#include "lap_processing.cuh"
#include "telemetry_loader.h"
#include "ui.h"

#include <iostream>
#include <filesystem>
#include <string>

int main(int argc, char** argv) {
  try {
    telemetry::TelemetryLap ref_lap;
    telemetry::TelemetryLap cmp_lap;
    std::string reference_label = "REF";
    std::string compare_label = "CMP";

    if (argc >= 3) {
      ref_lap = telemetry::load_lap_csv(argv[1]);
      cmp_lap = telemetry::load_lap_csv(argv[2]);
      std::cout << "Loaded telemetry from CSV files.\n";
      reference_label = std::filesystem::path(argv[1]).stem().string();
      compare_label = std::filesystem::path(argv[2]).stem().string();
      if (argc >= 5) {
        reference_label = argv[3];
        compare_label = argv[4];
      }
    } else {
      std::cout << "No CSV files supplied. Using built-in sample laps.\n";
      ref_lap = telemetry::make_sample_lap(120.0f, 80.0f, 90.0f, 400, 0.0f);
      cmp_lap = telemetry::make_sample_lap(120.0f, 80.0f, 91.4f, 420, 0.05f);
      reference_label = "REF";
      compare_label = "CMP";
    }

    constexpr std::size_t grid_points = 512;
    constexpr bool smoothing = true;
    const auto delta = lap::compute_delta_pipeline_cuda(
        ref_lap.x, ref_lap.y, ref_lap.t,
        cmp_lap.x, cmp_lap.y, cmp_lap.t,
        grid_points, smoothing);

    ui::UiOptions options;
    options.smoothing = smoothing;
    options.reference_label = reference_label;
    options.compare_label = compare_label;
    ui::run_prototype_ui(delta, options);

    std::cout << "Delta sample: start=" << delta.delta_t.front()
              << " mid=" << delta.delta_t[delta.delta_t.size() / 2]
              << " end=" << delta.delta_t.back() << "\n";
  } catch (const std::exception& ex) {
    std::cerr << "Error: " << ex.what() << "\n";
    return 1;
  }

  return 0;
}
