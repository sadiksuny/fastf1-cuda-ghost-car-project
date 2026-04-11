#pragma once

#include "lap_processing.cuh"

namespace ui {

struct UiOptions {
  bool smoothing = true;
  bool best_lap_mode = true;
  bool telemetry_overlay_speed = false;
  bool telemetry_overlay_brake = false;
};

void run_prototype_ui(const lap::DeltaResult& delta, const UiOptions& options);

}  // namespace ui
