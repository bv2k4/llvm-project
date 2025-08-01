//===- Promotion.cpp - Implementation of linalg Promotion -----------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements the linalg dialect Promotion pass.
//
//===----------------------------------------------------------------------===//

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Arith/Utils/Utils.h"
#include "mlir/Dialect/Complex/IR/Complex.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/GPU/IR/GPUDialect.h"
#include "mlir/Dialect/Linalg/IR/Linalg.h"
#include "mlir/Dialect/Linalg/Passes.h"
#include "mlir/Dialect/Linalg/Transforms/Transforms.h"
#include "mlir/IR/AffineMap.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/Interfaces/ValueBoundsOpInterface.h"
#include "mlir/Support/LLVM.h"
#include "mlir/Transforms/FoldUtils.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/SmallBitVector.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/ADT/TypeSwitch.h"
#include "llvm/Support/Debug.h"

using namespace mlir;
using namespace mlir::linalg;
using namespace mlir::scf;

using llvm::MapVector;

#define DEBUG_TYPE "linalg-promotion"

/// Alloc a new buffer of `size` * `width` i8; where `width` is given by the
/// data `layout` for `elementType`.
/// Use AllocOp or AllocaOp depending on `options`.
/// Take an optional alignment.
static Value allocBuffer(ImplicitLocOpBuilder &b,
                         const LinalgPromotionOptions &options,
                         Type elementType, Value allocSize, DataLayout &layout,
                         std::optional<unsigned> alignment = std::nullopt) {
  llvm::TypeSize width = layout.getTypeSize(elementType);
  assert(!width.isScalable() && "cannot allocate buffer for a scalable vector");

  IntegerAttr alignmentAttr;
  if (alignment.has_value())
    alignmentAttr = b.getI64IntegerAttr(alignment.value());

  Attribute memorySpaceAttr;
  if (options.memorySpace.has_value())
    memorySpaceAttr = *options.memorySpace;

  // Static buffer.
  if (std::optional<int64_t> cst = getConstantIntValue(allocSize)) {
    auto staticBufferType = MemRefType::get(width.getFixedValue() * cst.value(),
                                            b.getIntegerType(8));
    staticBufferType =
        MemRefType::Builder(staticBufferType).setMemorySpace(memorySpaceAttr);
    if (options.useAlloca) {
      return b.create<memref::AllocaOp>(staticBufferType, ValueRange{},
                                        alignmentAttr);
    }
    return b.create<memref::AllocOp>(staticBufferType, ValueRange{},
                                     alignmentAttr);
  }

  // Fallback dynamic buffer.
  auto dynamicBufferType =
      MemRefType::get(ShapedType::kDynamic, b.getIntegerType(8));
  dynamicBufferType =
      MemRefType::Builder(dynamicBufferType).setMemorySpace(memorySpaceAttr);
  Value mul = b.createOrFold<arith::MulIOp>(
      b.create<arith::ConstantIndexOp>(width), allocSize);
  if (options.useAlloca)
    return b.create<memref::AllocaOp>(dynamicBufferType, mul, alignmentAttr);
  return b.create<memref::AllocOp>(dynamicBufferType, mul, alignmentAttr);
}

/// Default allocation callback function. This allocates a promoted buffer when
/// no call back to do so is provided. The default is to allocate a
/// memref<..xi8> and return a view to get a memref type of shape
/// boundingSubViewSize.
static std::optional<Value> defaultAllocBufferCallBack(
    const LinalgPromotionOptions &options, OpBuilder &builder,
    memref::SubViewOp subView, ArrayRef<Value> boundingSubViewSize,
    std::optional<unsigned> alignment, DataLayout &layout) {
  ShapedType viewType = subView.getType();
  ImplicitLocOpBuilder b(subView.getLoc(), builder);
  auto zero = b.create<arith::ConstantIndexOp>(0);
  auto one = b.create<arith::ConstantIndexOp>(1);

  Attribute memorySpaceAttr;
  if (options.memorySpace.has_value())
    memorySpaceAttr = *options.memorySpace;

  Value allocSize = one;
  for (const auto &size : llvm::enumerate(boundingSubViewSize))
    allocSize = b.createOrFold<arith::MulIOp>(allocSize, size.value());
  Value buffer = allocBuffer(b, options, viewType.getElementType(), allocSize,
                             layout, alignment);
  SmallVector<int64_t, 4> dynSizes(boundingSubViewSize.size(),
                                   ShapedType::kDynamic);

  auto viewMemRefType = MemRefType::get(dynSizes, viewType.getElementType());
  viewMemRefType =
      MemRefType::Builder(viewMemRefType).setMemorySpace(memorySpaceAttr);
  Value view = b.createOrFold<memref::ViewOp>(viewMemRefType, buffer, zero,
                                              boundingSubViewSize);
  return view;
}

/// Default implementation of deallocation of the buffer use for promotion. It
/// expects to get the same value that the default allocation method returned,
/// i.e. result of a ViewOp.
static LogicalResult
defaultDeallocBufferCallBack(const LinalgPromotionOptions &options,
                             OpBuilder &b, Value fullLocalView) {
  if (!options.useAlloca) {
    auto viewOp = cast<memref::ViewOp>(fullLocalView.getDefiningOp());
    b.create<memref::DeallocOp>(viewOp.getSource().getLoc(),
                                viewOp.getSource());
  }
  return success();
}

namespace {

/// Helper struct that captures the information required to apply the
/// transformation on each op. This bridges the abstraction gap with the
/// user-facing API which exposes positional arguments to control which operands
/// are promoted.
struct LinalgOpInstancePromotionOptions {
  LinalgOpInstancePromotionOptions(LinalgOp op,
                                   const LinalgPromotionOptions &options);
  /// SubViews to promote.
  MapVector<int64_t, Value> subViews;
  /// Subviews operand numbers to copy in using copyInFn.
  llvm::SmallSet<int64_t, 4> operandsNumbersToCopyIn;
  /// True if the full view should be used for the promoted buffer.
  DenseMap<Value, bool> useFullTileBuffers;
  /// True if the original subview size should be used. This means the full tile
  /// buffer is the same size as the partial view.
  bool useOriginalSubviewSize;

  /// Callback functions for allocation and deallocation of promoted buffers, as
  /// well as to copy the data into and out of these buffers.
  AllocBufferCallbackFn allocationFn;
  DeallocBufferCallbackFn deallocationFn;
  CopyCallbackFn copyInFn;
  CopyCallbackFn copyOutFn;

  /// Alignment of promoted buffer.
  std::optional<unsigned> alignment;
};
} // namespace

LinalgOpInstancePromotionOptions::LinalgOpInstancePromotionOptions(
    LinalgOp linalgOp, const LinalgPromotionOptions &options)
    : subViews(), alignment(options.alignment) {
  assert(linalgOp.hasPureBufferSemantics() &&
         "revisit usage of shaped operand");
  auto vUseFullTileBuffers =
      options.useFullTileBuffers.value_or(llvm::SmallBitVector());
  vUseFullTileBuffers.resize(linalgOp->getNumOperands(),
                             options.useFullTileBuffersDefault);
  useOriginalSubviewSize = options.useOriginalSubviewSize;

  for (OpOperand &opOperand : linalgOp->getOpOperands()) {
    int64_t operandNumber = opOperand.getOperandNumber();
    if (options.operandsToPromote &&
        !options.operandsToPromote->count(operandNumber))
      continue;
    Operation *op = opOperand.get().getDefiningOp();
    if (auto sv = dyn_cast_or_null<memref::SubViewOp>(op)) {
      subViews[operandNumber] = sv;
      // In case of linalg generic, copy in only if subview is used in linalg
      // payload.
      if (!isa<linalg::GenericOp>(linalgOp) ||
          linalgOp.payloadUsesValueFromOperand(&opOperand))
        operandsNumbersToCopyIn.insert(operandNumber);
      useFullTileBuffers[sv] = vUseFullTileBuffers[operandNumber];
    }
  }

  if (options.allocationFn) {
    allocationFn = *options.allocationFn;
  } else {
    allocationFn = [&](OpBuilder &b, memref::SubViewOp subViewOp,
                       ArrayRef<Value> boundingSubViewSize,
                       DataLayout &layout) -> std::optional<Value> {
      return defaultAllocBufferCallBack(options, b, subViewOp,
                                        boundingSubViewSize, alignment, layout);
    };
  }

  if (options.deallocationFn) {
    deallocationFn = *options.deallocationFn;
  } else {
    deallocationFn = [&](OpBuilder &b, Value buffer) {
      return defaultDeallocBufferCallBack(options, b, buffer);
    };
  }

  // Save the loc because `linalgOp` goes out of scope.
  Location loc = linalgOp.getLoc();
  auto defaultCopyCallBack = [loc](OpBuilder &b, Value src,
                                   Value dst) -> LogicalResult {
    b.create<linalg::CopyOp>(loc, src, dst);
    return success();
  };
  copyInFn = (options.copyInFn ? *(options.copyInFn) : defaultCopyCallBack);
  copyOutFn = (options.copyOutFn ? *(options.copyOutFn) : defaultCopyCallBack);
}

// Performs promotion of a `subView` into a local buffer of the size of the
// *ranges* of the `subView`. This produces a buffer whose size may be bigger
// than the actual size of the `subView` at the boundaries.
// This is related to the full/partial tile problem.
// Returns a PromotionInfo containing a `buffer`, `fullLocalView` and
// `partialLocalView` such that:
//   * `buffer` is always the size of the full tile.
//   * `fullLocalView` is a dense contiguous view into that buffer.
//   * `partialLocalView` is a dense non-contiguous slice of `fullLocalView`
//     that corresponds to the size of `subView` and accounting for boundary
//     effects.
// The point of the full tile buffer is that constant static tile sizes are
// folded and result in a buffer type with statically known size and alignment
// properties.
// To account for general boundary effects, padding must be performed on the
// boundary tiles. For now this is done with an unconditional `fill` op followed
// by a partial `copy` op.
FailureOr<PromotionInfo> mlir::linalg::promoteSubviewAsNewBuffer(
    OpBuilder &b, Location loc, memref::SubViewOp subView,
    bool useOriginalSubviewSize, const AllocBufferCallbackFn &allocationFn,
    DataLayout &layout) {
  auto viewType = subView.getType();
  auto rank = viewType.getRank();
  SmallVector<Value, 4> fullSizes;
  SmallVector<OpFoldResult> partialSizes;
  fullSizes.reserve(rank);
  partialSizes.reserve(rank);
  llvm::SmallBitVector droppedDims = subView.getDroppedDims();
  int64_t resultDimIdx = 0;
  for (const auto &en : llvm::enumerate(subView.getOrCreateRanges(b, loc))) {
    if (droppedDims[en.index()])
      continue;
    auto rangeValue = en.value();
    // Try to extract a tight constant. If the size is known statically, no need
    // to look for the bound.
    LLVM_DEBUG(llvm::dbgs() << "Extract tightest: " << rangeValue.size << "\n");
    Value size;
    if (llvm::isa_and_present<Attribute>(rangeValue.size) ||
        useOriginalSubviewSize) {
      size = getValueOrCreateConstantIndexOp(b, loc, rangeValue.size);
    } else {
      FailureOr<int64_t> upperBound =
          ValueBoundsConstraintSet::computeConstantBound(
              presburger::BoundType::UB, rangeValue.size,
              /*stopCondition=*/nullptr, /*closedUB=*/true);
      size = failed(upperBound)
                 ? getValueOrCreateConstantIndexOp(b, loc, rangeValue.size)
                 : b.create<arith::ConstantIndexOp>(loc, *upperBound);
    }
    LLVM_DEBUG(llvm::dbgs() << "Extracted tightest: " << size << "\n");
    fullSizes.push_back(size);
    partialSizes.push_back(
        b.createOrFold<memref::DimOp>(loc, subView, resultDimIdx++));
  }
  // If a callback is not specified, then use the default implementation for
  // allocating the promoted buffer.
  std::optional<Value> fullLocalView =
      allocationFn(b, subView, fullSizes, layout);
  if (!fullLocalView)
    return failure();
  SmallVector<OpFoldResult, 4> zeros(fullSizes.size(), b.getIndexAttr(0));
  SmallVector<OpFoldResult, 4> ones(fullSizes.size(), b.getIndexAttr(1));
  auto partialLocalView = b.createOrFold<memref::SubViewOp>(
      loc, *fullLocalView, zeros, partialSizes, ones);
  return PromotionInfo{*fullLocalView, partialLocalView};
}

static FailureOr<MapVector<int64_t, PromotionInfo>>
promoteSubViews(ImplicitLocOpBuilder &b,
                LinalgOpInstancePromotionOptions options, DataLayout &layout) {
  if (options.subViews.empty())
    return failure();

  MapVector<int64_t, PromotionInfo> promotionInfoMap;

  for (auto v : options.subViews) {
    memref::SubViewOp subView =
        cast<memref::SubViewOp>(v.second.getDefiningOp());
    auto promotionInfo = promoteSubviewAsNewBuffer(
        b, b.getLoc(), subView, options.useOriginalSubviewSize,
        options.allocationFn, layout);
    if (failed(promotionInfo))
      return failure();
    promotionInfoMap[v.first] = *promotionInfo;

    // Only fill the buffer if the full local view is used
    if (!options.useFullTileBuffers[v.second])
      continue;
    Type subviewEltType = subView.getType().getElementType();
    Value fillVal =
        llvm::TypeSwitch<Type, Value>(subviewEltType)
            .Case([&](FloatType t) {
              return b.create<arith::ConstantOp>(FloatAttr::get(t, 0.0));
            })
            .Case([&](IntegerType t) {
              return b.create<arith::ConstantOp>(IntegerAttr::get(t, 0));
            })
            .Case([&](ComplexType t) {
              Value tmp;
              if (auto et = dyn_cast<FloatType>(t.getElementType()))
                tmp = b.create<arith::ConstantOp>(FloatAttr::get(et, 0.0));
              else if (auto et = cast<IntegerType>(t.getElementType()))
                tmp = b.create<arith::ConstantOp>(IntegerAttr::get(et, 0));
              return b.create<complex::CreateOp>(t, tmp, tmp);
            })
            .Default([](auto) { return Value(); });
    if (!fillVal)
      return failure();
    b.create<linalg::FillOp>(fillVal, promotionInfo->fullLocalView);
  }

  // Copy data into the promoted buffers. Use callback if provided.
  for (auto v : options.subViews) {
    auto *info = promotionInfoMap.find(v.first);
    if (info == promotionInfoMap.end())
      continue;
    if (options.operandsNumbersToCopyIn.count(v.first) == 0)
      continue;
    if (failed(options.copyInFn(
            b, cast<memref::SubViewOp>(v.second.getDefiningOp()),
            info->second.partialLocalView)))
      return failure();
  }
  return promotionInfoMap;
}

static FailureOr<LinalgOp>
promoteSubViews(ImplicitLocOpBuilder &b, LinalgOp op,
                LinalgOpInstancePromotionOptions options, DataLayout &layout) {
  assert(op.hasPureBufferSemantics() &&
         "expected linalg op with buffer semantics");

  // 1. Promote the specified views and use them in the new op.
  auto promotedBuffersAndViews = promoteSubViews(b, options, layout);
  if (failed(promotedBuffersAndViews) ||
      promotedBuffersAndViews->size() != options.subViews.size())
    return failure();

  // 2. Append all other operands as they appear, this enforces that such
  // operands are not views. This is to support cases such as FillOp taking
  // extra scalars etc.  Keep a reference to output buffers;
  SmallVector<Value, 8> opViews;
  opViews.reserve(op->getNumOperands());
  SmallVector<std::pair<Value, Value>, 8> writebackViews;
  writebackViews.reserve(promotedBuffersAndViews->size());
  for (OpOperand &opOperand : op->getOpOperands()) {
    int64_t operandNumber = opOperand.getOperandNumber();
    if (options.subViews.count(operandNumber) != 0) {
      if (options.useFullTileBuffers[opOperand.get()])
        opViews.push_back(
            (*promotedBuffersAndViews)[operandNumber].fullLocalView);
      else
        opViews.push_back(
            (*promotedBuffersAndViews)[operandNumber].partialLocalView);
      if (operandNumber >= op.getNumDpsInputs())
        writebackViews.emplace_back(std::make_pair(
            opOperand.get(),
            (*promotedBuffersAndViews)[operandNumber].partialLocalView));
    } else {
      opViews.push_back(opOperand.get());
    }
  }
  op->setOperands(0, opViews.size(), opViews);

  OpBuilder::InsertionGuard guard(b);
  b.setInsertionPointAfter(op);
  // 3. Emit write-back for the promoted output views: copy the partial view.
  for (auto viewAndPartialLocalView : writebackViews) {
    if (failed(options.copyOutFn(b, viewAndPartialLocalView.second,
                                 viewAndPartialLocalView.first)))
      return failure();
  }

  // 4. Dealloc all local buffers.
  for (const auto &pi : *promotedBuffersAndViews)
    (void)options.deallocationFn(b, pi.second.fullLocalView);
  return op;
}

LogicalResult
mlir::linalg::promoteSubviewsPrecondition(Operation *op,
                                          LinalgPromotionOptions options) {
  LinalgOp linalgOp = dyn_cast<LinalgOp>(op);
  // Transformation applies to buffers only.
  if (!linalgOp || !linalgOp.hasPureBufferSemantics())
    return failure();
  // Check that at least one of the requested operands is indeed a subview.
  for (OpOperand &opOperand : linalgOp->getOpOperands()) {
    auto sv =
        isa_and_nonnull<memref::SubViewOp>(opOperand.get().getDefiningOp());
    if (sv) {
      if (!options.operandsToPromote ||
          options.operandsToPromote->count(opOperand.getOperandNumber()))
        return success();
    }
  }
  // TODO: Check all subviews requested are bound by a static constant.
  // TODO: Check that the total footprint fits within a given size.
  return failure();
}

FailureOr<LinalgOp>
mlir::linalg::promoteSubViews(OpBuilder &builder, LinalgOp linalgOp,
                              const LinalgPromotionOptions &options) {
  LinalgOpInstancePromotionOptions linalgOptions(linalgOp, options);
  auto layout = DataLayout::closest(linalgOp);
  ImplicitLocOpBuilder b(linalgOp.getLoc(), builder);
  auto res = ::promoteSubViews(b, linalgOp, linalgOptions, layout);
  if (failed(res))
    return failure();
  return res;
}

/// Allocate the given subview to a memory address space in GPU by creating a
/// allocation operation and setting the memref type address space to desired
/// address space.
static std::optional<Value> allocateSubviewGPUMemoryInAddressSpace(
    OpBuilder &builder, memref::SubViewOp subview, ArrayRef<Value> sizeBounds,
    gpu::AddressSpace addressSpace) {
  OpBuilder::InsertionGuard guard(builder);

  func::FuncOp funcOp = subview->getParentOfType<func::FuncOp>();
  if (!funcOp)
    return std::nullopt;

  // The subview size bounds are expected to be constant; they specify the shape
  // of the allocation.
  SmallVector<int64_t> shape;
  for (Value bound : sizeBounds) {
    APInt value;
    if (!matchPattern(bound, m_ConstantInt(&value)))
      return std::nullopt;
    shape.push_back(value.getSExtValue());
  }

  builder.setInsertionPointToStart(&funcOp.front());
  auto type = MemRefType::get(
      shape, subview.getType().getElementType(), MemRefLayoutAttrInterface{},
      gpu::AddressSpaceAttr::get(builder.getContext(), addressSpace));
  Value buffer;
  if (addressSpace == gpu::GPUDialect::getWorkgroupAddressSpace()) {
    buffer = builder.create<memref::AllocOp>(funcOp.getLoc(), type);
  } else if (addressSpace == gpu::GPUDialect::getPrivateAddressSpace()) {
    buffer = builder.create<memref::AllocaOp>(funcOp.getLoc(), type);
  } else {
    return std::nullopt;
  }
  return buffer;
}

/// Allocate the subview in the GPU workgroup memory.
std::optional<Value> mlir::linalg::allocateWorkgroupMemory(
    OpBuilder &builder, memref::SubViewOp subview, ArrayRef<Value> sizeBounds,
    DataLayout &) {
  return allocateSubviewGPUMemoryInAddressSpace(
      builder, subview, sizeBounds,
      gpu::GPUDialect::getWorkgroupAddressSpace());
}

/// In case of GPU group memory there is no need to deallocate.
LogicalResult mlir::linalg::deallocateWorkgroupMemory(OpBuilder &,
                                                      Value /*buffer*/) {
  return success();
}

/// Create Memref copy operations and add gpu barrier guards before and after
/// the copy operation to ensure data integrity.
LogicalResult mlir::linalg::copyToWorkgroupMemory(OpBuilder &b, Value src,
                                                  Value dst) {
  b.create<gpu::BarrierOp>(src.getLoc());
  Operation *copyOp = b.create<memref::CopyOp>(src.getLoc(), src, dst);
  b.create<gpu::BarrierOp>(copyOp->getLoc());
  return success();
}

/// Allocate the subview in the GPU private memory.
std::optional<Value> mlir::linalg::allocateGPUPrivateMemory(
    OpBuilder &builder, memref::SubViewOp subview, ArrayRef<Value> sizeBounds,
    DataLayout &) {
  return allocateSubviewGPUMemoryInAddressSpace(
      builder, subview, sizeBounds, gpu::GPUDialect::getPrivateAddressSpace());
}

/// Normal copy to between src and dst.
LogicalResult mlir::linalg::copyToGPUPrivateMemory(OpBuilder &b, Value src,
                                                   Value dst) {
  b.create<memref::CopyOp>(src.getLoc(), src, dst);
  return success();
}

/// In case of GPU private memory there is no need to deallocate since the
/// memory is freed when going outside of the scope.
LogicalResult mlir::linalg::deallocateGPUPrivateMemory(OpBuilder &,
                                                       Value /*buffer*/) {
  return success();
}
