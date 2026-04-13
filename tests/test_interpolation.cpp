#include "lap_processing.cuh"

#include <cmath>
#include <iostream>
#include <vector>

int main() {
  // Straight-line path so distance alignment is exact and easy to verify.
  const std::vector<float> ref_x{0.0f, 1.0f, 2.0f, 3.0f};
  const std::vector<float> ref_y{0.0f, 0.0f, 0.0f, 0.0f};
  const std::vector<float> ref_t{0.0f, 1.0f, 2.0f, 3.0f};

  // Compare lap is uniformly +0.5s slower.
  const std::vector<float> cmp_x{0.0f, 1.0f, 2.0f, 3.0f};
  const std::vector<float> cmp_y{0.0f, 0.0f, 0.0f, 0.0f};
  const std::vector<float> cmp_t{0.5f, 1.5f, 2.5f, 3.5f};

  const auto delta = lap::compute_delta_pipeline_cuda(
      ref_x, ref_y, ref_t,
      cmp_x, cmp_y, cmp_t,
      16, false);

  for (float d : delta.delta_t) {
    if (std::abs(d - 0.5f) > 1e-3f) {
      std::cerr << "Unexpected delta value: " << d << "\n";
      return 1;
    }
  }

  std::cout << "interpolation test passed\n";
  return 0;
}
