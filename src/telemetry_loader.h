#pragma once

#include <string>
#include <vector>

namespace telemetry {

struct TelemetryLap {
  std::vector<float> x;
  std::vector<float> y;
  std::vector<float> t;
  std::vector<float> speed;
  std::vector<float> throttle;
  std::vector<float> brake;

  std::size_t size() const { return x.size(); }
  bool has_optional_channels() const {
    return speed.size() == x.size() && throttle.size() == x.size() && brake.size() == x.size();
  }
};

// CSV format:
// x,y,t[,speed,throttle,brake]
TelemetryLap load_lap_csv(const std::string& path);

// Creates a simple oval sample lap for quick testing.
TelemetryLap make_sample_lap(float radius_x, float radius_y, float lap_time_s, std::size_t points, float phase = 0.0f);

}  // namespace telemetry
