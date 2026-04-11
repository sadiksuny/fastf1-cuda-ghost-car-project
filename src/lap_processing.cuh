#pragma once

#include <cstddef>
#include <vector>

namespace lap {

struct ResampledLap {
  std::vector<float> s;
  std::vector<float> x;
  std::vector<float> y;
  std::vector<float> t;
};

struct DeltaResult {
  ResampledLap reference;
  ResampledLap compare;
  std::vector<float> delta_t;
};

// CPU reference implementation for cumulative distance (useful for tests).
std::vector<float> cumulative_distance_cpu(const std::vector<float>& x, const std::vector<float>& y);

// CUDA pipeline that computes cumulative distance, interpolation on uniform s-grid, and delta curve.
DeltaResult compute_delta_pipeline_cuda(const std::vector<float>& ref_x,
                                        const std::vector<float>& ref_y,
                                        const std::vector<float>& ref_t,
                                        const std::vector<float>& cmp_x,
                                        const std::vector<float>& cmp_y,
                                        const std::vector<float>& cmp_t,
                                        std::size_t grid_points,
                                        bool apply_smoothing);

}  // namespace lap
