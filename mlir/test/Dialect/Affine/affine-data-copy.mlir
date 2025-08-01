// RUN: mlir-opt %s -split-input-file -affine-data-copy-generate="fast-mem-space=0 skip-non-unit-stride-loops" | FileCheck %s
// Small buffer size to trigger fine copies.
// RUN: mlir-opt %s -split-input-file -affine-data-copy-generate="fast-mem-space=0 fast-mem-capacity=1" | FileCheck --check-prefix=CHECK-SMALL %s

// Test affine data copy with a memref filter. We use a test pass that invokes
// affine data copy utility on the input loop nest.
// '-test-affine-data-copy-memref-filter' passes the first memref found in an
// affine.load op in the innermost loop as a filter.
// RUN: mlir-opt %s -split-input-file -test-affine-data-copy='memref-filter' | FileCheck %s --check-prefix=FILTER
// RUN: mlir-opt %s -split-input-file -test-affine-data-copy='for-memref-region' | FileCheck %s --check-prefix=MEMREF_REGION
// RUN: mlir-opt %s -split-input-file -test-affine-data-copy='capacity-kib=32' | FileCheck %s --check-prefix=LIMITED-MEM

// -copy-skip-non-stride-loops forces the copies to be placed right inside the
// tile space loops, avoiding the sensitivity of copy placement depth to memory
// footprint -- so that one could write a definite test case and not have to
// update it each time something related to the cost functions change.

#id = affine_map<(d0) -> (d0)>
#ub = affine_map<(d0) -> (d0 + 128)>

// Map used to index the buffer while computing.
// CHECK-DAG: [[$MAP_IDENTITY:map[0-9a-zA-Z_]*]] = affine_map<(d0) -> (d0)>
// CHECK-DAG: [[$MAP_PLUS_128:map[0-9a-zA-Z_]*]] = affine_map<(d0) -> (d0 + 128)>

// CHECK-LABEL: func @matmul
// FILTER-LABEL: func @matmul
// LIMITED-MEM-LABEL: func @matmul
func.func @matmul(%A: memref<4096x4096xf32>, %B: memref<4096x4096xf32>, %C: memref<4096x4096xf32>) -> memref<4096x4096xf32> {
  affine.for %i = 0 to 4096 step 128 {
    affine.for %j = 0 to 4096 step 128 {
      affine.for %k = 0 to 4096 step 128 {
        affine.for %ii = #id(%i) to #ub(%i) {
          affine.for %jj = #id(%j) to #ub(%j) {
            affine.for %kk = #id(%k) to #ub(%k) {
              %5 = affine.load %A[%ii, %kk] : memref<4096x4096xf32>
              %6 = affine.load %B[%kk, %jj] : memref<4096x4096xf32>
              %7 = affine.load %C[%ii, %jj] : memref<4096x4096xf32>
              %8 = arith.mulf %5, %6 : f32
              %9 = arith.addf %7, %8 : f32
              affine.store %9, %C[%ii, %jj] : memref<4096x4096xf32>
            }
          }
        }
      }
    }
  }
  return %C : memref<4096x4096xf32>
  // LIMITED-MEM: return
}

// Buffers of size 128x128 get created here for all three matrices.

// CHECK: affine.for %[[I:.*]] = 0 to 4096 step 128 {
// CHECK:   affine.for %[[J:.*]] = 0 to 4096 step 128 {
// CHECK:     [[BUFC:%[0-9a-zA-Z_]+]] = memref.alloc() : memref<128x128xf32>
// The result matrix's copy gets hoisted out.
// Result matrix copy-in.
// CHECK:     affine.for %[[II:.*]] = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:       affine.for %[[JJ:.*]] = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:         affine.load %{{.*}}[%{{.*}}, %{{.*}}] : memref<4096x4096xf32>
// CHECK:         affine.store %{{.*}}, [[BUFC]][%[[II]] - %[[I]], %[[JJ]] - %[[J]]] : memref<128x128xf32>
// CHECK:       }
// CHECK:     }

// LHS matrix copy-in.
// CHECK:     affine.for %[[K:.*]] = 0 to 4096 step 128 {
// CHECK:      [[BUFA:%[0-9a-zA-Z_]+]] = memref.alloc() : memref<128x128xf32>
// CHECK:       affine.for %[[II:.*]] = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:         affine.for %[[KK:.*]] = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:           affine.load %{{.*}}[%{{.*}}, %{{.*}}] : memref<4096x4096xf32>
// CHECK:           affine.store %{{.*}}, [[BUFA]][%[[II]] - %[[I]], %[[KK]] - %[[K]]] : memref<128x128xf32>
// CHECK:         }
// CHECK:       }

// RHS matrix copy-in.
// CHECK:       [[BUFB:%[0-9a-zA-Z_]+]] = memref.alloc() : memref<128x128xf32>
// CHECK:       affine.for %[[KK:.*]] = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:         affine.for %[[JJ:.*]] = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:           affine.load %{{.*}}[%{{.*}}, %{{.*}}] : memref<4096x4096xf32>
// CHECK:           affine.store %{{.*}}, [[BUFB]][%[[KK]] - %[[K]], %[[JJ]] - %[[J]]] : memref<128x128xf32>
// CHECK:         }
// CHECK:       }

// Computation on the fast buffers.
// CHECK:       affine.for %{{.*}} = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:         affine.for %{{.*}} = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:           affine.for %{{.*}} = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:             affine.load [[BUFA]][-%{{.*}} + %{{.*}}, -%{{.*}} + %{{.*}}] : memref<128x128xf32>
// CHECK:             affine.load [[BUFB]][-%{{.*}} + %{{.*}}, -%{{.*}} + %{{.*}}] : memref<128x128xf32>
// CHECK:             affine.load [[BUFC]][-%{{.*}} + %{{.*}}, -%{{.*}} + %{{.*}}] : memref<128x128xf32>
// CHECK:             arith.mulf %{{.*}}, %{{.*}} : f32
// CHECK:             arith.addf %{{.*}}, %{{.*}} : f32
// CHECK:             affine.store %{{.*}}, [[BUFC]][-%{{.*}} + %{{.*}}, -%{{.*}} + %{{.*}}] : memref<128x128xf32>
// CHECK:           }
// CHECK:         }
// CHECK:       }
// CHECK:       memref.dealloc [[BUFB]] : memref<128x128xf32>
// CHECK:       memref.dealloc [[BUFA]] : memref<128x128xf32>
// CHECK:     }

// Result matrix copy out.
// CHECK:     affine.for %{{.*}} = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:       affine.for %{{.*}} = #[[$MAP_IDENTITY]](%{{.*}}) to #[[$MAP_PLUS_128]](%{{.*}}) {
// CHECK:         affine.load [[BUFC]][%{{.*}} - %{{.*}}, %{{.*}} - %{{.*}}] : memref<128x128xf32>
// CHECK:         store %{{.*}}, %{{.*}}[%{{.*}}, %{{.*}}] : memref<4096x4096xf32>
// CHECK:       }
// CHECK:     }
// CHECK:     memref.dealloc [[BUFC]] : memref<128x128xf32>
// CHECK:   }
// CHECK: }

// Check that only one memref is copied when memref filter is used.

//      FILTER: affine.for %{{.*}} = 0 to 4096 step 128 {
//      FILTER:   memref.alloc() : memref<128x4096xf32>
//  FILTER-NOT:   memref.alloc()
//      FILTER:   affine.for
//      FILTER:     affine.for %{{.*}} = 0 to 4096 {
//      FILTER:   affine.for %{{.*}} = 0 to 4096 step 128 {
// FILTER-NEXT:     affine.for %{{.*}} = 0 to 4096 step 128 {
// FILTER-NEXT:       affine.for %{{.*}} = #map{{.*}}(%{{.*}}) to #map{{.*}}(%{{.*}}) {
// FILTER-NEXT:         affine.for %{{.*}} = #map{{.*}}(%{{.*}}) to #map{{.*}}(%{{.*}}) {
// FILTER-NEXT:           affine.for %{{.*}} = #map{{.*}}(%{{.*}}) to #map{{.*}}(%{{.*}}) {
//      FILTER:   memref.dealloc %{{.*}} : memref<128x4096xf32>
//  FILTER-NOT:   memref.dealloc %{{.*}} : memref<128x4096xf32>

// -----

//
// This test case will lead to single element buffers. These are eventually
// expected to be turned into registers via alloca and mem2reg.
//
// CHECK-SMALL-LABEL: func @single_elt_buffers
// FILTER-LABEL: func @single_elt_buffers
// MEMREF_REGION-LABEL: func @single_elt_buffers
func.func @single_elt_buffers(%arg0: memref<1024x1024xf32>, %arg1: memref<1024x1024xf32>, %arg2: memref<1024x1024xf32>) -> memref<1024x1024xf32> {
  affine.for %i = 0 to 1024 {
    affine.for %j = 0 to 1024 {
      affine.for %k = 0 to 1024 {
        %6 = affine.load %arg1[%k, %j] : memref<1024x1024xf32>
        %7 = affine.load %arg2[%i, %j] : memref<1024x1024xf32>
        %9 = arith.addf %6, %7 : f32
        affine.store %9, %arg2[%i, %j] : memref<1024x1024xf32>
      }
    }
  }
  return %arg2 : memref<1024x1024xf32>
}
// CHECK-SMALL: affine.for %arg{{.*}} = 0 to 1024 {
// CHECK-SMALL:   affine.for %arg{{.*}} = 0 to 1024 {
// CHECK-SMALL:     memref.alloc() : memref<1x1xf32>
// CHECK-SMALL:     affine.load %arg{{.*}}[%{{.*}}, %{{.*}}] : memref<1024x1024xf32>
// CHECK-SMALL:     affine.store %{{.*}}, %{{.*}}[0, 0] : memref<1x1xf32>
// CHECK-SMALL:     affine.for %arg{{.*}} = 0 to 1024 {
// CHECK-SMALL:       memref.alloc() : memref<1x1xf32>
// CHECK-SMALL:       affine.load %arg{{.*}}[%{{.*}}, %{{.*}}] : memref<1024x1024xf32>
// CHECK-SMALL:       affine.store %{{.*}}, %{{.*}}[0, 0] : memref<1x1xf32>
// CHECK-SMALL:       affine.load %{{.*}}[0, 0] : memref<1x1xf32>
// CHECK-SMALL:       affine.load %{{.*}}[0, 0] : memref<1x1xf32>
// CHECK-SMALL:       arith.addf %{{.*}}, %{{.*}} : f32
// CHECK-SMALL:       affine.store %{{.*}}, %{{.*}}[0, 0] : memref<1x1xf32>
// CHECK-SMALL:       memref.dealloc %{{.*}} : memref<1x1xf32>
// CHECK-SMALL:     }
// CHECK-SMALL:     affine.load %{{.*}}[0, 0] : memref<1x1xf32>
// CHECK-SMALL:     affine.store %{{.*}}, %arg{{.*}}[%{{.*}}, %{{.*}}] : memref<1024x1024xf32>
// CHECK-SMALL:     memref.dealloc %{{.*}} : memref<1x1xf32>
// CHECK-SMALL:   }
// CHECK-SMALL: }
// CHECK-SMALL: return

// Check that only one memref is copied when memref filter is used.

//      FILTER: memref.alloc() : memref<1024x1024xf32>
//  FILTER-NOT: memref.alloc()
//      FILTER: affine.for %{{.*}} = 0 to 1024 {
//      FILTER:   affine.for %{{.*}} = 0 to 1024 {
//      FILTER: affine.for %{{.*}} = 0 to 1024 {
// FILTER-NEXT:   affine.for %{{.*}} = 0 to 1024 {
// FILTER-NEXT:     affine.for %{{.*}} = 0 to 1024 {
//      FILTER: memref.dealloc %{{.*}} : memref<1024x1024xf32>
//  FILTER-NOT: memref.dealloc
//  FILTER:     return

// CHeck that only one memref is copied, because for-memref-region is enabled
// (and the first ever encountered load is analyzed).
//      MEMREF_REGION: memref.alloc() : memref<1024x1024xf32>
//  MEMREF_REGION-NOT: memref.alloc()
//      MEMREF_REGION: affine.for %{{.*}} = 0 to 1024 {
//      MEMREF_REGION:   affine.for %{{.*}} = 0 to 1024 {
//      MEMREF_REGION:   }
//      MEMREF_REGION: }
// MEMREF_REGION-NEXT: affine.for %{{.*}} = 0 to 1024 {
// MEMREF_REGION-NEXT:   affine.for %{{.*}} = 0 to 1024 {
// MEMREF_REGION-NEXT:     affine.for %{{.*}} = 0 to 1024 {
//      MEMREF_REGION: memref.dealloc %{{.*}} : memref<1024x1024xf32>
// MEMREF_REGION-NOT: memref.dealloc
// MEMREF_REGION-NEXT: return

// -----

// This pattern typically appears with tiling with tile sizes that don't divide
// the loop trip counts.

#map_ub = affine_map<(d0) -> (4096, d0 + 100)>

// CHECK-DAG: [[$MAP_IDENTITY:map[0-9a-zA-Z_]*]] = affine_map<(d0) -> (d0)>
// CHECK-DAG: [[$MAP_MIN_UB1:map[0-9a-zA-Z_]*]] = affine_map<(d0) -> (d0 + 100, 4096)>
// CHECK-DAG: [[$MAP_MIN_UB2:map[0-9a-zA-Z_]*]] = affine_map<(d0) -> (4096, d0 + 100)>

// CHECK-LABEL: func @min_upper_bound
func.func @min_upper_bound(%A: memref<4096xf32>) -> memref<4096xf32> {
  affine.for %i = 0 to 4096 step 100 {
    affine.for %ii = affine_map<(d0) -> (d0)>(%i) to min #map_ub(%i) {
      %5 = affine.load %A[%ii] : memref<4096xf32>
      %6 = arith.mulf %5, %5 : f32
      affine.store %6, %A[%ii] : memref<4096xf32>
    }
  }
  return %A : memref<4096xf32>
}
// CHECK:      affine.for %[[IV1:.*]] = 0 to 4096 step 100
// CHECK:        %[[BUF:.*]] = memref.alloc() : memref<100xf32>
// CHECK-NEXT:   affine.for %[[IV2:.*]] = #[[$MAP_IDENTITY]](%[[IV1]]) to min #[[$MAP_MIN_UB1]](%[[IV1]]) {
// CHECK-NEXT:     affine.load %{{.*}}[%[[IV2]]] : memref<4096xf32>
// CHECK-NEXT:     affine.store %{{.*}}, %[[BUF]][%[[IV2]] - %[[IV1]]] : memref<100xf32>
// CHECK-NEXT:   }
// CHECK-NEXT:   affine.for %[[IV2:.*]] = #[[$MAP_IDENTITY]](%[[IV1]]) to min #[[$MAP_MIN_UB2]](%[[IV1]]) {
// CHECK-NEXT:     affine.load %[[BUF]][-%[[IV1]] + %[[IV2]]] : memref<100xf32>
// CHECK-NEXT:     arith.mulf
// CHECK-NEXT:     affine.store %{{.*}}, %[[BUF]][-%[[IV1]] + %[[IV2]]] : memref<100xf32>
// CHECK-NEXT:   }
// CHECK:        affine.for %[[IV2:.*]] = #[[$MAP_IDENTITY]](%[[IV1]]) to min #[[$MAP_MIN_UB1]](%[[IV1]]) {
// CHECK-NEXT:     affine.load %[[BUF]][%[[IV2]] - %[[IV1]]] : memref<100xf32>
// CHECK-NEXT:     affine.store %{{.*}}, %{{.*}}[%[[IV2]]] : memref<4096xf32>
// CHECK-NEXT:   }
// CHECK-NEXT:   memref.dealloc %[[BUF]] : memref<100xf32>
// CHECK-NEXT: }

// -----

// Lower bound is a max; upper bound is a min. This pattern typically appears
// with multi-level tiling when the tile sizes used don't divide loop trip
// counts.

#lb = affine_map<()[s0, s1] -> (s0 * 512, s1 * 6)>
#ub = affine_map<()[s0, s1] -> (s0 * 512 + 512, s1 * 6 + 6)>

// CHECK-DAG: #[[$LB:.*]] = affine_map<()[s0, s1] -> (s0 * 512, s1 * 6)>
// CHECK-DAG: #[[$UB:.*]] = affine_map<()[s0, s1] -> (s0 * 512 + 512, s1 * 6 + 6)>

// CHECK-LABEL: max_lower_bound(%{{.*}}: memref<2048x516xf64>,
// CHECK-SAME: [[i:arg[0-9a-zA-Z_]+]]
// CHECK-SAME: [[j:arg[0-9a-zA-Z_]+]]
func.func @max_lower_bound(%M: memref<2048x516xf64>, %i : index, %j : index) {
  affine.for %ii = 0 to 2048 {
    affine.for %jj = max #lb()[%i, %j] to min #ub()[%i, %j] {
      affine.load %M[%ii, %jj] : memref<2048x516xf64>
    }
  }
  return
}

// CHECK:      %[[BUF:.*]] = memref.alloc() : memref<2048x6xf64>
// CHECK-NEXT: affine.for %[[ii:.*]] = 0 to 2048 {
// CHECK-NEXT:   affine.for %[[jj:.*]] = max #[[$LB]]()[%[[i]], %[[j]]] to min #[[$UB]]()[%[[i]], %[[j]]] {
// CHECK-NEXT:      affine.load %{{.*}}[%[[ii]], %[[jj]]] : memref<2048x516xf64>
// CHECK-NEXT:      affine.store %{{.*}}, %[[BUF]][%[[ii]], %[[jj]] - symbol(%[[j]]) * 6] : memref<2048x6xf64>
// CHECK-NEXT:   }
// CHECK-NEXT: }
// CHECK-NEXT: affine.for %[[ii_:.*]] = 0 to 2048 {
// CHECK-NEXT:   affine.for %[[jj_:.*]] = max #[[$LB]]()[%{{.*}}, %{{.*}}] to min #[[$UB]]()[%{{.*}}, %{{.*}}] {
// CHECK-NEXT:     affine.load %[[BUF]][%[[ii_]], %[[jj_]] - symbol(%[[j]]) * 6] : memref<2048x6xf64>
// CHECK-NEXT:    }
// CHECK-NEXT: }
// CHECK-NEXT: memref.dealloc %[[BUF]] : memref<2048x6xf64>

// -----

// CHECK-LABEL: func @empty_loops
func.func @empty_loops(%arg0: memref<1024x1024xf64>) {
  // Empty loops - so no copy generation happens.
  affine.for %i = 0 to 0 {
    affine.load %arg0[0, %i] : memref<1024x1024xf64>
  }
  affine.for %i = 0 to -16 {
    affine.load %arg0[0, %i] : memref<1024x1024xf64>
  }
  return
  // CHECK-NOT:    memref.alloc
  // CHECK:        return
}

#map16 = affine_map<(d0, d1, d2) -> (d0 * 40 + d1 * 8 + d2 * 2)>
#map17 = affine_map<(d0, d1, d2) -> (d0 * 40 + d1 * 8 + d2 * 2 + 2)>
// CHECK-LABEL: func @affine_parallel
func.func @affine_parallel(%85:memref<2x5x4x2xi64>) {
  affine.for %arg0 = 0 to 2 {
    affine.parallel (%arg1) = (0) to (5) {
      affine.parallel (%arg2) = (0) to (4) {
        affine.for %arg3 = #map16(%arg0, %arg1, %arg2) to #map17(%arg0, %arg1, %arg2) {
          %105 = affine.load %85[((%arg3 floordiv 2) floordiv 4) floordiv 5, ((%arg3 floordiv 2) floordiv 4) mod 5, (%arg3 floordiv 2) mod 4, %arg3 mod 2] : memref<2x5x4x2xi64>
        }
      }
    }
  }
  // Lower and upper bounds for the region can't be determined for the outermost
  // dimension. No fast buffer generation.
  // CHECK:     affine.for
  // CHECK-NEXT:  affine.parallel
  // CHECK-NEXT:    affine.parallel
  // CHECK-NEXT:      affine.for
  // CHECK-NOT:      affine.for


  return
}

// CHECK-LABEL: func @index_elt_type
func.func @index_elt_type(%arg0: memref<1x2x4x8xindex>) {
  affine.for %arg1 = 0 to 1 {
    affine.for %arg2 = 0 to 2 {
      affine.for %arg3 = 0 to 4 {
        affine.for %arg4 = 0 to 8 {
          affine.store %arg4, %arg0[%arg1, %arg2, %arg3, %arg4] : memref<1x2x4x8xindex>
        }
      }
    }
  }

  // CHECK:     affine.for %{{.*}} = 0 to 1
  // CHECK-NEXT:  affine.for %{{.*}} = 0 to 2
  // CHECK-NEXT:    affine.for %{{.*}} = 0 to 4
  // CHECK-NEXT:      affine.for %{{.*}} = 0 to 8

  // CHECK:     affine.for %{{.*}} = 0 to 2
  // CHECK-NEXT:  affine.for %{{.*}} = 0 to 4
  // CHECK-NEXT:    affine.for %{{.*}} = 0 to 8
  return
}

#map = affine_map<(d0) -> (d0 + 1)>

// CHECK-LABEL: func @arbitrary_memory_space
func.func @arbitrary_memory_space() {
  %alloc = memref.alloc() : memref<256x8xi8, #spirv.storage_class<StorageBuffer>>
  affine.for %arg0 = 0 to 32 step 4 {
    %0 = affine.apply #map(%arg0)
    affine.for %arg1 = 0 to 8 step 2 {
      %1 = affine.apply #map(%arg1)
      affine.for %arg2 = 0 to 8 step 2 {
        // CHECK: memref.alloc() : memref<1x7xi8>
        %2 = affine.apply #map(%arg2)
        %3 = affine.load %alloc[%0, %1] : memref<256x8xi8, #spirv.storage_class<StorageBuffer>>
        affine.store %3, %alloc[%0, %2] : memref<256x8xi8, #spirv.storage_class<StorageBuffer>>
      }
    }
  }
  return
}

// CHECK-LABEL: zero_ranked
func.func @zero_ranked(%3:memref<480xi1>) {
  %false = arith.constant false
  %4 = memref.alloc() {alignment = 128 : i64} : memref<i1>
  affine.store %false, %4[] : memref<i1>
  %5 = memref.alloc() {alignment = 128 : i64} : memref<i1>
  memref.copy %4, %5 : memref<i1> to memref<i1>
  affine.for %arg0 = 0 to 480 {
    %11 = affine.load %3[%arg0] : memref<480xi1>
    %12 = affine.load %5[] : memref<i1>
    %13 = arith.cmpi slt, %11, %12 : i1
    %14 = arith.select %13, %11, %12 : i1
    affine.store %14, %5[] : memref<i1>
  }
  return
}

// CHECK-LABEL: func @scalar_memref_copy_without_dma
func.func @scalar_memref_copy_without_dma() {
    %false = arith.constant false
    %4 = memref.alloc() {alignment = 128 : i64} : memref<i1>
    affine.store %false, %4[] : memref<i1>

    // CHECK: %[[FALSE:.*]] = arith.constant false
    // CHECK: %[[MEMREF:.*]] = memref.alloc() {alignment = 128 : i64} : memref<i1>
    // CHECK: affine.store %[[FALSE]], %[[MEMREF]][] : memref<i1>
    return
}

// CHECK-LABEL: func @scalar_memref_copy_in_loop
func.func @scalar_memref_copy_in_loop(%3:memref<480xi1>) {
  %false = arith.constant false
  %4 = memref.alloc() {alignment = 128 : i64} : memref<i1>
  affine.store %false, %4[] : memref<i1>
  %5 = memref.alloc() {alignment = 128 : i64} : memref<i1>
  memref.copy %4, %5 : memref<i1> to memref<i1>
  affine.for %arg0 = 0 to 480 {
    %11 = affine.load %3[%arg0] : memref<480xi1>
    %12 = affine.load %5[] : memref<i1>
    %13 = arith.cmpi slt, %11, %12 : i1
    %14 = arith.select %13, %11, %12 : i1
    affine.store %14, %5[] : memref<i1>
  }

  // CHECK: %[[FALSE:.*]] = arith.constant false
  // CHECK: %[[MEMREF:.*]] = memref.alloc() {alignment = 128 : i64} : memref<i1>
  // CHECK: affine.store %[[FALSE]], %[[MEMREF]][] : memref<i1>
  // CHECK: %[[TARGET:.*]] = memref.alloc() {alignment = 128 : i64} : memref<i1>
  // CHECK: memref.copy %alloc, %[[TARGET]] : memref<i1> to memref<i1>
  // CHECK: %[[FAST_MEMREF:.*]] = memref.alloc() : memref<480xi1>
  // CHECK: affine.for %{{.*}} = 0 to 480 {
  // CHECK:   %{{.*}} = affine.load %arg0[%{{.*}}] : memref<480xi1>
  // CHECK:   affine.store %{{.*}}, %[[FAST_MEMREF]][%{{.*}}] : memref<480xi1>
  // CHECK: }
  // CHECK: affine.for %arg1 = 0 to 480 {
  // CHECK:   %[[L0:.*]] = affine.load %[[FAST_MEMREF]][%arg1] : memref<480xi1>
  // CHECK:   %[[L1:.*]] = affine.load %[[TARGET]][] : memref<i1>
  // CHECK:   %[[CMPI:.*]] = arith.cmpi slt, %[[L0]], %[[L1]] : i1
  // CHECK:   %[[SELECT:.*]] = arith.select %[[CMPI]], %[[L0]], %[[L1]] : i1
  // CHECK:   affine.store %[[SELECT]], %[[TARGET]][] : memref<i1>
  // CHECK: }
  // CHECK: memref.dealloc %[[FAST_MEMREF]] : memref<480xi1>
  return
}

// CHECK-LABEL: func @memref_def_inside
// LIMITED-MEM-LABEL: func @memref_def_inside
func.func @memref_def_inside(%arg0: index) {
  %0 = llvm.mlir.constant(1.000000e+00 : f32) : f32
  // No copy generation can happen at this depth given the definition inside.
  affine.for %arg1 = 0 to 29 {
    %alloc_7 = memref.alloc() : memref<1xf32>
    // CHECK: affine.store {{.*}} : memref<1xf32>
    affine.store %0, %alloc_7[0] : memref<1xf32>
  }

  // With the limited capacity specified, buffer generation happens at the
  // innermost depth. Tests that copy-placement is proper and respects the
  // memref definition.

  // LIMITED-MEM:      affine.for %{{.*}} = 0 to 29
  // LIMITED-MEM-NEXT:   memref.alloc() : memref<1xf32>
  // LIMITED-MEM-NEXT:   memref.alloc() : memref<1xf32>
  // LIMITED-MEM-NEXT:   affine.store %{{.*}}, %{{.*}}[0] : memref<1xf32>
  // LIMITED-MEM-NEXT:   affine.load %{{.*}}[%c0{{.*}}] : memref<1xf32>
  // LIMITED-MEM-NEXT:   affine.store %{{.*}}, %{{.*}}[0] : memref<1xf32>
  // LIMITED-MEM-NEXT:   memref.dealloc %{{.*}} : memref<1xf32>
  return
}

// Test with uses across multiple blocks.

memref.global "private" constant @__constant_1x2x1xi32_1 : memref<1x2x1xi32> = dense<0> {alignment = 64 : i64}

// CHECK-LABEL: func @multiple_blocks
func.func @multiple_blocks(%arg0: index) -> memref<1x2x1xi32> {
  %c1_i32 = arith.constant 1 : i32
  %c3_i32 = arith.constant 3 : i32
  %0 = memref.get_global @__constant_1x2x1xi32_1 : memref<1x2x1xi32>
  %alloc = memref.alloc() {alignment = 64 : i64} : memref<1x2x1xi32>
  memref.copy %0, %alloc : memref<1x2x1xi32> to memref<1x2x1xi32>
  cf.br ^bb1(%alloc : memref<1x2x1xi32>)
^bb1(%1: memref<1x2x1xi32>):  // 2 preds: ^bb0, ^bb2
// CHECK: ^bb1(%[[MEM:.*]]: memref<1x2x1xi32>):
  %alloc_0 = memref.alloc() {alignment = 64 : i64} : memref<1x2x1xi1>
  // CHECK: %[[BUF:.*]] = memref.alloc() : memref<1x2x1xi32>
  affine.for %arg1 = 0 to 1 {
    affine.for %arg2 = 0 to 2 {
      affine.for %arg3 = 0 to 1 {
        // CHECK: affine.load %[[BUF]]
        %3 = affine.load %1[%arg1, %arg2, %arg3] : memref<1x2x1xi32>
        %4 = arith.cmpi slt, %3, %c3_i32 : i32
        affine.store %4, %alloc_0[%arg1, %arg2, %arg3] : memref<1x2x1xi1>
      }
    }
  }
  // CHECK: memref.dealloc %[[BUF]]
  %2 = memref.load %alloc_0[%arg0, %arg0, %arg0] : memref<1x2x1xi1>
  cf.cond_br %2, ^bb2, ^bb3
^bb2:  // pred: ^bb1
// CHECK: ^bb2
  %alloc_1 = memref.alloc() {alignment = 64 : i64} : memref<1x2x1xi32>
  affine.for %arg1 = 0 to 1 {
    affine.for %arg2 = 0 to 2 {
      affine.for %arg3 = 0 to 1 {
        // Ensure that this reference isn't replaced.
        %3 = affine.load %1[%arg1, %arg2, %arg3] : memref<1x2x1xi32>
        // CHECK: affine.load %[[MEM]]
        %4 = arith.addi %3, %c1_i32 : i32
        affine.store %4, %alloc_1[%arg1, %arg2, %arg3] : memref<1x2x1xi32>
      }
    }
  }
  cf.br ^bb1(%alloc_1 : memref<1x2x1xi32>)
^bb3:  // pred: ^bb1
  return %1 : memref<1x2x1xi32>
}
