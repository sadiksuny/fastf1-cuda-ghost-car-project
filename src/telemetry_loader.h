#pragma once

#include <string>
#include <vector>

namespace telemetry {

// Raw telemetry channels loaded from CSV or generated synthetically for quick
// smoke tests. The optional channels are always sized to match x/y/t once a lap
// is successfully loaded so downstream code can assume consistent vector sizes.
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
//
// Header rows are tolerated. If the optional telemetry channels are absent they
// are back-filled with zeros so the CUDA pipeline can still run.
TelemetryLap load_lap_csv(const std::string& path);

// Creates a simple oval sample lap for quick testing.
TelemetryLap make_sample_lap(float radius_x, float radius_y, float lap_time_s, std::size_t points, float phase = 0.0f);

}  // namespace telemetry
