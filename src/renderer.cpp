#include "renderer.h"

#include <algorithm>
#include <fstream>
#include <stdexcept>

namespace render {
namespace {

RGB lerp_color(float v) {
  // Blue (faster compare) -> white -> red (slower compare)
  const float clamped = std::max(-1.0f, std::min(1.0f, v));
  if (clamped < 0.0f) {
    const float a = clamped + 1.0f;
    return RGB{static_cast<unsigned char>(255.0f * a), static_cast<unsigned char>(255.0f * a), 255};
  }
  const float a = 1.0f - clamped;
  return RGB{255, static_cast<unsigned char>(255.0f * a), static_cast<unsigned char>(255.0f * a)};
}

void put_pixel(Image& img, int x, int y, RGB c) {
  if (x < 0 || x >= img.width || y < 0 || y >= img.height) {
    return;
  }
  img.pixels[y * img.width + x] = c;
}

void draw_dot(Image& img, int cx, int cy, int radius, RGB c) {
  for (int y = -radius; y <= radius; ++y) {
    for (int x = -radius; x <= radius; ++x) {
      if (x * x + y * y <= radius * radius) {
        put_pixel(img, cx + x, cy + y, c);
      }
    }
  }
}

}  // namespace

Image render_track_frame(const lap::DeltaResult& delta,
                         std::size_t ghost_index,
                         int width,
                         int height) {
  Image image{width, height, std::vector<RGB>(static_cast<std::size_t>(width * height), RGB{10, 10, 10})};

  const auto minmax_x = std::minmax_element(delta.reference.x.begin(), delta.reference.x.end());
  const auto minmax_y = std::minmax_element(delta.reference.y.begin(), delta.reference.y.end());

  const float min_x = *minmax_x.first;
  const float max_x = *minmax_x.second;
  const float min_y = *minmax_y.first;
  const float max_y = *minmax_y.second;

  const float scale_x = (width - 20) / std::max(1e-3f, (max_x - min_x));
  const float scale_y = (height - 20) / std::max(1e-3f, (max_y - min_y));

  auto to_px = [&](float x, float y) {
    const int px = 10 + static_cast<int>((x - min_x) * scale_x);
    const int py = 10 + static_cast<int>((y - min_y) * scale_y);
    return std::pair<int, int>{px, py};
  };

  float abs_max_delta = 1e-3f;
  for (float d : delta.delta_t) {
    abs_max_delta = std::max(abs_max_delta, std::abs(d));
  }

  for (std::size_t i = 0; i < delta.reference.x.size(); ++i) {
    auto [px, py] = to_px(delta.reference.x[i], delta.reference.y[i]);
    const float normalized = delta.delta_t[i] / abs_max_delta;
    draw_dot(image, px, py, 2, lerp_color(normalized));
  }

  const std::size_t idx = std::min(ghost_index, delta.reference.x.size() - 1);
  auto [ref_px, ref_py] = to_px(delta.reference.x[idx], delta.reference.y[idx]);
  auto [cmp_px, cmp_py] = to_px(delta.compare.x[idx], delta.compare.y[idx]);

  draw_dot(image, ref_px, ref_py, 4, RGB{0, 255, 0});
  draw_dot(image, cmp_px, cmp_py, 4, RGB{255, 255, 0});

  return image;
}

void write_ppm(const Image& image, const std::string& path) {
  std::ofstream out(path, std::ios::binary);
  if (!out.is_open()) {
    throw std::runtime_error("Failed to open image output: " + path);
  }

  out << "P6\n" << image.width << " " << image.height << "\n255\n";
  out.write(reinterpret_cast<const char*>(image.pixels.data()), static_cast<std::streamsize>(image.pixels.size() * sizeof(RGB)));
}

}  // namespace render
