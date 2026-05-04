#pragma once

#include "lap_processing.cuh"

#include <string>

namespace ui {

struct UiOptions {
  bool smoothing = true;
  bool telemetry_overlay_speed = true;
  bool telemetry_overlay_brake = true;
  std::string session_label;
  std::string reference_label = "REF";
  std::string compare_label = "CMP";
  std::string reference_lap_label;
  std::string compare_lap_label;
};

void run_prototype_ui(const lap::DeltaResult& delta, const UiOptions& options);
void write_html_viewer(const std::string& output_path,
                       std::size_t num_frames,
                       int frame_delay_ms,
                       const UiOptions& options);

}  // namespace ui
