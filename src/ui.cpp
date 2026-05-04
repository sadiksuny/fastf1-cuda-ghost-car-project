#include "ui.h"

#include "renderer.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>

namespace ui {

void write_html_viewer(const std::string& output_path,
                       std::size_t num_frames,
                       int frame_delay_ms,
                       const UiOptions& options) {
  std::ofstream out(output_path, std::ios::binary);
  if (!out.is_open()) {
    throw std::runtime_error("Failed to open HTML viewer output: " + output_path);
  }

  out << "<!doctype html>\n"
         "<html lang=\"en\">\n"
         "<head>\n"
         "  <meta charset=\"utf-8\">\n"
         "  <title>Ghost Car Viewer</title>\n"
         "  <style>\n"
         "    body { background:#0b0b0b; color:#efefef; font-family:Segoe UI, Arial, sans-serif; margin:0; padding:24px; }\n"
         "    .wrap { max-width:980px; margin:0 auto; }\n"
         "    h1 { margin:0 0 8px; font-size:28px; }\n"
         "    p { color:#c8c8c8; }\n"
         "    .meta { display:flex; gap:18px; flex-wrap:wrap; margin:16px 0; }\n"
         "    .chip { background:#171717; border:1px solid #303030; border-radius:999px; padding:8px 14px; }\n"
         "    .viewer { background:#111; border:1px solid #303030; border-radius:16px; padding:18px; }\n"
         "    img { width:100%; height:auto; display:block; image-rendering:auto; background:#000; border-radius:12px; }\n"
         "    .controls { display:flex; align-items:center; gap:12px; margin-top:14px; flex-wrap:wrap; }\n"
         "    button { background:#202020; color:#efefef; border:1px solid #404040; border-radius:10px; padding:8px 14px; cursor:pointer; }\n"
         "    button:hover { background:#2a2a2a; }\n"
         "  </style>\n"
         "</head>\n"
         "<body>\n"
         "  <div class=\"wrap\">\n"
         "    <h1>Ghost Car Viewer</h1>\n"
         "    <div class=\"meta\">\n"
      << "      <div class=\"chip\">Reference: " << options.reference_label << "</div>\n"
      << "      <div class=\"chip\">Compare: " << options.compare_label << "</div>\n"
      << (options.session_label.empty() ? std::string() : std::string("      <div class=\"chip\">Session: ") + options.session_label + "</div>\n")
      << (options.reference_lap_label.empty() ? std::string() : std::string("      <div class=\"chip\">Ref lap: ") + options.reference_lap_label + "</div>\n")
      << (options.compare_lap_label.empty() ? std::string() : std::string("      <div class=\"chip\">Cmp lap: ") + options.compare_lap_label + "</div>\n")
      << "      <div class=\"chip\">Frames: " << num_frames << "</div>\n"
         "    </div>\n"
         "    <div class=\"viewer\">\n"
         "      <img id=\"frame\" src=\"frame_0.bmp\" alt=\"Ghost car animation frame\">\n"
         "      <div class=\"controls\">\n"
         "        <button id=\"toggle\">Pause</button>\n"
         "        <span id=\"status\">Frame 1 / "
      << num_frames
      << "</span>\n"
         "      </div>\n"
         "    </div>\n"
         "  </div>\n"
         "  <script>\n"
      << "    const totalFrames = " << num_frames << ";\n"
      << "    const delayMs = " << frame_delay_ms << ";\n"
         "    const img = document.getElementById('frame');\n"
         "    const status = document.getElementById('status');\n"
         "    const toggle = document.getElementById('toggle');\n"
         "    let frame = 0;\n"
         "    let playing = true;\n"
         "    function renderFrame() {\n"
         "      img.src = `frame_${frame}.bmp`;\n"
         "      status.textContent = `Frame ${frame + 1} / ${totalFrames}`;\n"
         "    }\n"
         "    function tick() {\n"
         "      if (!playing) return;\n"
         "      frame = (frame + 1) % totalFrames;\n"
         "      renderFrame();\n"
         "    }\n"
         "    toggle.addEventListener('click', () => {\n"
         "      playing = !playing;\n"
         "      toggle.textContent = playing ? 'Pause' : 'Play';\n"
         "    });\n"
         "    renderFrame();\n"
         "    setInterval(tick, delayMs);\n"
         "  </script>\n"
         "</body>\n"
         "</html>\n";
}

void run_prototype_ui(const lap::DeltaResult& delta, const UiOptions& options) {
  std::filesystem::create_directories("output");

  std::cout << "Prototype settings:\n"
            << "  smoothing: " << (options.smoothing ? "on" : "off") << "\n";

  const std::size_t num_frames = 300;
  constexpr int frame_delay_ms = 100;
  const float max_time_s = std::min(delta.reference.t.back(), delta.compare.t.back());
  for (std::size_t frame = 0; frame < num_frames; ++frame) {
    const float frame_time_s = max_time_s * static_cast<float>(frame) / static_cast<float>(num_frames - 1);
    auto image = render::render_track_frame(
        delta,
        frame_time_s,
        options.reference_label,
        options.compare_label,
        options.telemetry_overlay_speed,
        options.telemetry_overlay_brake,
        800,
        600);
    const std::string bmp_path = "output/frame_" + std::to_string(frame) + ".bmp";
    render::write_bmp(image, bmp_path);
  }

  write_html_viewer("output/viewer.html", num_frames, frame_delay_ms, options);

  std::cout << "Wrote " << num_frames
            << " rendered frames to ./output (BMP) and wrote ./output/viewer.html.\n";
}

}  // namespace ui
