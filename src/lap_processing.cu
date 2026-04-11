#include "lap_processing.cuh"

#include <cuda_runtime.h>
#include <thrust/device_ptr.h>
#include <thrust/scan.h>

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace lap {
namespace {

inline void cuda_check(cudaError_t status, const char* context) {
  if (status != cudaSuccess) {
    throw std::runtime_error(std::string(context) + ": " + cudaGetErrorString(status));
  }
}

__global__ void segment_lengths_kernel(const float* x, const float* y, float* segment_lengths, int n) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= n) {
    return;
  }

  if (idx == 0) {
    segment_lengths[0] = 0.0f;
    return;
  }

  const float dx = x[idx] - x[idx - 1];
  const float dy = y[idx] - y[idx - 1];
  segment_lengths[idx] = sqrtf(dx * dx + dy * dy);
}

__device__ int lower_bound_device(const float* arr, int n, float value) {
  int left = 0;
  int right = n;
  while (left < right) {
    const int mid = left + (right - left) / 2;
    if (arr[mid] < value) {
      left = mid + 1;
    } else {
      right = mid;
    }
  }
  return left;
}

__global__ void resample_kernel(const float* source_s,
                                const float* source_x,
                                const float* source_y,
                                const float* source_t,
                                int source_n,
                                const float* grid_s,
                                float* out_x,
                                float* out_y,
                                float* out_t,
                                int grid_n) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= grid_n) {
    return;
  }

  const float s = grid_s[idx];
  const int upper = lower_bound_device(source_s, source_n, s);

  if (upper <= 0) {
    out_x[idx] = source_x[0];
    out_y[idx] = source_y[0];
    out_t[idx] = source_t[0];
    return;
  }
  if (upper >= source_n) {
    out_x[idx] = source_x[source_n - 1];
    out_y[idx] = source_y[source_n - 1];
    out_t[idx] = source_t[source_n - 1];
    return;
  }

  const int lower = upper - 1;
  const float s0 = source_s[lower];
  const float s1 = source_s[upper];
  const float alpha = (s1 > s0) ? ((s - s0) / (s1 - s0)) : 0.0f;

  out_x[idx] = source_x[lower] + alpha * (source_x[upper] - source_x[lower]);
  out_y[idx] = source_y[lower] + alpha * (source_y[upper] - source_y[lower]);
  out_t[idx] = source_t[lower] + alpha * (source_t[upper] - source_t[lower]);
}

__global__ void delta_kernel(const float* cmp_t, const float* ref_t, float* delta_t, int n) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= n) {
    return;
  }
  delta_t[idx] = cmp_t[idx] - ref_t[idx];
}

// Simple shared-memory box filter; shared memory keeps neighbor reads local for clarity/perf.
__global__ void smooth_kernel(const float* in, float* out, int n, int radius) {
  extern __shared__ float shared[];
  const int global_idx = blockIdx.x * blockDim.x + threadIdx.x;
  const int local_idx = threadIdx.x + radius;

  if (global_idx < n) {
    shared[local_idx] = in[global_idx];
  }

  if (threadIdx.x < radius) {
    const int left = max(0, global_idx - radius);
    const int right = min(n - 1, global_idx + static_cast<int>(blockDim.x));
    shared[threadIdx.x] = in[left];
    shared[local_idx + blockDim.x] = in[right];
  }
  __syncthreads();

  if (global_idx >= n) {
    return;
  }

  float sum = 0.0f;
  int count = 0;
  for (int k = -radius; k <= radius; ++k) {
    sum += shared[local_idx + k];
    ++count;
  }
  out[global_idx] = sum / static_cast<float>(count);
}

std::vector<float> compute_cumulative_distance_cuda(const std::vector<float>& x, const std::vector<float>& y) {
  if (x.size() != y.size() || x.empty()) {
    throw std::runtime_error("x and y must have same non-zero size");
  }

  const int n = static_cast<int>(x.size());
  float *d_x = nullptr, *d_y = nullptr, *d_seg = nullptr;

  cuda_check(cudaMalloc(&d_x, n * sizeof(float)), "cudaMalloc d_x");
  cuda_check(cudaMalloc(&d_y, n * sizeof(float)), "cudaMalloc d_y");
  cuda_check(cudaMalloc(&d_seg, n * sizeof(float)), "cudaMalloc d_seg");

  cuda_check(cudaMemcpy(d_x, x.data(), n * sizeof(float), cudaMemcpyHostToDevice), "copy x");
  cuda_check(cudaMemcpy(d_y, y.data(), n * sizeof(float), cudaMemcpyHostToDevice), "copy y");

  const int block = 256;
  const int grid = (n + block - 1) / block;
  segment_lengths_kernel<<<grid, block>>>(d_x, d_y, d_seg, n);
  cuda_check(cudaGetLastError(), "segment_lengths_kernel launch");

  thrust::device_ptr<float> seg_ptr(d_seg);
  thrust::inclusive_scan(seg_ptr, seg_ptr + n, seg_ptr);

  std::vector<float> cumulative(n);
  cuda_check(cudaMemcpy(cumulative.data(), d_seg, n * sizeof(float), cudaMemcpyDeviceToHost), "copy cumulative");

  cudaFree(d_x);
  cudaFree(d_y);
  cudaFree(d_seg);

  return cumulative;
}

std::vector<float> make_uniform_grid(float s_end, std::size_t points) {
  std::vector<float> grid(points);
  const float denom = static_cast<float>(points - 1);
  for (std::size_t i = 0; i < points; ++i) {
    grid[i] = s_end * static_cast<float>(i) / denom;
  }
  return grid;
}

ResampledLap resample_cuda(const std::vector<float>& source_s,
                           const std::vector<float>& source_x,
                           const std::vector<float>& source_y,
                           const std::vector<float>& source_t,
                           const std::vector<float>& grid_s) {
  const int source_n = static_cast<int>(source_s.size());
  const int grid_n = static_cast<int>(grid_s.size());

  float *d_s = nullptr, *d_x = nullptr, *d_y = nullptr, *d_t = nullptr;
  float *d_grid = nullptr, *d_out_x = nullptr, *d_out_y = nullptr, *d_out_t = nullptr;

  cuda_check(cudaMalloc(&d_s, source_n * sizeof(float)), "cudaMalloc d_s");
  cuda_check(cudaMalloc(&d_x, source_n * sizeof(float)), "cudaMalloc d_x src");
  cuda_check(cudaMalloc(&d_y, source_n * sizeof(float)), "cudaMalloc d_y src");
  cuda_check(cudaMalloc(&d_t, source_n * sizeof(float)), "cudaMalloc d_t src");
  cuda_check(cudaMalloc(&d_grid, grid_n * sizeof(float)), "cudaMalloc d_grid");
  cuda_check(cudaMalloc(&d_out_x, grid_n * sizeof(float)), "cudaMalloc out_x");
  cuda_check(cudaMalloc(&d_out_y, grid_n * sizeof(float)), "cudaMalloc out_y");
  cuda_check(cudaMalloc(&d_out_t, grid_n * sizeof(float)), "cudaMalloc out_t");

  cudaMemcpy(d_s, source_s.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_x, source_x.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_y, source_y.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_t, source_t.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_grid, grid_s.data(), grid_n * sizeof(float), cudaMemcpyHostToDevice);

  const int block = 256;
  const int grid = (grid_n + block - 1) / block;
  resample_kernel<<<grid, block>>>(d_s, d_x, d_y, d_t, source_n, d_grid, d_out_x, d_out_y, d_out_t, grid_n);
  cuda_check(cudaGetLastError(), "resample_kernel launch");

  ResampledLap out;
  out.s = grid_s;
  out.x.resize(grid_n);
  out.y.resize(grid_n);
  out.t.resize(grid_n);

  cudaMemcpy(out.x.data(), d_out_x, grid_n * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(out.y.data(), d_out_y, grid_n * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(out.t.data(), d_out_t, grid_n * sizeof(float), cudaMemcpyDeviceToHost);

  cudaFree(d_s);
  cudaFree(d_x);
  cudaFree(d_y);
  cudaFree(d_t);
  cudaFree(d_grid);
  cudaFree(d_out_x);
  cudaFree(d_out_y);
  cudaFree(d_out_t);

  return out;
}

std::vector<float> delta_cuda(const std::vector<float>& cmp_t, const std::vector<float>& ref_t, bool apply_smoothing) {
  const int n = static_cast<int>(cmp_t.size());
  float *d_cmp = nullptr, *d_ref = nullptr, *d_delta = nullptr, *d_smooth = nullptr;

  cuda_check(cudaMalloc(&d_cmp, n * sizeof(float)), "cudaMalloc d_cmp");
  cuda_check(cudaMalloc(&d_ref, n * sizeof(float)), "cudaMalloc d_ref");
  cuda_check(cudaMalloc(&d_delta, n * sizeof(float)), "cudaMalloc d_delta");

  cudaMemcpy(d_cmp, cmp_t.data(), n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_ref, ref_t.data(), n * sizeof(float), cudaMemcpyHostToDevice);

  const int block = 256;
  const int grid = (n + block - 1) / block;
  delta_kernel<<<grid, block>>>(d_cmp, d_ref, d_delta, n);
  cuda_check(cudaGetLastError(), "delta_kernel launch");

  if (apply_smoothing) {
    cuda_check(cudaMalloc(&d_smooth, n * sizeof(float)), "cudaMalloc d_smooth");
    constexpr int radius = 2;
    const std::size_t shared_bytes = (block + 2 * radius) * sizeof(float);
    smooth_kernel<<<grid, block, shared_bytes>>>(d_delta, d_smooth, n, radius);
    cuda_check(cudaGetLastError(), "smooth_kernel launch");
    cudaFree(d_delta);
    d_delta = d_smooth;
  }

  std::vector<float> delta(n);
  cudaMemcpy(delta.data(), d_delta, n * sizeof(float), cudaMemcpyDeviceToHost);

  cudaFree(d_cmp);
  cudaFree(d_ref);
  cudaFree(d_delta);
  return delta;
}

}  // namespace

std::vector<float> cumulative_distance_cpu(const std::vector<float>& x, const std::vector<float>& y) {
  if (x.size() != y.size() || x.empty()) {
    throw std::runtime_error("x and y must have same non-zero size");
  }

  std::vector<float> cumulative(x.size(), 0.0f);
  for (std::size_t i = 1; i < x.size(); ++i) {
    const float dx = x[i] - x[i - 1];
    const float dy = y[i] - y[i - 1];
    cumulative[i] = cumulative[i - 1] + std::sqrt(dx * dx + dy * dy);
  }
  return cumulative;
}

DeltaResult compute_delta_pipeline_cuda(const std::vector<float>& ref_x,
                                        const std::vector<float>& ref_y,
                                        const std::vector<float>& ref_t,
                                        const std::vector<float>& cmp_x,
                                        const std::vector<float>& cmp_y,
                                        const std::vector<float>& cmp_t,
                                        std::size_t grid_points,
                                        bool apply_smoothing) {
  if (ref_x.size() != ref_y.size() || ref_x.size() != ref_t.size() ||
      cmp_x.size() != cmp_y.size() || cmp_x.size() != cmp_t.size()) {
    throw std::runtime_error("Input channels must have matching lengths");
  }

  const auto ref_s = compute_cumulative_distance_cuda(ref_x, ref_y);
  const auto cmp_s = compute_cumulative_distance_cuda(cmp_x, cmp_y);

  const float common_end = std::min(ref_s.back(), cmp_s.back());
  const auto grid_s = make_uniform_grid(common_end, grid_points);

  auto ref_resampled = resample_cuda(ref_s, ref_x, ref_y, ref_t, grid_s);
  auto cmp_resampled = resample_cuda(cmp_s, cmp_x, cmp_y, cmp_t, grid_s);

  DeltaResult result;
  result.reference = std::move(ref_resampled);
  result.compare = std::move(cmp_resampled);
  result.delta_t = delta_cuda(result.compare.t, result.reference.t, apply_smoothing);
  return result;
}

}  // namespace lap
