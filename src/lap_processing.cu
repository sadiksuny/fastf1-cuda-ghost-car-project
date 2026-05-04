#include "lap_processing.cuh"

#include <cuda_runtime.h>
#include <thrust/device_ptr.h>
#include <thrust/scan.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <stdexcept>
#include <string>

namespace lap {
namespace {

// Centralized CUDA error handling keeps every host-side launch/copy site
// readable while still surfacing meaningful diagnostics to the caller.
inline void cuda_check(cudaError_t status, const char* context) {
  if (status != cudaSuccess) {
    throw std::runtime_error(std::string(context) + ": " + cudaGetErrorString(status));
  }
}

// Converts per-sample positions into segment lengths so an inclusive scan can
// build cumulative distance for the whole lap.
__global__ void segment_lengths_kernel(const float* x, const float* y, float* segment_lengths, int n) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= n) {
    return;
  }

  if (idx == 0) {
    segment_lengths[0] = 0.0f;
    return;
  }

  const float dx = x[idx] - x[idx - 1];
  const float dy = y[idx] - y[idx - 1];
  segment_lengths[idx] = sqrtf(dx * dx + dy * dy);
}

// Device-side lower_bound lets each resampling thread locate the source segment
// that brackets its target distance value.
__device__ int lower_bound_device(const float* arr, int n, float value) {
  int left = 0;
  int right = n;
  while (left < right) {
    const int mid = left + (right - left) / 2;
    if (arr[mid] < value) {
      left = mid + 1;
    } else {
      right = mid;
    }
  }
  return left;
}

// Resamples all lap channels onto a shared distance grid. Carrying speed,
// throttle, and brake through this step means the renderer can treat them as
// time-aligned overlays later.
__global__ void resample_kernel(const float* source_s,
                                const float* source_x,
                                const float* source_y,
                                const float* source_t,
                                const float* source_speed,
                                const float* source_throttle,
                                const float* source_brake,
                                int source_n,
                                const float* grid_s,
                                float* out_x,
                                float* out_y,
                                float* out_t,
                                float* out_speed,
                                float* out_throttle,
                                float* out_brake,
                                int grid_n) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= grid_n) {
    return;
  }

  const float s = grid_s[idx];
  const int upper = lower_bound_device(source_s, source_n, s);

  if (upper <= 0) {
    out_x[idx] = source_x[0];
    out_y[idx] = source_y[0];
    out_t[idx] = source_t[0];
    out_speed[idx] = source_speed[0];
    out_throttle[idx] = source_throttle[0];
    out_brake[idx] = source_brake[0];
    return;
  }
  if (upper >= source_n) {
    out_x[idx] = source_x[source_n - 1];
    out_y[idx] = source_y[source_n - 1];
    out_t[idx] = source_t[source_n - 1];
    out_speed[idx] = source_speed[source_n - 1];
    out_throttle[idx] = source_throttle[source_n - 1];
    out_brake[idx] = source_brake[source_n - 1];
    return;
  }

  const int lower = upper - 1;
  const float s0 = source_s[lower];
  const float s1 = source_s[upper];
  const float alpha = (s1 > s0) ? ((s - s0) / (s1 - s0)) : 0.0f;

  out_x[idx] = source_x[lower] + alpha * (source_x[upper] - source_x[lower]);
  out_y[idx] = source_y[lower] + alpha * (source_y[upper] - source_y[lower]);
  out_t[idx] = source_t[lower] + alpha * (source_t[upper] - source_t[lower]);
  out_speed[idx] = source_speed[lower] + alpha * (source_speed[upper] - source_speed[lower]);
  out_throttle[idx] = source_throttle[lower] + alpha * (source_throttle[upper] - source_throttle[lower]);
  out_brake[idx] = source_brake[lower] + alpha * (source_brake[upper] - source_brake[lower]);
}

// The delta curve is defined as compare minus reference, which keeps positive
// values aligned with compare being slower.
__global__ void delta_kernel(const float* cmp_t, const float* ref_t, float* delta_t, int n) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= n) {
    return;
  }
  delta_t[idx] = cmp_t[idx] - ref_t[idx];
}

// Clears the RGB frame to a neutral dark background before the track and
// overlays are painted.
__global__ void clear_image_kernel(unsigned char* image, int pixel_count) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= pixel_count) {
    return;
  }
  image[idx * 3 + 0] = 10;
  image[idx * 3 + 1] = 10;
  image[idx * 3 + 2] = 10;
}

// Shared primitive used by all device-side drawing helpers.
__device__ void set_rgb(unsigned char* image, int width, int height, int x, int y,
                        unsigned char r, unsigned char g, unsigned char b) {
  if (x < 0 || x >= width || y < 0 || y >= height) {
    return;
  }
  const int pixel = (y * width + x) * 3;
  image[pixel + 0] = r;
  image[pixel + 1] = g;
  image[pixel + 2] = b;
}

// Maps signed delta values onto the project's blue-to-red comparison palette.
__device__ void lerp_color_device(float v, unsigned char& r, unsigned char& g, unsigned char& b) {
  const float clamped = fmaxf(-1.0f, fminf(1.0f, v));
  if (clamped < 0.0f) {
    const float a = clamped + 1.0f;
    r = static_cast<unsigned char>(255.0f * a);
    g = static_cast<unsigned char>(255.0f * a);
    b = 255;
    return;
  }
  const float a = 1.0f - clamped;
  r = 255;
  g = static_cast<unsigned char>(255.0f * a);
  b = static_cast<unsigned char>(255.0f * a);
}

// The following draw_* helpers intentionally keep the CUDA overlay path
// self-contained. That avoids a second CPU compositing pass for text, legend,
// and marker annotations.
__device__ void draw_rect_device(unsigned char* image, int width, int height,
                                 int x0, int y0, int x1, int y1,
                                 unsigned char r, unsigned char g, unsigned char b) {
  for (int y = y0; y <= y1; ++y) {
    for (int x = x0; x <= x1; ++x) {
      set_rgb(image, width, height, x, y, r, g, b);
    }
  }
}

__device__ void draw_rect_outline_device(unsigned char* image, int width, int height,
                                         int x0, int y0, int x1, int y1,
                                         unsigned char r, unsigned char g, unsigned char b) {
  for (int x = x0; x <= x1; ++x) {
    set_rgb(image, width, height, x, y0, r, g, b);
    set_rgb(image, width, height, x, y1, r, g, b);
  }
  for (int y = y0; y <= y1; ++y) {
    set_rgb(image, width, height, x0, y, r, g, b);
    set_rgb(image, width, height, x1, y, r, g, b);
  }
}

__device__ void draw_dot_device(unsigned char* image, int width, int height,
                                int cx, int cy, int radius,
                                unsigned char r, unsigned char g, unsigned char b) {
  for (int y = -radius; y <= radius; ++y) {
    for (int x = -radius; x <= radius; ++x) {
      if (x * x + y * y <= radius * radius) {
        set_rgb(image, width, height, cx + x, cy + y, r, g, b);
      }
    }
  }
}

__device__ void draw_ring_device(unsigned char* image, int width, int height,
                                 int cx, int cy, int outer_radius, int inner_radius,
                                 unsigned char r, unsigned char g, unsigned char b) {
  for (int y = -outer_radius; y <= outer_radius; ++y) {
    for (int x = -outer_radius; x <= outer_radius; ++x) {
      const int dist2 = x * x + y * y;
      if (dist2 <= outer_radius * outer_radius && dist2 >= inner_radius * inner_radius) {
        set_rgb(image, width, height, cx + x, cy + y, r, g, b);
      }
    }
  }
}

__device__ unsigned char glyph_row_for(char ch, int row) {
  const unsigned char blank[7] = {0, 0, 0, 0, 0, 0, 0};
  switch (ch) {
    case 'A': { const unsigned char g[7] = {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11}; return g[row]; }
    case 'B': { const unsigned char g[7] = {0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E}; return g[row]; }
    case 'C': { const unsigned char g[7] = {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E}; return g[row]; }
    case 'D': { const unsigned char g[7] = {0x1E,0x11,0x11,0x11,0x11,0x11,0x1E}; return g[row]; }
    case 'E': { const unsigned char g[7] = {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F}; return g[row]; }
    case 'F': { const unsigned char g[7] = {0x1F,0x10,0x10,0x1E,0x10,0x10,0x10}; return g[row]; }
    case 'G': { const unsigned char g[7] = {0x0E,0x11,0x10,0x17,0x11,0x11,0x0E}; return g[row]; }
    case 'H': { const unsigned char g[7] = {0x11,0x11,0x11,0x1F,0x11,0x11,0x11}; return g[row]; }
    case 'I': { const unsigned char g[7] = {0x1F,0x04,0x04,0x04,0x04,0x04,0x1F}; return g[row]; }
    case 'J': { const unsigned char g[7] = {0x01,0x01,0x01,0x01,0x11,0x11,0x0E}; return g[row]; }
    case 'K': { const unsigned char g[7] = {0x11,0x12,0x14,0x18,0x14,0x12,0x11}; return g[row]; }
    case 'L': { const unsigned char g[7] = {0x10,0x10,0x10,0x10,0x10,0x10,0x1F}; return g[row]; }
    case 'M': { const unsigned char g[7] = {0x11,0x1B,0x15,0x15,0x11,0x11,0x11}; return g[row]; }
    case 'N': { const unsigned char g[7] = {0x11,0x19,0x15,0x13,0x11,0x11,0x11}; return g[row]; }
    case 'O': { const unsigned char g[7] = {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E}; return g[row]; }
    case 'P': { const unsigned char g[7] = {0x1E,0x11,0x11,0x1E,0x10,0x10,0x10}; return g[row]; }
    case 'Q': { const unsigned char g[7] = {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D}; return g[row]; }
    case 'R': { const unsigned char g[7] = {0x1E,0x11,0x11,0x1E,0x14,0x12,0x11}; return g[row]; }
    case 'S': { const unsigned char g[7] = {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E}; return g[row]; }
    case 'T': { const unsigned char g[7] = {0x1F,0x04,0x04,0x04,0x04,0x04,0x04}; return g[row]; }
    case 'U': { const unsigned char g[7] = {0x11,0x11,0x11,0x11,0x11,0x11,0x0E}; return g[row]; }
    case 'V': { const unsigned char g[7] = {0x11,0x11,0x11,0x11,0x11,0x0A,0x04}; return g[row]; }
    case 'W': { const unsigned char g[7] = {0x11,0x11,0x11,0x15,0x15,0x15,0x0A}; return g[row]; }
    case 'X': { const unsigned char g[7] = {0x11,0x11,0x0A,0x04,0x0A,0x11,0x11}; return g[row]; }
    case 'Y': { const unsigned char g[7] = {0x11,0x11,0x0A,0x04,0x04,0x04,0x04}; return g[row]; }
    case 'Z': { const unsigned char g[7] = {0x1F,0x01,0x02,0x04,0x08,0x10,0x1F}; return g[row]; }
    case '0': { const unsigned char g[7] = {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}; return g[row]; }
    case '1': { const unsigned char g[7] = {0x04,0x0C,0x04,0x04,0x04,0x04,0x0E}; return g[row]; }
    case '2': { const unsigned char g[7] = {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F}; return g[row]; }
    case '3': { const unsigned char g[7] = {0x1E,0x01,0x01,0x0E,0x01,0x01,0x1E}; return g[row]; }
    case '4': { const unsigned char g[7] = {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}; return g[row]; }
    case '5': { const unsigned char g[7] = {0x1F,0x10,0x10,0x1E,0x01,0x01,0x1E}; return g[row]; }
    case '6': { const unsigned char g[7] = {0x0E,0x10,0x10,0x1E,0x11,0x11,0x0E}; return g[row]; }
    case '7': { const unsigned char g[7] = {0x1F,0x01,0x02,0x04,0x08,0x08,0x08}; return g[row]; }
    case '8': { const unsigned char g[7] = {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E}; return g[row]; }
    case '9': { const unsigned char g[7] = {0x0E,0x11,0x11,0x0F,0x01,0x01,0x0E}; return g[row]; }
    case '.': { const unsigned char g[7] = {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C}; return g[row]; }
    case '+': { const unsigned char g[7] = {0x00,0x04,0x04,0x1F,0x04,0x04,0x00}; return g[row]; }
    case '-': { const unsigned char g[7] = {0x00,0x00,0x00,0x1F,0x00,0x00,0x00}; return g[row]; }
    case '_': { const unsigned char g[7] = {0x00,0x00,0x00,0x00,0x00,0x00,0x1F}; return g[row]; }
    case ' ': return blank[row];
    default: return blank[row];
  }
}

// Simple bitmap text is used instead of a font dependency so labels can be
// rendered entirely inside a CUDA kernel.
__device__ void draw_char_device(unsigned char* image, int width, int height,
                                 int x, int y, char ch,
                                 unsigned char r, unsigned char g, unsigned char b,
                                 int scale = 2) {
  for (int row = 0; row < 7; ++row) {
    const unsigned char glyph = glyph_row_for(ch, row);
    for (int col = 0; col < 5; ++col) {
      if ((glyph >> (4 - col)) & 0x1) {
        draw_rect_device(image, width, height,
                         x + col * scale, y + row * scale,
                         x + col * scale + scale - 1, y + row * scale + scale - 1,
                         r, g, b);
      }
    }
  }
}

__device__ int string_length_device(const char* text) {
  int len = 0;
  while (text[len] != '\0') {
    ++len;
  }
  return len;
}

__device__ void draw_text_device(unsigned char* image, int width, int height,
                                 int x, int y, const char* text,
                                 unsigned char r, unsigned char g, unsigned char b,
                                 int scale = 2) {
  int pen_x = x;
  for (int i = 0; text[i] != '\0'; ++i) {
    draw_char_device(image, width, height, pen_x, y, text[i], r, g, b, scale);
    pen_x += 6 * scale;
  }
}

__device__ void draw_marker_label_box_device(unsigned char* image, int width, int height,
                                             int anchor_x, int anchor_y, const char* label,
                                             int off_x, int off_y,
                                             unsigned char mr, unsigned char mg, unsigned char mb) {
  const unsigned char bg_r = 18, bg_g = 18, bg_b = 18;
  const unsigned char text_r = 240, text_g = 240, text_b = 240;
  const int scale = 2;
  const int text_width = string_length_device(label) * 6 * scale;
  const int text_height = 7 * scale;
  const int padding = 4;
  int left = anchor_x + off_x;
  int top = anchor_y + off_y;
  if (left + text_width + (2 * padding) >= width) {
    left = anchor_x - text_width - (2 * padding) - 10;
  }
  if (top < 4) {
    top = anchor_y + 10;
  }
  const int right = left + text_width + (2 * padding);
  const int bottom = top + text_height + (2 * padding);
  draw_rect_device(image, width, height, left, top, right, bottom, bg_r, bg_g, bg_b);
  draw_rect_outline_device(image, width, height, left, top, right, bottom, mr, mg, mb);
  draw_text_device(image, width, height, left + padding, top + padding, label, text_r, text_g, text_b);
}

__global__ void overlay_render_kernel(unsigned char* image,
                                      int width,
                                      int height,
                                      int ref_px,
                                      int ref_py,
                                      int cmp_px,
                                      int cmp_py,
                                      const char* ref_label,
                                      const char* cmp_label,
                                      const char* lead_line1,
                                      const char* lead_line2,
                                      unsigned char lead_r,
                                      unsigned char lead_g,
                                      unsigned char lead_b) {
  if (blockIdx.x != 0 || threadIdx.x != 0) {
    return;
  }

  // A single thread composes the small UI layer because the amount of work is
  // tiny relative to the track rasterization pass and keeps the logic simple.
  const unsigned char bg_r = 18, bg_g = 18, bg_b = 18;
  const unsigned char outline_r = 220, outline_g = 220, outline_b = 220;
  const unsigned char text_r = 240, text_g = 240, text_b = 240;
  const unsigned char ref_r = 0, ref_g = 255, ref_b = 0;
  const unsigned char cmp_r = 255, cmp_g = 255, cmp_b = 0;
  const unsigned char fast_r = 170, fast_g = 210, fast_b = 255;
  const unsigned char slow_r = 255, slow_g = 190, slow_b = 190;

  const int legend_left = 18;
  const int legend_top = height - 186;
  const int legend_right = 292;
  const int legend_bottom = height - 18;
  draw_rect_device(image, width, height, legend_left, legend_top, legend_right, legend_bottom, bg_r, bg_g, bg_b);
  draw_rect_outline_device(image, width, height, legend_left, legend_top, legend_right, legend_bottom, outline_r, outline_g, outline_b);
    draw_text_device(image, width, height, legend_left + 12, legend_top + 10, "DELTA", text_r, text_g, text_b);
    char ref_line[32] = {};
    char cmp_line[32] = {};
    ref_line[0] = 'R';
    ref_line[1] = 'E';
    ref_line[2] = 'F';
    ref_line[3] = ' ';
    cmp_line[0] = 'C';
    cmp_line[1] = 'M';
    cmp_line[2] = 'P';
    cmp_line[3] = ' ';
    int label_i = 0;
    while (ref_label[label_i] != '\0' && label_i < 20) {
      ref_line[4 + label_i] = ref_label[label_i];
      ++label_i;
    }
    ref_line[4 + label_i] = '\0';
    label_i = 0;
    while (cmp_label[label_i] != '\0' && label_i < 20) {
      cmp_line[4 + label_i] = cmp_label[label_i];
      ++label_i;
    }
    cmp_line[4 + label_i] = '\0';

    draw_dot_device(image, width, height, legend_left + 22, legend_top + 50, 6, ref_r, ref_g, ref_b);
    draw_text_device(image, width, height, legend_left + 38, legend_top + 41, ref_line, text_r, text_g, text_b);
    draw_dot_device(image, width, height, legend_left + 22, legend_top + 78, 6, cmp_r, cmp_g, cmp_b);
    draw_text_device(image, width, height, legend_left + 38, legend_top + 69, cmp_line, text_r, text_g, text_b);
  const int bar_left = legend_left + 12;
  const int bar_top = legend_top + 104;
  const int bar_width = 128;
  const int bar_height = 12;
  for (int x = 0; x < bar_width; ++x) {
    const float t = static_cast<float>(x) / static_cast<float>(max(1, bar_width - 1));
    const float normalized = (2.0f * t) - 1.0f;
    unsigned char r, g, b;
    lerp_color_device(normalized, r, g, b);
    draw_rect_device(image, width, height, bar_left + x, bar_top, bar_left + x, bar_top + bar_height, r, g, b);
  }
  draw_rect_outline_device(image, width, height, bar_left, bar_top, bar_left + bar_width, bar_top + bar_height, outline_r, outline_g, outline_b);
  char fast_label[32] = {};
  char slow_label[32] = {};
  int n = 0;
  while (cmp_label[n] != '\0' && n < 20) {
    fast_label[n] = cmp_label[n];
    slow_label[n] = cmp_label[n];
    ++n;
  }
  fast_label[n + 0] = ' ';
  fast_label[n + 1] = 'F';
  fast_label[n + 2] = 'A';
  fast_label[n + 3] = 'S';
  fast_label[n + 4] = 'T';
  fast_label[n + 5] = '\0';
  slow_label[n + 0] = ' ';
  slow_label[n + 1] = 'S';
  slow_label[n + 2] = 'L';
  slow_label[n + 3] = 'O';
  slow_label[n + 4] = 'W';
  slow_label[n + 5] = '\0';

  draw_text_device(image, width, height, bar_left, bar_top + 20, fast_label, fast_r, fast_g, fast_b);
  draw_text_device(image, width, height, bar_left, bar_top + 42, slow_label, slow_r, slow_g, slow_b);

  const int panel_width = 196;
  const int panel_height = 52;
  const int panel_left = width - panel_width - 20;
  const int panel_top = 20;
  draw_rect_device(image, width, height, panel_left, panel_top, panel_left + panel_width, panel_top + panel_height, 16, 16, 16);
  draw_rect_outline_device(image, width, height, panel_left, panel_top, panel_left + panel_width, panel_top + panel_height, lead_r, lead_g, lead_b);
  draw_text_device(image, width, height, panel_left + 10, panel_top + 8, lead_line1, lead_r, lead_g, lead_b);
  draw_text_device(image, width, height, panel_left + 10, panel_top + 28, lead_line2, text_r, text_g, text_b);

  draw_ring_device(image, width, height, ref_px, ref_py, 7, 4, ref_r, ref_g, ref_b);
  draw_dot_device(image, width, height, cmp_px, cmp_py, 4, cmp_r, cmp_g, cmp_b);

  const int dx = cmp_px - ref_px;
  const int dy = cmp_py - ref_py;
  const bool overlapping = (dx * dx + dy * dy) < (14 * 14);

  if (overlapping) {
    draw_marker_label_box_device(image, width, height, ref_px, ref_py, ref_label, 10, -28, ref_r, ref_g, ref_b);
    draw_marker_label_box_device(image, width, height, cmp_px, cmp_py, cmp_label, 10, 12, cmp_r, cmp_g, cmp_b);
  } else {
    draw_marker_label_box_device(image, width, height, ref_px, ref_py, ref_label, 10, -18, ref_r, ref_g, ref_b);
    draw_marker_label_box_device(image, width, height, cmp_px, cmp_py, cmp_label, 10, -18, cmp_r, cmp_g, cmp_b);
  }
}

__global__ void track_render_kernel(const float* ref_x,
                                    const float* ref_y,
                                    const float* ref_speed,
                                    const float* ref_brake,
                                    const float* delta_t,
                                    int n,
                                    float min_x,
                                    float min_y,
                                    float scale_x,
                                    float scale_y,
                                    float abs_max_delta,
                                    bool overlay_speed,
                                    bool overlay_brake,
                                    unsigned char* image,
                                    int width,
                                    int height) {
  // Each source sample paints a small circular stamp in screen space. The
  // result is intentionally point-based rather than anti-aliased geometry so
  // the replay stays lightweight and deterministic.
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= n) {
    return;
  }

  const int px = 10 + static_cast<int>((ref_x[idx] - min_x) * scale_x);
  const int py = 10 + static_cast<int>((ref_y[idx] - min_y) * scale_y);

  unsigned char r = 255;
  unsigned char g = 255;
  unsigned char b = 255;
  const float normalized = delta_t[idx] / abs_max_delta;
  lerp_color_device(normalized, r, g, b);

  if (overlay_speed) {
    const float speed_alpha = fmaxf(0.0f, fminf(1.0f, ref_speed[idx] / 350.0f));
    g = static_cast<unsigned char>(fminf(255.0f, g * (0.6f + 0.4f * speed_alpha)));
    b = static_cast<unsigned char>(fminf(255.0f, b * (0.6f + 0.4f * speed_alpha)));
  }
  if (overlay_brake) {
    const float brake_alpha = fmaxf(0.0f, fminf(1.0f, ref_brake[idx]));
    r = static_cast<unsigned char>(fminf(255.0f, r * (0.7f + 0.3f * brake_alpha)));
  }

  for (int oy = -2; oy <= 2; ++oy) {
    for (int ox = -2; ox <= 2; ++ox) {
      if (ox * ox + oy * oy <= 4) {
        set_rgb(image, width, height, px + ox, py + oy, r, g, b);
      }
    }
  }
}

// Simple shared-memory box filter; shared memory keeps neighbor reads local for clarity/perf.
__global__ void smooth_kernel(const float* in, float* out, int n, int radius) {
  extern __shared__ float shared[];
  const int global_idx = blockIdx.x * blockDim.x + threadIdx.x;
  const int local_idx = threadIdx.x + radius;

  if (global_idx < n) {
    shared[local_idx] = in[global_idx];
  }

  if (threadIdx.x < radius) {
    const int left = max(0, global_idx - radius);
    const int right = min(n - 1, global_idx + static_cast<int>(blockDim.x));
    shared[threadIdx.x] = in[left];
    shared[local_idx + blockDim.x] = in[right];
  }
  __syncthreads();

  if (global_idx >= n) {
    return;
  }

  float sum = 0.0f;
  int count = 0;
  for (int k = -radius; k <= radius; ++k) {
    sum += shared[local_idx + k];
    ++count;
  }
  out[global_idx] = sum / static_cast<float>(count);
}

// Host wrapper for the cumulative-distance stage. The implementation allocates
// only the temporary buffers needed for this step and frees them immediately so
// the higher-level pipeline can stay modular.
std::vector<float> compute_cumulative_distance_cuda(const std::vector<float>& x, const std::vector<float>& y) {
  if (x.size() != y.size() || x.empty()) {
    throw std::runtime_error("x and y must have same non-zero size");
  }

  const int n = static_cast<int>(x.size());
  float *d_x = nullptr, *d_y = nullptr, *d_seg = nullptr;

  cuda_check(cudaMalloc(&d_x, n * sizeof(float)), "cudaMalloc d_x");
  cuda_check(cudaMalloc(&d_y, n * sizeof(float)), "cudaMalloc d_y");
  cuda_check(cudaMalloc(&d_seg, n * sizeof(float)), "cudaMalloc d_seg");

  cuda_check(cudaMemcpy(d_x, x.data(), n * sizeof(float), cudaMemcpyHostToDevice), "copy x");
  cuda_check(cudaMemcpy(d_y, y.data(), n * sizeof(float), cudaMemcpyHostToDevice), "copy y");

  const int block = 256;
  const int grid = (n + block - 1) / block;
  segment_lengths_kernel<<<grid, block>>>(d_x, d_y, d_seg, n);
  cuda_check(cudaGetLastError(), "segment_lengths_kernel launch");

  thrust::device_ptr<float> seg_ptr(d_seg);
  thrust::inclusive_scan(seg_ptr, seg_ptr + n, seg_ptr);

  std::vector<float> cumulative(n);
  cuda_check(cudaMemcpy(cumulative.data(), d_seg, n * sizeof(float), cudaMemcpyDeviceToHost), "copy cumulative");

  cudaFree(d_x);
  cudaFree(d_y);
  cudaFree(d_seg);

  return cumulative;
}

// Builds the canonical shared distance axis for both laps.
std::vector<float> make_uniform_grid(float s_end, std::size_t points) {
  std::vector<float> grid(points);
  const float denom = static_cast<float>(points - 1);
  for (std::size_t i = 0; i < points; ++i) {
    grid[i] = s_end * static_cast<float>(i) / denom;
  }
  return grid;
}

// Host-side entry point for GPU resampling of all telemetry channels.
ResampledLap resample_cuda(const std::vector<float>& source_s,
                           const std::vector<float>& source_x,
                           const std::vector<float>& source_y,
                           const std::vector<float>& source_t,
                           const std::vector<float>& source_speed,
                           const std::vector<float>& source_throttle,
                           const std::vector<float>& source_brake,
                           const std::vector<float>& grid_s) {
  const int source_n = static_cast<int>(source_s.size());
  const int grid_n = static_cast<int>(grid_s.size());

  float *d_s = nullptr, *d_x = nullptr, *d_y = nullptr, *d_t = nullptr;
  float *d_speed = nullptr, *d_throttle = nullptr, *d_brake = nullptr;
  float *d_grid = nullptr, *d_out_x = nullptr, *d_out_y = nullptr, *d_out_t = nullptr;
  float *d_out_speed = nullptr, *d_out_throttle = nullptr, *d_out_brake = nullptr;

  cuda_check(cudaMalloc(&d_s, source_n * sizeof(float)), "cudaMalloc d_s");
  cuda_check(cudaMalloc(&d_x, source_n * sizeof(float)), "cudaMalloc d_x src");
  cuda_check(cudaMalloc(&d_y, source_n * sizeof(float)), "cudaMalloc d_y src");
  cuda_check(cudaMalloc(&d_t, source_n * sizeof(float)), "cudaMalloc d_t src");
  cuda_check(cudaMalloc(&d_speed, source_n * sizeof(float)), "cudaMalloc d_speed src");
  cuda_check(cudaMalloc(&d_throttle, source_n * sizeof(float)), "cudaMalloc d_throttle src");
  cuda_check(cudaMalloc(&d_brake, source_n * sizeof(float)), "cudaMalloc d_brake src");
  cuda_check(cudaMalloc(&d_grid, grid_n * sizeof(float)), "cudaMalloc d_grid");
  cuda_check(cudaMalloc(&d_out_x, grid_n * sizeof(float)), "cudaMalloc out_x");
  cuda_check(cudaMalloc(&d_out_y, grid_n * sizeof(float)), "cudaMalloc out_y");
  cuda_check(cudaMalloc(&d_out_t, grid_n * sizeof(float)), "cudaMalloc out_t");
  cuda_check(cudaMalloc(&d_out_speed, grid_n * sizeof(float)), "cudaMalloc out_speed");
  cuda_check(cudaMalloc(&d_out_throttle, grid_n * sizeof(float)), "cudaMalloc out_throttle");
  cuda_check(cudaMalloc(&d_out_brake, grid_n * sizeof(float)), "cudaMalloc out_brake");

  cudaMemcpy(d_s, source_s.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_x, source_x.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_y, source_y.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_t, source_t.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_speed, source_speed.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_throttle, source_throttle.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_brake, source_brake.data(), source_n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_grid, grid_s.data(), grid_n * sizeof(float), cudaMemcpyHostToDevice);

  const int block = 256;
  const int grid = (grid_n + block - 1) / block;
  resample_kernel<<<grid, block>>>(
      d_s,
      d_x,
      d_y,
      d_t,
      d_speed,
      d_throttle,
      d_brake,
      source_n,
      d_grid,
      d_out_x,
      d_out_y,
      d_out_t,
      d_out_speed,
      d_out_throttle,
      d_out_brake,
      grid_n);
  cuda_check(cudaGetLastError(), "resample_kernel launch");

  ResampledLap out;
  out.s = grid_s;
  out.x.resize(grid_n);
  out.y.resize(grid_n);
  out.t.resize(grid_n);
  out.speed.resize(grid_n);
  out.throttle.resize(grid_n);
  out.brake.resize(grid_n);

  cudaMemcpy(out.x.data(), d_out_x, grid_n * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(out.y.data(), d_out_y, grid_n * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(out.t.data(), d_out_t, grid_n * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(out.speed.data(), d_out_speed, grid_n * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(out.throttle.data(), d_out_throttle, grid_n * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(out.brake.data(), d_out_brake, grid_n * sizeof(float), cudaMemcpyDeviceToHost);

  cudaFree(d_s);
  cudaFree(d_x);
  cudaFree(d_y);
  cudaFree(d_t);
  cudaFree(d_speed);
  cudaFree(d_throttle);
  cudaFree(d_brake);
  cudaFree(d_grid);
  cudaFree(d_out_x);
  cudaFree(d_out_y);
  cudaFree(d_out_t);
  cudaFree(d_out_speed);
  cudaFree(d_out_throttle);
  cudaFree(d_out_brake);

  return out;
}

// Host-side wrapper for delta and optional smoothing.
std::vector<float> delta_cuda(const std::vector<float>& cmp_t, const std::vector<float>& ref_t, bool apply_smoothing) {
  const int n = static_cast<int>(cmp_t.size());
  float *d_cmp = nullptr, *d_ref = nullptr, *d_delta = nullptr, *d_smooth = nullptr;

  cuda_check(cudaMalloc(&d_cmp, n * sizeof(float)), "cudaMalloc d_cmp");
  cuda_check(cudaMalloc(&d_ref, n * sizeof(float)), "cudaMalloc d_ref");
  cuda_check(cudaMalloc(&d_delta, n * sizeof(float)), "cudaMalloc d_delta");

  cudaMemcpy(d_cmp, cmp_t.data(), n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_ref, ref_t.data(), n * sizeof(float), cudaMemcpyHostToDevice);

  const int block = 256;
  const int grid = (n + block - 1) / block;
  delta_kernel<<<grid, block>>>(d_cmp, d_ref, d_delta, n);
  cuda_check(cudaGetLastError(), "delta_kernel launch");

  if (apply_smoothing) {
    cuda_check(cudaMalloc(&d_smooth, n * sizeof(float)), "cudaMalloc d_smooth");
    constexpr int radius = 2;
    const std::size_t shared_bytes = (block + 2 * radius) * sizeof(float);
    smooth_kernel<<<grid, block, shared_bytes>>>(d_delta, d_smooth, n, radius);
    cuda_check(cudaGetLastError(), "smooth_kernel launch");
    cudaFree(d_delta);
    d_delta = d_smooth;
  }

  std::vector<float> delta(n);
  cudaMemcpy(delta.data(), d_delta, n * sizeof(float), cudaMemcpyDeviceToHost);

  cudaFree(d_cmp);
  cudaFree(d_ref);
  cudaFree(d_delta);
  return delta;
}

// Internal frame renderer that assumes the caller already resolved marker
// positions and banner text for the current replay time.
std::vector<unsigned char> render_frame_cuda_impl(const DeltaResult& delta,
                                                  const char* ref_label,
                                                  const char* cmp_label,
                                                  const char* lead_line1,
                                                  const char* lead_line2,
                                                  int ref_px,
                                                  int ref_py,
                                                  int cmp_px,
                                                  int cmp_py,
                                                  unsigned char lead_r,
                                                  unsigned char lead_g,
                                                  unsigned char lead_b,
                                                  int width,
                                                  int height,
                                                  bool overlay_speed,
                                                  bool overlay_brake) {
  const int n = static_cast<int>(delta.reference.x.size());
  const int pixel_count = width * height;
  const auto minmax_x = std::minmax_element(delta.reference.x.begin(), delta.reference.x.end());
  const auto minmax_y = std::minmax_element(delta.reference.y.begin(), delta.reference.y.end());
  const float min_x = *minmax_x.first;
  const float max_x = *minmax_x.second;
  const float min_y = *minmax_y.first;
  const float max_y = *minmax_y.second;
  const float scale_x = (width - 20) / std::max(1e-3f, (max_x - min_x));
  const float scale_y = (height - 20) / std::max(1e-3f, (max_y - min_y));

  float abs_max_delta = 1e-3f;
  for (float d : delta.delta_t) {
    abs_max_delta = std::max(abs_max_delta, std::abs(d));
  }

  float *d_ref_x = nullptr, *d_ref_y = nullptr, *d_ref_speed = nullptr, *d_ref_brake = nullptr, *d_delta = nullptr;
  unsigned char* d_image = nullptr;
  char *d_ref_label = nullptr, *d_cmp_label = nullptr, *d_lead_line1 = nullptr, *d_lead_line2 = nullptr;
  cuda_check(cudaMalloc(&d_ref_x, n * sizeof(float)), "cudaMalloc render d_ref_x");
  cuda_check(cudaMalloc(&d_ref_y, n * sizeof(float)), "cudaMalloc render d_ref_y");
  cuda_check(cudaMalloc(&d_ref_speed, n * sizeof(float)), "cudaMalloc render d_ref_speed");
  cuda_check(cudaMalloc(&d_ref_brake, n * sizeof(float)), "cudaMalloc render d_ref_brake");
  cuda_check(cudaMalloc(&d_delta, n * sizeof(float)), "cudaMalloc render d_delta");
  cuda_check(cudaMalloc(&d_image, pixel_count * 3 * sizeof(unsigned char)), "cudaMalloc render d_image");
  cuda_check(cudaMalloc(&d_ref_label, 32), "cudaMalloc render d_ref_label");
  cuda_check(cudaMalloc(&d_cmp_label, 32), "cudaMalloc render d_cmp_label");
  cuda_check(cudaMalloc(&d_lead_line1, 32), "cudaMalloc render d_lead_line1");
  cuda_check(cudaMalloc(&d_lead_line2, 32), "cudaMalloc render d_lead_line2");

  cudaMemcpy(d_ref_x, delta.reference.x.data(), n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_ref_y, delta.reference.y.data(), n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_ref_speed, delta.reference.speed.data(), n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_ref_brake, delta.reference.brake.data(), n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_delta, delta.delta_t.data(), n * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_ref_label, ref_label, 32, cudaMemcpyHostToDevice);
  cudaMemcpy(d_cmp_label, cmp_label, 32, cudaMemcpyHostToDevice);
  cudaMemcpy(d_lead_line1, lead_line1, 32, cudaMemcpyHostToDevice);
  cudaMemcpy(d_lead_line2, lead_line2, 32, cudaMemcpyHostToDevice);

  const int block = 256;
  const int pixel_grid = (pixel_count + block - 1) / block;
  clear_image_kernel<<<pixel_grid, block>>>(d_image, pixel_count);
  cuda_check(cudaGetLastError(), "clear_image_kernel launch");

  const int track_grid = (n + block - 1) / block;
  track_render_kernel<<<track_grid, block>>>(
      d_ref_x,
      d_ref_y,
      d_ref_speed,
      d_ref_brake,
      d_delta,
      n,
      min_x,
      min_y,
      scale_x,
      scale_y,
      abs_max_delta,
      overlay_speed,
      overlay_brake,
      d_image,
      width,
      height);
  cuda_check(cudaGetLastError(), "track_render_kernel launch");
  overlay_render_kernel<<<1, 1>>>(
      d_image, width, height,
      ref_px, ref_py, cmp_px, cmp_py,
      d_ref_label, d_cmp_label, d_lead_line1, d_lead_line2,
      lead_r, lead_g, lead_b);
  cuda_check(cudaGetLastError(), "overlay_render_kernel launch");

  std::vector<unsigned char> image(static_cast<std::size_t>(pixel_count * 3));
  cudaMemcpy(image.data(), d_image, image.size() * sizeof(unsigned char), cudaMemcpyDeviceToHost);

  cudaFree(d_ref_x);
  cudaFree(d_ref_y);
  cudaFree(d_ref_speed);
  cudaFree(d_ref_brake);
  cudaFree(d_delta);
  cudaFree(d_image);
  cudaFree(d_ref_label);
  cudaFree(d_cmp_label);
  cudaFree(d_lead_line1);
  cudaFree(d_lead_line2);
  return image;
}

}  // namespace

std::vector<float> cumulative_distance_cpu(const std::vector<float>& x, const std::vector<float>& y) {
  if (x.size() != y.size() || x.empty()) {
    throw std::runtime_error("x and y must have same non-zero size");
  }

  std::vector<float> cumulative(x.size(), 0.0f);
  for (std::size_t i = 1; i < x.size(); ++i) {
    const float dx = x[i] - x[i - 1];
    const float dy = y[i] - y[i - 1];
    cumulative[i] = cumulative[i - 1] + std::sqrt(dx * dx + dy * dy);
  }
  return cumulative;
}

DeltaResult compute_delta_pipeline_cuda(const std::vector<float>& ref_x,
                                        const std::vector<float>& ref_y,
                                        const std::vector<float>& ref_t,
                                        const std::vector<float>& ref_speed,
                                        const std::vector<float>& ref_throttle,
                                        const std::vector<float>& ref_brake,
                                        const std::vector<float>& cmp_x,
                                        const std::vector<float>& cmp_y,
                                        const std::vector<float>& cmp_t,
                                        const std::vector<float>& cmp_speed,
                                        const std::vector<float>& cmp_throttle,
                                        const std::vector<float>& cmp_brake,
                                        std::size_t grid_points,
                                        bool apply_smoothing) {
  // Validation happens once at the host boundary so the downstream kernels can
  // assume coherent channel lengths.
  if (ref_x.size() != ref_y.size() || ref_x.size() != ref_t.size() ||
      cmp_x.size() != cmp_y.size() || cmp_x.size() != cmp_t.size()) {
    throw std::runtime_error("Input channels must have matching lengths");
  }

  const auto ref_s = compute_cumulative_distance_cuda(ref_x, ref_y);
  const auto cmp_s = compute_cumulative_distance_cuda(cmp_x, cmp_y);

  const float common_end = std::min(ref_s.back(), cmp_s.back());
  const auto grid_s = make_uniform_grid(common_end, grid_points);

  auto ref_resampled = resample_cuda(ref_s, ref_x, ref_y, ref_t, ref_speed, ref_throttle, ref_brake, grid_s);
  auto cmp_resampled = resample_cuda(cmp_s, cmp_x, cmp_y, cmp_t, cmp_speed, cmp_throttle, cmp_brake, grid_s);

  DeltaResult result;
  result.reference = std::move(ref_resampled);
  result.compare = std::move(cmp_resampled);
  result.delta_t = delta_cuda(result.compare.t, result.reference.t, apply_smoothing);
  return result;
}

std::vector<unsigned char> render_frame_cuda(const DeltaResult& delta,
                                             float frame_time_s,
                                             const std::string& reference_label,
                                             const std::string& compare_label,
                                             float reference_x,
                                             float reference_y,
                                             float compare_x,
                                             float compare_y,
                                             float delta_t_value,
                                             int width,
                                             int height,
                                             bool overlay_speed,
                                             bool overlay_brake) {
  // The renderer receives marker positions in world space and converts them to
  // screen space using the same bounds as the track rasterization pass.
  const auto minmax_x = std::minmax_element(delta.reference.x.begin(), delta.reference.x.end());
  const auto minmax_y = std::minmax_element(delta.reference.y.begin(), delta.reference.y.end());
  const float min_x = *minmax_x.first;
  const float max_x = *minmax_x.second;
  const float min_y = *minmax_y.first;
  const float max_y = *minmax_y.second;
  const float scale_x = (width - 20) / std::max(1e-3f, (max_x - min_x));
  const float scale_y = (height - 20) / std::max(1e-3f, (max_y - min_y));
  const int ref_px = 10 + static_cast<int>((reference_x - min_x) * scale_x);
  const int ref_py = 10 + static_cast<int>((reference_y - min_y) * scale_y);
  const int cmp_px = 10 + static_cast<int>((compare_x - min_x) * scale_x);
  const int cmp_py = 10 + static_cast<int>((compare_y - min_y) * scale_y);

  // CUDA-side text rendering only understands a narrow ASCII subset, so labels
  // are normalized before they are copied to fixed-size device buffers.
  auto sanitize_label = [](const std::string& text) {
    std::array<char, 32> out{};
    std::size_t n = 0;
    for (char ch : text) {
      if (n >= out.size() - 1) {
        break;
      }
      unsigned char uch = static_cast<unsigned char>(ch);
      if (std::isalnum(uch) || ch == '-' || ch == '_' || ch == ' ' || ch == '+' || ch == '.') {
        out[n++] = static_cast<char>(std::toupper(uch));
      }
    }
    if (n == 0) {
      out[0] = 'C'; out[1] = 'A'; out[2] = 'R';
    }
    return out;
  };

  const auto ref_label = sanitize_label(reference_label);
  const auto cmp_label = sanitize_label(compare_label);

  // Lead banner formatting is resolved on the host so the device-side overlay
  // kernel only has to paint prepared strings.
  std::string leader = std::string(ref_label.data());
  unsigned char lead_r = 0, lead_g = 255, lead_b = 0;
  float magnitude = delta_t_value;
  if (delta_t_value < 0.0f) {
    leader = std::string(cmp_label.data());
    lead_r = 255; lead_g = 255; lead_b = 0;
    magnitude = -delta_t_value;
  }
  const int hundredths = static_cast<int>(magnitude * 100.0f + 0.5f);
  const int seconds = hundredths / 100;
  const int fractional = hundredths % 100;
  std::string line1 = leader + " AHEAD";
  std::string line2 = "BY +" + std::to_string(seconds) + ".";
  if (fractional < 10) {
    line2 += "0";
  }
  line2 += std::to_string(fractional) + "S";
  const auto lead_line1 = sanitize_label(line1);
  const auto lead_line2 = sanitize_label(line2);

  return render_frame_cuda_impl(
      delta,
      ref_label.data(),
      cmp_label.data(),
      lead_line1.data(),
      lead_line2.data(),
      ref_px,
      ref_py,
      cmp_px,
      cmp_py,
      lead_r,
      lead_g,
      lead_b,
      width,
      height,
      overlay_speed,
      overlay_brake);
}

}  // namespace lap
