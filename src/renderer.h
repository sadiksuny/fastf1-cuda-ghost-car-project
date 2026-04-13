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
                         std::size_t ghost_index,
                         int width,
                         int height);

void write_ppm(const Image& image, const std::string& path);

}  // namespace render
