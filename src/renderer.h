#pragma once

#include "lap_processing.cuh"

#include <cstddef>
#include <string>
#include <vector>

namespace render {

struct RGB {
  unsigned char r;
  unsigned char g;
  unsigned char b;
};

struct Image {
  int width;
  int height;
  std::vector<RGB> pixels;
};

Image render_track_frame(const lap::DeltaResult& delta,
                         float frame_time_s,
                         const std::string& reference_label,
                         const std::string& compare_label,
                         int width,
                         int height);

void write_ppm(const Image& image, const std::string& path);
void write_bmp(const Image& image, const std::string& path);

}  // namespace render
