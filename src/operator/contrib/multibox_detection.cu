#include <hip/hip_runtime.h>
/*!
 * Copyright (c) 2016 by Contributors
 * \file multibox_detection.cu
 * \brief MultiBoxDetection op
 * \author Joshua Zhang
*/
#include "./multibox_detection-inl.h"
#include <mshadow/cuda/tensor_gpu-inl.cuh>

#define MULTIBOX_DETECTION_CUDA_CHECK(condition) \
  /* Code block avoids redefinition of hipError_t error */ \
  do { \
    hipError_t error = condition; \
    CHECK_EQ(error, hipSuccess) << " " << hipGetErrorString(error); \
  } while (0)

namespace mshadow {
namespace cuda {
template<typename DType>
__device__ void Clip(DType *value, const DType lower, const DType upper) {
  if ((*value) < lower) *value = lower;
  if ((*value) > upper) *value = upper;
}

template<typename DType>
__device__ void CalculateOverlap(const DType *a, const DType *b, DType *iou) {
  DType w = max(DType(0), min(a[2], b[2]) - max(a[0], b[0]));
  DType h = max(DType(0), min(a[3], b[3]) - max(a[1], b[1]));
  DType i = w * h;
  DType u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i;
  (*iou) =  u <= 0.f ? static_cast<DType>(0) : static_cast<DType>(i / u);
}

template<typename DType>
__global__ void DetectionForwardKernel(DType *out, const DType *cls_prob,
                                       const DType *loc_pred, const DType *anchors,
                                       DType *temp_space, const int num_classes,
                                       const int num_anchors, const float threshold,
                                       const bool clip, const float vx,
                                       const float vy, const float vw,
                                       const float vh, const float nms_threshold,
                                       const bool force_suppress, const int nms_topk) {
  const int nbatch = hipBlockIdx_x;  // each block for each batch
  int index = hipThreadIdx_x;
  __shared__ int valid_count;
  out += nbatch * num_anchors * 6;
  cls_prob += nbatch * num_anchors * num_classes;
  loc_pred += nbatch * num_anchors * 4;

  if (index == 0) {
    valid_count = 0;
  }
  __syncthreads();

  // apply prediction to anchors
  for (int i = index; i < num_anchors; i += hipBlockDim_x) {
    DType score = -1;
    int id = 0;
    for (int j = 1; j < num_classes; ++j) {
      DType temp = cls_prob[j * num_anchors + i];
      if (temp > score) {
        score = temp;
        id = j;
      }
    }
    if (id > 0 && score < threshold) {
      id = 0;
    }

    if (id > 0) {
      // valid class
      int pos = atomicAdd(&valid_count, 1);
      out[pos * 6] = id - 1;  // restore original class id
      out[pos * 6 + 1] = (id == 0 ? DType(-1) : score);
      int offset = i * 4;
      DType al = anchors[offset];
      DType at = anchors[offset + 1];
      DType ar = anchors[offset + 2];
      DType ab = anchors[offset + 3];
      DType aw = ar - al;
      DType ah = ab - at;
      DType ax = (al + ar) / 2.f;
      DType ay = (at + ab) / 2.f;
      DType ox = loc_pred[offset] * vx * aw + ax;
      DType oy = loc_pred[offset + 1] * vy * ah + ay;
      DType ow = exp(loc_pred[offset + 2] * vw) * aw / 2;
      DType oh = exp(loc_pred[offset + 3] * vh) * ah / 2;
      DType xmin = ox - ow;
      DType ymin = oy - oh;
      DType xmax = ox + ow;
      DType ymax = oy + oh;
      if (clip) {
        Clip(&xmin, DType(0), DType(1));
        Clip(&ymin, DType(0), DType(1));
        Clip(&xmax, DType(0), DType(1));
        Clip(&ymax, DType(0), DType(1));
      }
      out[pos * 6 + 2] = xmin;
      out[pos * 6 + 3] = ymin;
      out[pos * 6 + 4] = xmax;
      out[pos * 6 + 5] = ymax;
    }
  }
  __syncthreads();

  if (valid_count < 1 || nms_threshold <= 0 || nms_threshold > 1) return;
  // if (index == 0) printf("%d\n", valid_count);

  // descent sort according to scores
  const int size = valid_count;
  temp_space += nbatch * num_anchors * 6;
  DType *src = out;
  DType *dst = temp_space;
  for (int width = 2; width < (size << 1); width <<= 1) {
    int slices = (size - 1) / (hipBlockDim_x * width) + 1;
    int start = width * index * slices;
    for (int slice = 0; slice < slices; ++slice) {
      if (start >= size) break;
      int middle = start + (width >> 1);
      if (middle > size) middle = size;
      int end = start + width;
      if (end > size) end = size;
      int i = start;
      int j = middle;
      for (int k = start; k < end; ++k) {
        DType score_i = i < size ? src[i * 6 + 1] : DType(-1);
        DType score_j = j < size ? src[j * 6 + 1] : DType(-1);
        if (i < middle && (j >= end || score_i > score_j)) {
          for (int n = 0; n < 6; ++n) {
            dst[k * 6 + n] = src[i * 6 + n];
          }
          ++i;
        } else {
          for (int n = 0; n < 6; ++n) {
            dst[k * 6 + n] = src[j * 6 + n];
          }
          ++j;
        }
      }
      start += width;
    }
    __syncthreads();
    src = src == out? temp_space : out;
    dst = dst == out? temp_space : out;
  }
  __syncthreads();

  if (src == temp_space) {
    // copy from temp to out
    for (int i = index; i < size * 6; i += hipBlockDim_x) {
      out[i] = temp_space[i];
    }
    __syncthreads();
  }

  // keep top k detections
  int ntop = size;
  if (nms_topk > 0 && nms_topk < ntop) {
    ntop = nms_topk;
    for (int i = ntop + index; i < size; i += hipBlockDim_x) {
      out[i * 6] = -1;
    }
    __syncthreads();
  }

  // apply NMS
  for (int compare_pos = 0; compare_pos < ntop; ++compare_pos) {
    DType compare_id = out[compare_pos * 6];
    if (compare_id < 0) continue;  // not a valid positive detection, skip
    DType *compare_loc_ptr = out + compare_pos * 6 + 2;
    for (int i = compare_pos + index + 1; i < ntop; i += hipBlockDim_x) {
      DType class_id = out[i * 6];
      if (class_id < 0) continue;
      if (force_suppress || (class_id == compare_id)) {
        DType iou;
        CalculateOverlap(compare_loc_ptr, out + i * 6 + 2, &iou);
        if (iou >= nms_threshold) {
          out[i * 6] = -1;
        }
      }
    }
    __syncthreads();
  }
}
}  // namespace cuda

template<typename DType>
inline void MultiBoxDetectionForward(const Tensor<gpu, 3, DType> &out,
                                     const Tensor<gpu, 3, DType> &cls_prob,
                                     const Tensor<gpu, 2, DType> &loc_pred,
                                     const Tensor<gpu, 2, DType> &anchors,
                                     const Tensor<gpu, 3, DType> &temp_space,
                                     const float threshold,
                                     const bool clip,
                                     const nnvm::Tuple<float> &variances,
                                     const float nms_threshold,
                                     const bool force_suppress,
                                     const int nms_topk) {
  CHECK_EQ(variances.ndim(), 4) << "Variance size must be 4";
  const int num_classes = cls_prob.size(1);
  const int num_anchors = cls_prob.size(2);
  const int num_batches = cls_prob.size(0);
  const int num_threads = cuda::kMaxThreadsPerBlock;
  int num_blocks = num_batches;
  cuda::CheckLaunchParam(num_blocks, num_threads, "MultiBoxDetection Forward");
  hipStream_t stream = Stream<gpu>::GetStream(out.stream_);
   hipLaunchKernelGGL(HIP_KERNEL_NAME(cuda::DetectionForwardKernel), dim3(num_blocks), dim3(num_threads), 0, stream,\
        static_cast<DType*>(out.dptr_),\
        static_cast<const DType*>(cls_prob.dptr_),\
        static_cast<const DType*>(loc_pred.dptr_),\
        static_cast<const DType*>(anchors.dptr_),\
        static_cast<DType*>(temp_space.dptr_),\
        static_cast<const int>(num_classes),\
        static_cast<const int>(num_anchors),\
        static_cast<const float>(threshold),\
        static_cast<const bool>(clip),\
        static_cast<const float>(variances[0]),\
        static_cast<const float>(variances[1]),\
        static_cast<const float>(variances[2]),\
        static_cast<const float>(variances[3]),\
        static_cast<const float>(nms_threshold),\
        static_cast<const bool>(force_suppress),\
        static_cast<const int>(nms_topk));
  MULTIBOX_DETECTION_CUDA_CHECK(hipPeekAtLastError());
}
}  // namespace mshadow

namespace mxnet {
namespace op {
template<>
Operator *CreateOp<gpu>(MultiBoxDetectionParam param, int dtype) {
  Operator *op = NULL;
  MSHADOW_REAL_TYPE_SWITCH(dtype, DType, {
    op = new MultiBoxDetectionOp<gpu, DType>(param);
  });
  return op;
}
}  // namespace op
}  // namespace mxnet
