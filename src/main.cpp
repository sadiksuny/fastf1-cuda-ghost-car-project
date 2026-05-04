#include "lap_processing.cuh"
#include "telemetry_loader.h"
#include "ui.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <regex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

struct SessionDriverEntry {
  std::string label;
  std::filesystem::path csv_path;
  int lap_number = -1;
  std::string lap_time;
};

struct SessionDriverGroup {
  std::string label;
  std::vector<SessionDriverEntry> laps;
};

struct SessionManifestInfo {
  std::string session_label;
  std::string lap_mode;
  std::vector<SessionDriverEntry> entries;
};

std::string trim_copy(std::string value) {
  value.erase(value.begin(), std::find_if(value.begin(), value.end(), [](unsigned char c) {
    return !std::isspace(c);
  }));
  value.erase(std::find_if(value.rbegin(), value.rend(), [](unsigned char c) {
    return !std::isspace(c);
  }).base(), value.end());
  return value;
}

std::string expand_session_code(std::string session_code) {
  session_code = trim_copy(session_code);
  std::transform(session_code.begin(), session_code.end(), session_code.begin(), [](unsigned char c) {
    return static_cast<char>(std::toupper(c));
  });

  if (session_code == "R") {
    return "Race";
  }
  if (session_code == "Q") {
    return "Qualifying";
  }
  if (session_code == "SQ") {
    return "Sprint Qualifying";
  }
  if (session_code == "S") {
    return "Sprint";
  }
  if (session_code == "FP1") {
    return "Free Practice 1";
  }
  if (session_code == "FP2") {
    return "Free Practice 2";
  }
  if (session_code == "FP3") {
    return "Free Practice 3";
  }
  return session_code;
}

SessionManifestInfo read_session_manifest(const std::filesystem::path& folder) {
  SessionManifestInfo info;
  const auto manifest_path = folder / "session_manifest.json";
  if (!std::filesystem::exists(manifest_path)) {
    return info;
  }

  std::ifstream in(manifest_path);
  if (!in.is_open()) {
    return info;
  }

  std::ostringstream buffer;
  buffer << in.rdbuf();
  const std::string text = buffer.str();

  const std::regex session_rx(
      R"manifest("session"\s*:\s*\{[^}]*"year"\s*:\s*(\d+)[^}]*"event"\s*:\s*"([^"]+)"[^}]*"session"\s*:\s*"([^"]+)")manifest");
  std::smatch session_match;
  if (std::regex_search(text, session_match, session_rx) && session_match.size() == 4) {
    info.session_label = trim_copy(session_match[2].str()) + " " + trim_copy(session_match[1].str()) + " " +
                         expand_session_code(session_match[3].str());
  }

  const std::regex mode_rx(R"manifest("lap_mode"\s*:\s*"([^"]+)")manifest");
  std::smatch mode_match;
  if (std::regex_search(text, mode_match, mode_rx) && mode_match.size() == 2) {
    info.lap_mode = trim_copy(mode_match[1].str());
  }

  const std::regex entry_rx(
      R"manifest(\{\s*"driver"\s*:\s*"([A-Z0-9]+)"\s*,\s*"file"\s*:\s*"([^"]+)"\s*,\s*"lap_number"\s*:\s*(-?\d+)\s*,\s*"lap_time"\s*:\s*"([^"]*)")manifest");
  for (std::sregex_iterator it(text.begin(), text.end(), entry_rx), end; it != end; ++it) {
    SessionDriverEntry entry;
    entry.label = (*it)[1].str();
    entry.csv_path = folder / (*it)[2].str();
    entry.lap_number = std::stoi((*it)[3].str());
    entry.lap_time = (*it)[4].str();
    info.entries.push_back(entry);
  }

  return info;
}

std::string describe_lap_mode(const std::string& lap_mode) {
  if (lap_mode == "fastest-accurate-non-box") {
    return "fastest accurate non-box lap";
  }
  if (lap_mode == "all-accurate") {
    return "all accurate laps";
  }
  if (lap_mode == "all-laps") {
    return "all laps";
  }
  return {};
}

std::string build_lap_label(const SessionDriverEntry& entry) {
  if (entry.lap_number < 0 && entry.lap_time.empty()) {
    return {};
  }

  std::string label = entry.label;
  if (entry.lap_number >= 0) {
    label += " Lap " + std::to_string(entry.lap_number);
  }
  if (!entry.lap_time.empty()) {
    label += " (" + entry.lap_time + ")";
  }
  return label;
}

double parse_lap_time_seconds(const std::string& lap_time_text) {
  if (lap_time_text.empty() || lap_time_text == "unknown") {
    return std::numeric_limits<double>::infinity();
  }

  const auto colon = lap_time_text.find(':');
  if (colon == std::string::npos) {
    return std::numeric_limits<double>::infinity();
  }

  try {
    const double minutes = std::stod(lap_time_text.substr(0, colon));
    const double seconds = std::stod(lap_time_text.substr(colon + 1));
    return (minutes * 60.0) + seconds;
  } catch (...) {
    return std::numeric_limits<double>::infinity();
  }
}

const SessionDriverEntry& fastest_lap_entry(const SessionDriverGroup& group) {
  return *std::min_element(group.laps.begin(), group.laps.end(), [](const SessionDriverEntry& a, const SessionDriverEntry& b) {
    const double a_time = parse_lap_time_seconds(a.lap_time);
    const double b_time = parse_lap_time_seconds(b.lap_time);
    if (a_time != b_time) {
      return a_time < b_time;
    }
    return a.lap_number < b.lap_number;
  });
}

std::vector<SessionDriverEntry> list_session_lap_entries(const std::filesystem::path& folder) {
  const auto manifest = read_session_manifest(folder);
  if (!manifest.entries.empty()) {
    auto entries = manifest.entries;
    std::sort(entries.begin(), entries.end(), [](const SessionDriverEntry& a, const SessionDriverEntry& b) {
      if (a.label != b.label) {
        return a.label < b.label;
      }
      return a.lap_number < b.lap_number;
    });
    return entries;
  }

  std::vector<SessionDriverEntry> entries;
  for (const auto& item : std::filesystem::directory_iterator(folder)) {
    if (!item.is_regular_file() || item.path().extension() != ".csv") {
      continue;
    }
    SessionDriverEntry entry;
    entry.label = item.path().stem().string();
    entry.csv_path = item.path();
    entries.push_back(entry);
  }

  std::sort(entries.begin(), entries.end(), [](const SessionDriverEntry& a, const SessionDriverEntry& b) {
    return a.label < b.label;
  });
  return entries;
}

std::vector<SessionDriverGroup> group_session_entries(const std::vector<SessionDriverEntry>& entries) {
  std::vector<SessionDriverGroup> groups;
  for (const auto& entry : entries) {
    auto group_it = std::find_if(groups.begin(), groups.end(), [&](const SessionDriverGroup& group) {
      return group.label == entry.label;
    });
    if (group_it == groups.end()) {
      groups.push_back(SessionDriverGroup{entry.label, {entry}});
    } else {
      group_it->laps.push_back(entry);
    }
  }

  for (auto& group : groups) {
    std::sort(group.laps.begin(), group.laps.end(), [](const SessionDriverEntry& a, const SessionDriverEntry& b) {
      return a.lap_number < b.lap_number;
    });
  }

  std::sort(groups.begin(), groups.end(), [](const SessionDriverGroup& a, const SessionDriverGroup& b) {
    return a.label < b.label;
  });
  return groups;
}

int prompt_driver_choice(const std::vector<SessionDriverGroup>& groups, const std::string& prompt) {
  while (true) {
    std::cout << prompt;
    std::string input;
    if (!(std::cin >> input)) {
      continue;
    }

    bool is_number = !input.empty() && std::all_of(input.begin(), input.end(), [](unsigned char c) {
      return std::isdigit(c) != 0;
    });
    if (is_number) {
      const int choice = std::stoi(input);
      if (choice >= 1 && choice <= static_cast<int>(groups.size())) {
        return choice - 1;
      }
    } else {
      std::string upper = input;
      std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) {
        return static_cast<char>(std::toupper(c));
      });
      for (std::size_t i = 0; i < groups.size(); ++i) {
        std::string label = groups[i].label;
        std::transform(label.begin(), label.end(), label.begin(), [](unsigned char c) {
          return static_cast<char>(std::toupper(c));
        });
        if (label == upper) {
          return static_cast<int>(i);
        }
      }
    }

    std::cout << "Please enter a driver number (1-" << groups.size() << ") or a driver code like LEC.\n";
  }
}

int prompt_lap_choice(const SessionDriverGroup& group, const std::string& prompt) {
  while (true) {
    std::cout << prompt;
    std::string input;
    if (!(std::cin >> input)) {
      continue;
    }

    std::string upper = input;
    std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) {
      return static_cast<char>(std::toupper(c));
    });
    if (upper == "D" || upper == "DEFAULT" || upper == "FASTEST") {
      const auto& fastest = fastest_lap_entry(group);
      return static_cast<int>(&fastest - group.laps.data());
    }

    const bool is_number = !input.empty() && std::all_of(input.begin(), input.end(), [](unsigned char c) {
      return std::isdigit(c) != 0;
    });
    if (!is_number) {
      std::cout << "Enter a list number, a lap number, or D for the fastest exported lap.\n";
      continue;
    }

    const int choice = std::stoi(input);
    if (choice >= 1 && choice <= static_cast<int>(group.laps.size())) {
      return choice - 1;
    }

    auto lap_it = std::find_if(group.laps.begin(), group.laps.end(), [&](const SessionDriverEntry& entry) {
      return entry.lap_number == choice;
    });
    if (lap_it != group.laps.end()) {
      return static_cast<int>(lap_it - group.laps.begin());
    }

    std::cout << "Please enter a list number (1-" << group.laps.size()
              << "), an actual lap number shown in the list, or D for the fastest exported lap.\n";
  }
}

}  // namespace

int main(int argc, char** argv) {
  try {
    telemetry::TelemetryLap ref_lap;
    telemetry::TelemetryLap cmp_lap;
    std::string reference_label = "REF";
    std::string compare_label = "CMP";
    constexpr bool speed_overlay = true;
    constexpr bool brake_overlay = true;
    std::string session_label;
    std::string reference_lap_label;
    std::string compare_lap_label;

    if (argc == 2 && std::filesystem::is_directory(argv[1])) {
      const auto session_folder = std::filesystem::path(argv[1]);
      const auto manifest = read_session_manifest(session_folder);
      const auto entries = list_session_lap_entries(session_folder);
      const auto groups = group_session_entries(entries);
      if (groups.size() < 2) {
        throw std::runtime_error("Session folder must contain at least two CSV files.");
      }

      std::cout << "Available drivers in " << session_folder.string() << ":\n";
      const auto mode_description = describe_lap_mode(manifest.lap_mode);
      if (!mode_description.empty()) {
        std::cout << "This folder contains " << mode_description << " for each driver in the session.\n";
      }
      for (std::size_t i = 0; i < groups.size(); ++i) {
        std::cout << "  " << (i + 1) << ". " << groups[i].label << "  (" << groups[i].laps.size() << " lap";
        if (groups[i].laps.size() != 1) {
          std::cout << "s";
        }
        std::cout << ")\n";
      }

      const int reference_driver_idx = prompt_driver_choice(groups, "Choose reference driver: ");
      int compare_driver_idx = prompt_driver_choice(groups, "Choose compare driver: ");
      while (compare_driver_idx == reference_driver_idx) {
        std::cout << "Choose a different driver for compare.\n";
        compare_driver_idx = prompt_driver_choice(groups, "Choose compare driver: ");
      }

      const auto& reference_group = groups[reference_driver_idx];
      const auto& compare_group = groups[compare_driver_idx];

      const auto& reference_fastest = fastest_lap_entry(reference_group);
      std::cout << "Fastest exported lap for " << reference_group.label << ": "
                << build_lap_label(reference_fastest) << "\n";

      std::cout << "Available laps for " << reference_group.label << ":\n";
      for (std::size_t i = 0; i < reference_group.laps.size(); ++i) {
        std::cout << "  " << (i + 1) << ". " << build_lap_label(reference_group.laps[i]) << "\n";
      }
      const int reference_lap_idx = prompt_lap_choice(reference_group, "Choose reference lap (D = fastest): ");

      const auto& compare_fastest = fastest_lap_entry(compare_group);
      std::cout << "Fastest exported lap for " << compare_group.label << ": "
                << build_lap_label(compare_fastest) << "\n";

      std::cout << "Available laps for " << compare_group.label << ":\n";
      for (std::size_t i = 0; i < compare_group.laps.size(); ++i) {
        std::cout << "  " << (i + 1) << ". " << build_lap_label(compare_group.laps[i]) << "\n";
      }
      const int compare_lap_idx = prompt_lap_choice(compare_group, "Choose compare lap (D = fastest): ");

      const auto& reference_entry = reference_group.laps[reference_lap_idx];
      const auto& compare_entry = compare_group.laps[compare_lap_idx];

      reference_label = reference_entry.label;
      compare_label = compare_entry.label;
      session_label = manifest.session_label;
      reference_lap_label = build_lap_label(reference_entry);
      compare_lap_label = build_lap_label(compare_entry);
      ref_lap = telemetry::load_lap_csv(reference_entry.csv_path.string());
      cmp_lap = telemetry::load_lap_csv(compare_entry.csv_path.string());
      std::cout << "Loaded telemetry for " << reference_label << " vs " << compare_label << ".\n";
    } else if (argc >= 3) {
      ref_lap = telemetry::load_lap_csv(argv[1]);
      cmp_lap = telemetry::load_lap_csv(argv[2]);
      std::cout << "Loaded telemetry from CSV files.\n";
      reference_label = std::filesystem::path(argv[1]).stem().string();
      compare_label = std::filesystem::path(argv[2]).stem().string();
      if (argc >= 5 && std::string(argv[3]).rfind("--", 0) != 0) {
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
        ref_lap.speed, ref_lap.throttle, ref_lap.brake,
        cmp_lap.x, cmp_lap.y, cmp_lap.t,
        cmp_lap.speed, cmp_lap.throttle, cmp_lap.brake,
        grid_points, smoothing);

    ui::UiOptions options;
    options.smoothing = smoothing;
    options.session_label = session_label;
    options.reference_label = reference_label;
    options.compare_label = compare_label;
    options.reference_lap_label = reference_lap_label;
    options.compare_lap_label = compare_lap_label;
    options.telemetry_overlay_speed = speed_overlay;
    options.telemetry_overlay_brake = brake_overlay;
    ui::run_prototype_ui(delta, options);
  } catch (const std::exception& ex) {
    std::cerr << "Error: " << ex.what() << "\n";
    return 1;
  }

  return 0;
}
