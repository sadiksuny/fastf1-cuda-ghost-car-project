#include "telemetry_loader.h"

#include <cmath>
#include <fstream>
#include <sstream>
#include <stdexcept>

namespace telemetry {
namespace {

constexpr float kPi = 3.14159265358979323846f;

std::vector<float> split_csv_to_floats(const std::string& line) {
  std::vector<float> values;
  std::stringstream ss(line);
  std::string cell;
  while (std::getline(ss, cell, ',')) {
    if (cell.empty()) {
      values.push_back(0.0f);
    } else {
      values.push_back(std::stof(cell));
    }
  }
  return values;
}

}  // namespace

TelemetryLap load_lap_csv(const std::string& path) {
  std::ifstream input(path);
  if (!input.is_open()) {
    throw std::runtime_error("Unable to open telemetry file: " + path);
  }

  TelemetryLap lap;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty()) {
      continue;
    }

    // Skip header line if present.
    if (line.find("x") != std::string::npos && line.find("y") != std::string::npos && line.find("t") != std::string::npos) {
      continue;
    }

    const auto values = split_csv_to_floats(line);
    if (values.size() < 3) {
      throw std::runtime_error("Telemetry line must have at least x,y,t values");
    }

    lap.x.push_back(values[0]);
    lap.y.push_back(values[1]);
    lap.t.push_back(values[2]);

    if (values.size() >= 6) {
      lap.speed.push_back(values[3]);
      lap.throttle.push_back(values[4]);
      lap.brake.push_back(values[5]);
    }
  }

  if (lap.x.empty() || lap.y.size() != lap.x.size() || lap.t.size() != lap.x.size()) {
    throw std::runtime_error("Telemetry file contains inconsistent column lengths");
  }

  return lap;
}

TelemetryLap make_sample_lap(float radius_x, float radius_y, float lap_time_s, std::size_t points, float phase) {
  TelemetryLap lap;
  lap.x.resize(points);
  lap.y.resize(points);
  lap.t.resize(points);
  lap.speed.resize(points);
  lap.throttle.resize(points);
  lap.brake.resize(points);

  for (std::size_t i = 0; i < points; ++i) {
    const float u = static_cast<float>(i) / static_cast<float>(points - 1);
    const float theta = (2.0f * kPi * u) + phase;
    lap.x[i] = radius_x * std::cos(theta);
    lap.y[i] = radius_y * std::sin(theta);
    lap.t[i] = lap_time_s * u;

    const float curvature = std::abs(std::sin(theta));
    lap.speed[i] = 75.0f + 25.0f * (1.0f - curvature);
    lap.throttle[i] = 0.4f + 0.6f * (1.0f - curvature);
    lap.brake[i] = curvature;
  }

  return lap;
}

}  // namespace telemetry
