#pragma once

#include "lap_processing.cuh"

#include <cstddef>
#include <string>
#include <vector>

namespace render {

// Compact host-side pixel type used after the CUDA renderer returns an RGB byte
// buffer. This keeps file output code straightforward and independent of CUDA.
struct RGB {
  unsigned char r;
  unsigned char g;
  unsigned char b;
};

// Plain in-memory image container used by the BMP writer and any future host
// side post-processing.
struct Image {
  int width;
  int height;
  std::vector<RGB> pixels;
};

// Builds a single replay frame. The heavy compositing work happens in CUDA; the
// host-side renderer mainly resolves the current marker positions in time and
// packages the returned bytes into an Image object.
Image render_track_frame(const lap::DeltaResult& delta,
                         float frame_time_s,
                         const std::string& reference_label,
                         const std::string& compare_label,
                         bool overlay_speed,
                         bool overlay_brake,
                         int width,
                         int height);

// Writes a simple 24-bit BMP so the generated frames can be opened on any
// standard desktop install without extra codecs or image libraries.
void write_bmp(const Image& image, const std::string& path);

}  // namespace render
