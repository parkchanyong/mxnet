/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

/*!
 * Copyright (c) 2017 by Contributors
 * \file random_generator.h
 * \brief Parallel random number generator.
 */
#ifndef MXNET_COMMON_RANDOM_GENERATOR_H_
#define MXNET_COMMON_RANDOM_GENERATOR_H_

#include <mxnet/base.h>
#include <random>
#include <new>

#if MXNET_USE_GPU
#include <hiprand_kernel.h>
#include "../common/cuda_utils.h"
#endif  // MXNET_USE_GPU

namespace mxnet {
namespace common {
namespace random {

template<typename Device, typename DType MSHADOW_DEFAULT_DTYPE>
class RandGenerator;

template<typename DType>
class RandGenerator<cpu, DType> {
 public:
  // at least how many random numbers should be generated by one CPU thread.
  static const int kMinNumRandomPerThread;
  // store how many global random states for CPU.
  static const int kNumRandomStates;

  // implementation class for random number generator
  class Impl {
   public:
    typedef typename std::conditional<std::is_floating_point<DType>::value,
                                      DType, double>::type FType;

    explicit Impl(RandGenerator<cpu, DType> *gen, int state_idx)
        : engine_(gen->states_ + state_idx) {}

    Impl(const Impl &) = delete;
    Impl &operator=(const Impl &) = delete;

    MSHADOW_XINLINE int rand() { return engine_->operator()(); }

    MSHADOW_XINLINE FType uniform() {
      typedef typename std::conditional<std::is_integral<DType>::value,
      std::uniform_int_distribution<DType>,
      std::uniform_real_distribution<FType>>::type GType;
      GType dist_uniform;
      return dist_uniform(*engine_);
    }

    MSHADOW_XINLINE FType normal() {
      std::normal_distribution<FType> dist_normal;
      return dist_normal(*engine_);
    }

   private:
    std::mt19937 *engine_;
  };

  static void AllocState(RandGenerator<cpu, DType> *inst) {
    inst->states_ = new std::mt19937[kNumRandomStates];
  }

  static void FreeState(RandGenerator<cpu, DType> *inst) {
    delete[] inst->states_;
  }

  MSHADOW_XINLINE void Seed(mshadow::Stream<cpu> *, uint32_t seed) {
    for (int i = 0; i < kNumRandomStates; ++i) (states_ + i)->seed(seed + i);
  }

 private:
  std::mt19937 *states_;
};  // class RandGenerator<cpu, DType>

template<typename DType>
const int RandGenerator<cpu, DType>::kMinNumRandomPerThread = 64;

template<typename DType>
const int RandGenerator<cpu, DType>::kNumRandomStates = 1024;

#if MXNET_USE_GPU

template<typename DType>
class RandGenerator<gpu, DType> {
 public:
  // at least how many random numbers should be generated by one GPU thread.
  static const int kMinNumRandomPerThread;
  // store how many global random states for GPU.
  static const int kNumRandomStates;

  // uniform number generation in Cuda made consistent with stl (include 0 but exclude 1)
  // by using 1.0-hiprand_uniform().
  // Needed as some samplers in sampler.h won't be able to deal with
  // one of the boundary cases.
  class Impl {
   public:
    Impl &operator=(const Impl &) = delete;
    Impl(const Impl &) = delete;

    // Copy state to local memory for efficiency.
    __device__ explicit Impl(RandGenerator<gpu, DType> *gen, int state_idx)
        : global_gen_(gen),
          global_state_idx_(state_idx),
          state_(*(gen->states_ + state_idx)) {}

    __device__ ~Impl() {
      // store the hiprand state back into global memory
      global_gen_->states_[global_state_idx_] = state_;
    }

    MSHADOW_FORCE_INLINE __device__ int rand() {
      return hiprand(&state_);
    }

    MSHADOW_FORCE_INLINE __device__ float uniform() {
      return static_cast<float>(1.0) - hiprand_uniform(&state_);
    }

    MSHADOW_FORCE_INLINE __device__ float normal() {
      return hiprand_normal(&state_);
    }

   private:
    RandGenerator<gpu, DType> *global_gen_;
    int global_state_idx_;
    hiprandStatePhilox4_32_10_t state_;
  };  // class RandGenerator<gpu, DType>::Impl

  static void AllocState(RandGenerator<gpu, DType> *inst) {
    CUDA_CALL(hipMalloc(&inst->states_,
                         kNumRandomStates * sizeof(hiprandStatePhilox4_32_10_t)));
  }

  static void FreeState(RandGenerator<gpu, DType> *inst) {
    CUDA_CALL(hipFree(inst->states_));
  }

  void Seed(mshadow::Stream<gpu> *s, uint32_t seed);

 private:
  hiprandStatePhilox4_32_10_t *states_;
};  // class RandGenerator<gpu, DType>

template<>
class RandGenerator<gpu, double> {
 public:
  // uniform number generation in Cuda made consistent with stl (include 0 but exclude 1)
  // by using 1.0-hiprand_uniform().
  // Needed as some samplers in sampler.h won't be able to deal with
  // one of the boundary cases.
  class Impl {
   public:
    Impl &operator=(const Impl &) = delete;
    Impl(const Impl &) = delete;

    // Copy state to local memory for efficiency.
    __device__ explicit Impl(RandGenerator<gpu, double> *gen, int state_idx)
        : global_gen_(gen),
          global_state_idx_(state_idx),
          state_(*(gen->states_ + state_idx)) {}

    __device__ ~Impl() {
      // store the hiprand state back into global memory
      global_gen_->states_[global_state_idx_] = state_;
    }

    MSHADOW_FORCE_INLINE __device__ int rand() {
      return hiprand(&state_);
    }

    MSHADOW_FORCE_INLINE __device__ double uniform() {
      return static_cast<float>(1.0) - hiprand_uniform_double(&state_);
    }

    MSHADOW_FORCE_INLINE __device__ double normal() {
      return hiprand_normal_double(&state_);
    }

   private:
    RandGenerator<gpu, double> *global_gen_;
    int global_state_idx_;
    hiprandStatePhilox4_32_10_t state_;
  };  // class RandGenerator<gpu, double>::Impl

 private:
  hiprandStatePhilox4_32_10_t *states_;
};  // class RandGenerator<gpu, double>

#endif  // MXNET_USE_GPU

}  // namespace random
}  // namespace common
}  // namespace mxnet
#endif  // MXNET_COMMON_RANDOM_GENERATOR_H_
