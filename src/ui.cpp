#include "ui.h"

#include "renderer.h"

#include <filesystem>
#include <iostream>

namespace ui {

void run_prototype_ui(const lap::DeltaResult& delta, const UiOptions& options) {
  std::filesystem::create_directories("output");

  std::cout << "Prototype toggles:\n"
            << "  best lap mode: " << (options.best_lap_mode ? "on" : "off") << "\n"
            << "  smoothing: " << (options.smoothing ? "on" : "off") << "\n"
            << "  speed overlay: " << (options.telemetry_overlay_speed ? "on" : "off") << "\n"
            << "  brake overlay: " << (options.telemetry_overlay_brake ? "on" : "off") << "\n";

  const std::size_t num_frames = 20;
  for (std::size_t frame = 0; frame < num_frames; ++frame) {
    const std::size_t idx = frame * (delta.reference.s.size() - 1) / (num_frames - 1);
    auto image = render::render_track_frame(delta, idx, 800, 600);
    const std::string path = "output/frame_" + std::to_string(frame) + ".ppm";
    render::write_ppm(image, path);
  }

  std::cout << "Wrote " << num_frames
            << " rendered frames to ./output (PPM). Use an image viewer to scrub ghost-marker movement.\n";
}

}  // namespace ui
