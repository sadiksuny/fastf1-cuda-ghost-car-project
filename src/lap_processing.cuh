#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace lap {

struct ResampledLap {
  std::vector<float> s;
  std::vector<float> x;
  std::vector<float> y;
  std::vector<float> t;
  std::vector<float> speed;
  std::vector<float> throttle;
  std::vector<float> brake;
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
                                        const std::vector<float>& ref_speed,
                                        const std::vector<float>& ref_throttle,
                                        const std::vector<float>& ref_brake,
                                        const std::vector<float>& cmp_x,
                                        const std::vector<float>& cmp_y,
                                        const std::vector<float>& cmp_t,
                                        const std::vector<float>& cmp_speed,
                                        const std::vector<float>& cmp_throttle,
                                        const std::vector<float>& cmp_brake,
                                        std::size_t grid_points,
                                        bool apply_smoothing);

std::vector<unsigned char> render_frame_cuda(const DeltaResult& delta,
                                             float frame_time_s,
                                             const std::string& reference_label,
                                             const std::string& compare_label,
                                             float reference_x,
                                             float reference_y,
                                             float compare_x,
                                             float compare_y,
                                             float delta_t_value,
                                             int width,
                                             int height,
                                             bool overlay_speed,
                                             bool overlay_brake);

}  // namespace lap
