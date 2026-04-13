#pragma once

#include "lap_processing.cuh"

#include <string>

namespace ui {

struct UiOptions {
  bool smoothing = true;
  bool best_lap_mode = true;
  bool telemetry_overlay_speed = false;
  bool telemetry_overlay_brake = false;
  std::string reference_label = "REF";
  std::string compare_label = "CMP";
};

void run_prototype_ui(const lap::DeltaResult& delta, const UiOptions& options);
void write_html_viewer(const std::string& output_path,
                       std::size_t num_frames,
                       int frame_delay_ms,
                       const UiOptions& options);

}  // namespace ui
