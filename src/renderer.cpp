#include "renderer.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace render {
namespace {

constexpr RGB kBackground{10, 10, 10};
constexpr RGB kPanelFill{18, 18, 18};
constexpr RGB kPanelOutline{220, 220, 220};
constexpr RGB kText{240, 240, 240};
constexpr RGB kReferenceMarker{0, 255, 0};
constexpr RGB kCompareMarker{255, 255, 0};
constexpr RGB kFastLabel{170, 210, 255};
constexpr RGB kSlowLabel{255, 190, 190};
constexpr RGB kLeadPanelFill{16, 16, 16};

RGB lerp_color(float v) {
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
  img.pixels[static_cast<std::size_t>(y * img.width + x)] = c;
}

void draw_rect(Image& img, int x0, int y0, int x1, int y1, RGB c) {
  for (int y = y0; y <= y1; ++y) {
    for (int x = x0; x <= x1; ++x) {
      put_pixel(img, x, y, c);
    }
  }
}

void draw_rect_outline(Image& img, int x0, int y0, int x1, int y1, RGB c) {
  for (int x = x0; x <= x1; ++x) {
    put_pixel(img, x, y0, c);
    put_pixel(img, x, y1, c);
  }
  for (int y = y0; y <= y1; ++y) {
    put_pixel(img, x0, y, c);
    put_pixel(img, x1, y, c);
  }
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

void draw_ring(Image& img, int cx, int cy, int outer_radius, int inner_radius, RGB c) {
  for (int y = -outer_radius; y <= outer_radius; ++y) {
    for (int x = -outer_radius; x <= outer_radius; ++x) {
      const int dist2 = x * x + y * y;
      if (dist2 <= outer_radius * outer_radius && dist2 >= inner_radius * inner_radius) {
        put_pixel(img, cx + x, cy + y, c);
      }
    }
  }
}

std::array<unsigned char, 7> glyph_for(char ch) {
  switch (ch) {
    case 'A': return {0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11};
    case 'B': return {0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E};
    case 'C': return {0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E};
    case 'D': return {0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E};
    case 'E': return {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F};
    case 'F': return {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10};
    case 'G': return {0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E};
    case 'H': return {0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11};
    case 'I': return {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1F};
    case 'J': return {0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0E};
    case 'K': return {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11};
    case 'L': return {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F};
    case 'M': return {0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11};
    case 'N': return {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11};
    case 'O': return {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E};
    case 'P': return {0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10};
    case 'Q': return {0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D};
    case 'R': return {0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11};
    case 'S': return {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E};
    case 'T': return {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04};
    case 'U': return {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E};
    case 'V': return {0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04};
    case 'W': return {0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A};
    case 'X': return {0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11};
    case 'Y': return {0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04};
    case 'Z': return {0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F};
    case '0': return {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E};
    case '1': return {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E};
    case '2': return {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F};
    case '3': return {0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E};
    case '4': return {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02};
    case '5': return {0x1F, 0x10, 0x10, 0x1E, 0x01, 0x01, 0x1E};
    case '6': return {0x0E, 0x10, 0x10, 0x1E, 0x11, 0x11, 0x0E};
    case '7': return {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08};
    case '8': return {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E};
    case '9': return {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x01, 0x0E};
    case '-': return {0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00};
    case '_': return {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F};
    case ' ': return {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    default: return {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
  }
}

void draw_char(Image& img, int x, int y, char ch, RGB c, int scale = 2) {
  const auto glyph = glyph_for(ch);
  for (int row = 0; row < 7; ++row) {
    for (int col = 0; col < 5; ++col) {
      if ((glyph[row] >> (4 - col)) & 0x1) {
        draw_rect(
            img,
            x + col * scale,
            y + row * scale,
            x + col * scale + scale - 1,
            y + row * scale + scale - 1,
            c);
      }
    }
  }
}

void draw_text(Image& img, int x, int y, const std::string& text, RGB c, int scale = 2) {
  int pen_x = x;
  for (char ch : text) {
    draw_char(img, pen_x, y, ch, c, scale);
    pen_x += 6 * scale;
  }
}

std::string make_display_label(const std::string& text, std::size_t max_chars) {
  std::string out;
  out.reserve(max_chars);
  for (char ch : text) {
    if (out.size() >= max_chars) {
      break;
    }
    if (std::isalnum(static_cast<unsigned char>(ch)) || ch == '-' || ch == '_' || ch == ' ') {
      out.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(ch))));
    }
  }
  if (out.empty()) {
    out = "CAR";
  }
  return out;
}

void draw_legend(Image& img, const std::string& reference_label, const std::string& compare_label) {
  const int left = 16;
  const int top = 16;
  const int right = 276;
  const int bottom = 156;
  draw_rect(img, left, top, right, bottom, kPanelFill);
  draw_rect_outline(img, left, top, right, bottom, kPanelOutline);

  draw_text(img, left + 12, top + 10, "DELTA", kText);

  draw_dot(img, left + 22, top + 50, 6, kReferenceMarker);
  draw_text(img, left + 38, top + 41, make_display_label(reference_label, 10), kText);

  draw_dot(img, left + 22, top + 78, 6, kCompareMarker);
  draw_text(img, left + 38, top + 69, make_display_label(compare_label, 10), kText);

  const int bar_left = left + 12;
  const int bar_top = top + 104;
  const int bar_width = 150;
  const int bar_height = 12;
  for (int x = 0; x < bar_width; ++x) {
    const float t = static_cast<float>(x) / static_cast<float>(std::max(1, bar_width - 1));
    const float normalized = (2.0f * t) - 1.0f;
    draw_rect(img, bar_left + x, bar_top, bar_left + x, bar_top + bar_height, lerp_color(normalized));
  }
  draw_rect_outline(img, bar_left, bar_top, bar_left + bar_width, bar_top + bar_height, kPanelOutline);
  draw_text(img, bar_left, bar_top + 20, "FAST", kFastLabel);
  draw_text(img, bar_left + 84, bar_top + 20, "SLOW", kSlowLabel);
}

void draw_lead_banner(Image& img,
                      const std::string& reference_label,
                      const std::string& compare_label,
                      float delta_t_value) {
  const std::string ref = make_display_label(reference_label, 10);
  const std::string cmp = make_display_label(compare_label, 10);

  std::string leader = ref;
  RGB accent = kReferenceMarker;
  float magnitude = delta_t_value;
  if (delta_t_value < 0.0f) {
    leader = cmp;
    accent = kCompareMarker;
    magnitude = -delta_t_value;
  }

  const int hundredths = static_cast<int>(magnitude * 100.0f + 0.5f);
  const int seconds = hundredths / 100;
  const int fractional = hundredths % 100;

  std::string time_text = std::to_string(seconds) + ".";
  if (fractional < 10) {
    time_text += "0";
  }
  time_text += std::to_string(fractional) + "S";

  const std::string line1 = leader + " AHEAD";
  const std::string line2 = "BY " + time_text;

  const int scale = 2;
  const int panel_width = 196;
  const int panel_height = 52;
  const int left = img.width - panel_width - 20;
  const int top = 20;
  draw_rect(img, left, top, left + panel_width, top + panel_height, kLeadPanelFill);
  draw_rect_outline(img, left, top, left + panel_width, top + panel_height, accent);
  draw_text(img, left + 10, top + 8, line1, accent, scale);
  draw_text(img, left + 10, top + 28, line2, kText, scale);
}

void draw_marker_label(Image& img,
                       int anchor_x,
                       int anchor_y,
                       const std::string& label,
                       int dx,
                       int dy,
                       RGB marker_color) {
  const std::string display = make_display_label(label, 10);
  const int scale = 2;
  const int text_width = static_cast<int>(display.size()) * 6 * scale;
  const int text_height = 7 * scale;
  const int padding = 4;

  int left = anchor_x + dx;
  int top = anchor_y + dy;
  if (left + text_width + (2 * padding) >= img.width) {
    left = anchor_x - text_width - (2 * padding) - 10;
  }
  if (top < 4) {
    top = anchor_y + 10;
  }

  const int right = left + text_width + (2 * padding);
  const int bottom = top + text_height + (2 * padding);
  draw_rect(img, left, top, right, bottom, kPanelFill);
  draw_rect_outline(img, left, top, right, bottom, marker_color);
  draw_text(img, left + padding, top + padding, display, kText, scale);
}

void write_u16(std::ofstream& out, std::uint16_t value) {
  out.put(static_cast<char>(value & 0xFF));
  out.put(static_cast<char>((value >> 8) & 0xFF));
}

}  // namespace

Image render_track_frame(const lap::DeltaResult& delta,
                         float frame_time_s,
                         const std::string& reference_label,
                         const std::string& compare_label,
                         int width,
                         int height) {
  Image image{width, height, std::vector<RGB>(static_cast<std::size_t>(width * height), kBackground)};

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

  auto [ref_x, ref_y] = sample_position_at_time(delta.reference, frame_time_s);
  auto [cmp_x, cmp_y] = sample_position_at_time(delta.compare, frame_time_s);
  auto [ref_px, ref_py] = to_px(ref_x, ref_y);
  auto [cmp_px, cmp_py] = to_px(cmp_x, cmp_y);

  auto sample_delta_at_time = [&]() {
    if (delta.reference.t.empty() || delta.delta_t.empty()) {
      return 0.0f;
    }
    auto upper_it = std::lower_bound(delta.reference.t.begin(), delta.reference.t.end(), frame_time_s);
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
    const float alpha = (t1 > t0) ? ((frame_time_s - t0) / (t1 - t0)) : 0.0f;
    return delta.delta_t[lower] + alpha * (delta.delta_t[upper] - delta.delta_t[lower]);
  };

  // Draw the reference marker as a ring so it remains visible even when the compare
  // marker sits on top of the same pixel position.
  draw_ring(image, ref_px, ref_py, 7, 4, kReferenceMarker);
  draw_dot(image, cmp_px, cmp_py, 4, kCompareMarker);

  const int dx = cmp_px - ref_px;
  const int dy = cmp_py - ref_py;
  const bool overlapping = (dx * dx + dy * dy) < (14 * 14);

  if (overlapping) {
    draw_marker_label(image, ref_px, ref_py, reference_label, 10, -28, kReferenceMarker);
    draw_marker_label(image, cmp_px, cmp_py, compare_label, 10, 12, kCompareMarker);
  } else {
    draw_marker_label(image, ref_px, ref_py, reference_label, 10, -18, kReferenceMarker);
    draw_marker_label(image, cmp_px, cmp_py, compare_label, 10, -18, kCompareMarker);
  }
  draw_legend(image, reference_label, compare_label);
  draw_lead_banner(image, reference_label, compare_label, sample_delta_at_time());

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

void write_bmp(const Image& image, const std::string& path) {
  const int row_stride = image.width * 3;
  const int padded_stride = (row_stride + 3) & ~3;
  const int pixel_bytes = padded_stride * image.height;
  const std::uint32_t file_size = 14 + 40 + static_cast<std::uint32_t>(pixel_bytes);

  std::ofstream out(path, std::ios::binary);
  if (!out.is_open()) {
    throw std::runtime_error("Failed to open BMP output: " + path);
  }

  out.put('B');
  out.put('M');
  out.put(static_cast<char>(file_size & 0xFF));
  out.put(static_cast<char>((file_size >> 8) & 0xFF));
  out.put(static_cast<char>((file_size >> 16) & 0xFF));
  out.put(static_cast<char>((file_size >> 24) & 0xFF));
  write_u16(out, 0);
  write_u16(out, 0);
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
  write_u16(out, 1);
  write_u16(out, 24);
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
