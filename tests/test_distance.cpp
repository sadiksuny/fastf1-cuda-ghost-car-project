#include "lap_processing.cuh"

#include <cmath>
#include <iostream>
#include <vector>

int main() {
  // Polyline: (0,0) -> (3,4) -> (6,8), each segment length 5.
  const std::vector<float> x{0.0f, 3.0f, 6.0f};
  const std::vector<float> y{0.0f, 4.0f, 8.0f};

  const auto s = lap::cumulative_distance_cpu(x, y);
  if (s.size() != 3) {
    std::cerr << "Expected 3 distances, got " << s.size() << "\n";
    return 1;
  }

  if (std::abs(s[0] - 0.0f) > 1e-5f || std::abs(s[1] - 5.0f) > 1e-5f || std::abs(s[2] - 10.0f) > 1e-5f) {
    std::cerr << "Unexpected cumulative distances: [" << s[0] << ", " << s[1] << ", " << s[2] << "]\n";
    return 1;
  }

  std::cout << "distance test passed\n";
  return 0;
}
