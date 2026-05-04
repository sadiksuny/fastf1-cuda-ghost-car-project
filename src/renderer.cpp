#include "renderer.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace render {

Image render_track_frame(const lap::DeltaResult& delta,
                         float frame_time_s,
                         const std::string& reference_label,
                         const std::string& compare_label,
                         bool overlay_speed,
                         bool overlay_brake,
                         int width,
                         int height) {
  // The replay is defined in time rather than by raw sample index. This keeps
  // the visual notion of "ahead" aligned with the lead banner and the actual
  // track position of each driver.
  auto sample_position_at_time = [](const lap::ResampledLap& lap_data, float time_s) {
    if (lap_data.t.empty()) {
      return std::pair<float, float>{0.0f, 0.0f};
    }

    auto upper_it = std::lower_bound(lap_data.t.begin(), lap_data.t.end(), time_s);
    if (upper_it == lap_data.t.begin()) {
      return std::pair<float, float>{lap_data.x.front(), lap_data.y.front()};
    }
    if (upper_it == lap_data.t.end()) {
      return std::pair<float, float>{lap_data.x.back(), lap_data.y.back()};
    }

    const std::size_t upper = static_cast<std::size_t>(upper_it - lap_data.t.begin());
    const std::size_t lower = upper - 1;
    const float t0 = lap_data.t[lower];
    const float t1 = lap_data.t[upper];
    const float alpha = (t1 > t0) ? ((time_s - t0) / (t1 - t0)) : 0.0f;
    const float x = lap_data.x[lower] + alpha * (lap_data.x[upper] - lap_data.x[lower]);
    const float y = lap_data.y[lower] + alpha * (lap_data.y[upper] - lap_data.y[lower]);
    return std::pair<float, float>{x, y};
  };

  auto sample_delta_at_time = [&](float time_s) {
    if (delta.reference.t.empty() || delta.delta_t.empty()) {
      return 0.0f;
    }
    auto upper_it = std::lower_bound(delta.reference.t.begin(), delta.reference.t.end(), time_s);
    if (upper_it == delta.reference.t.begin()) {
      return delta.delta_t.front();
    }
    if (upper_it == delta.reference.t.end()) {
      return delta.delta_t.back();
    }

    const std::size_t upper = static_cast<std::size_t>(upper_it - delta.reference.t.begin());
    const std::size_t lower = upper - 1;
    const float t0 = delta.reference.t[lower];
    const float t1 = delta.reference.t[upper];
    const float alpha = (t1 > t0) ? ((time_s - t0) / (t1 - t0)) : 0.0f;
    return delta.delta_t[lower] + alpha * (delta.delta_t[upper] - delta.delta_t[lower]);
  };

  const auto [ref_x, ref_y] = sample_position_at_time(delta.reference, frame_time_s);
  const auto [cmp_x, cmp_y] = sample_position_at_time(delta.compare, frame_time_s);
  const float delta_t_value = sample_delta_at_time(frame_time_s);

  // The CUDA renderer expects both the track-aligned lap data and the current
  // marker state for the requested frame.
  const auto gpu_image = lap::render_frame_cuda(
      delta,
      frame_time_s,
      reference_label,
      compare_label,
      ref_x,
      ref_y,
      cmp_x,
      cmp_y,
      delta_t_value,
      width,
      height,
      overlay_speed,
      overlay_brake);

  Image image{width, height, std::vector<RGB>(static_cast<std::size_t>(width * height))};
  for (std::size_t i = 0; i < image.pixels.size(); ++i) {
    image.pixels[i] = RGB{
        gpu_image[i * 3 + 0],
        gpu_image[i * 3 + 1],
        gpu_image[i * 3 + 2],
    };
  }

  return image;
}

void write_bmp(const Image& image, const std::string& path) {
  // BMP is intentionally simple: no external dependencies, predictable binary
  // layout, and broad default support on Windows.
  const int row_stride = image.width * 3;
  const int padded_stride = (row_stride + 3) & ~3;
  const int pixel_bytes = padded_stride * image.height;
  const std::uint32_t file_size = 14 + 40 + static_cast<std::uint32_t>(pixel_bytes);

  std::ofstream out(path, std::ios::binary);
  if (!out.is_open()) {
    throw std::runtime_error("Failed to open BMP output: " + path);
  }

  auto write_u16 = [&](std::uint16_t value) {
    out.put(static_cast<char>(value & 0xFF));
    out.put(static_cast<char>((value >> 8) & 0xFF));
  };

  out.put('B');
  out.put('M');
  out.put(static_cast<char>(file_size & 0xFF));
  out.put(static_cast<char>((file_size >> 8) & 0xFF));
  out.put(static_cast<char>((file_size >> 16) & 0xFF));
  out.put(static_cast<char>((file_size >> 24) & 0xFF));
  write_u16(0);
  write_u16(0);
  out.put(54);
  out.put(0);
  out.put(0);
  out.put(0);

  out.put(40);
  out.put(0);
  out.put(0);
  out.put(0);
  out.put(static_cast<char>(image.width & 0xFF));
  out.put(static_cast<char>((image.width >> 8) & 0xFF));
  out.put(static_cast<char>((image.width >> 16) & 0xFF));
  out.put(static_cast<char>((image.width >> 24) & 0xFF));
  out.put(static_cast<char>(image.height & 0xFF));
  out.put(static_cast<char>((image.height >> 8) & 0xFF));
  out.put(static_cast<char>((image.height >> 16) & 0xFF));
  out.put(static_cast<char>((image.height >> 24) & 0xFF));
  write_u16(1);
  write_u16(24);
  out.put(0);
  out.put(0);
  out.put(0);
  out.put(0);
  out.put(static_cast<char>(pixel_bytes & 0xFF));
  out.put(static_cast<char>((pixel_bytes >> 8) & 0xFF));
  out.put(static_cast<char>((pixel_bytes >> 16) & 0xFF));
  out.put(static_cast<char>((pixel_bytes >> 24) & 0xFF));
  for (int i = 0; i < 16; ++i) {
    out.put(0);
  }

  std::vector<unsigned char> row(static_cast<std::size_t>(padded_stride), 0);
  for (int y = image.height - 1; y >= 0; --y) {
    std::fill(row.begin(), row.end(), 0);
    for (int x = 0; x < image.width; ++x) {
      const auto& pixel = image.pixels[static_cast<std::size_t>(y * image.width + x)];
      const int offset = x * 3;
      row[static_cast<std::size_t>(offset + 0)] = pixel.b;
      row[static_cast<std::size_t>(offset + 1)] = pixel.g;
      row[static_cast<std::size_t>(offset + 2)] = pixel.r;
    }
    out.write(reinterpret_cast<const char*>(row.data()), static_cast<std::streamsize>(row.size()));
  }
}

}  // namespace render
