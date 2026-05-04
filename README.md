# Fast F1 CUDA Ghost Car

This is a small CUDA/C++ app for comparing two laps and visualizing the difference as a ghost-car replay.

It takes two telemetry CSV files, aligns the laps on the GPU, computes the delta, renders a frame sequence, and writes a simple local viewer to `output/viewer.html`.

## Requirements

You need:
- an NVIDIA GPU
- a working NVIDIA driver
- the CUDA Toolkit
- CMake 3.22 or newer
- a C++ compiler supported by your CUDA install

## Platform Notes

### Windows

Windows is the main supported path for this repo.

Install:
- Visual Studio 2022 with `Desktop development with C++`
- CUDA Toolkit
- CMake

Use a Visual Studio Developer Command Prompt or Developer PowerShell.

### Linux

Linux should work as long as you have:
- NVIDIA driver
- CUDA Toolkit
- CMake
- GCC/G++

### macOS

macOS is not a practical target for this project. Native CUDA support is not available on modern Macs, so you will need a Windows or Linux machine with an NVIDIA GPU.

## Build

### Windows

From the repo root:

```bat
set CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2
set PATH=%CUDA_PATH%\bin;%PATH%
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 -T "cuda=%CUDA_PATH%"
cmake --build build --config Release
```

If your CUDA version is different, replace `v13.2` with the version you actually installed.

### Linux

```bash
cmake -S . -B build
cmake --build build -j
```

If CMake does not find CUDA automatically:

```bash
cmake -S . -B build -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc
cmake --build build -j
```

## Input Data

The app expects two CSV files. Minimum format:

```text
x,y,t
```

Optional extra columns:

```text
x,y,t,speed,throttle,brake
```

If you want real F1 telemetry, the helper script in `scripts/export_fastf1_laps.py` can generate CSVs from Fast-F1 data.

The export script supports three session folder modes:
- `fastest-accurate-non-box`
- `all-accurate`
- `all-laps`

Useful examples:

List all drivers in a session:

```bash
python scripts/export_fastf1_laps.py --year 2024 --event Monaco --session Q --list-drivers
```

Export the whole grid into one folder. By default this writes each driver's
fastest accurate non-box lap for that session:

```bash
python scripts/export_fastf1_laps.py --year 2024 --event Monaco --session Q --export-all-dir data/monaco_q
```

Other export modes:

```bash
python scripts/export_fastf1_laps.py --year 2024 --event Monaco --session Q --export-all-dir data/monaco_q_all_accurate --lap-mode all-accurate
python scripts/export_fastf1_laps.py --year 2024 --event Monaco --session Q --export-all-dir data/monaco_q_all_laps --lap-mode all-laps
```

`--lap-mode fastest-accurate-non-box` exports one clean representative lap per driver.

`--lap-mode all-accurate` exports every accurate lap for every driver.

`--lap-mode all-laps` exports every lap Fast-F1 has for that session.

When you use `--export-all-dir`, the script also writes `session_manifest.json`
with the session name, lap mode, lap numbers, and lap times used by the native picker and HTML viewer.

There is also a built-in picker mode. If you pass a folder that contains session CSVs, the app will:
- list the drivers in the terminal
- show what kind of folder it is, such as `all laps` or `fastest accurate non-box lap`
- let you choose a reference and compare driver
- show each driver's fastest exported lap as the default comparison option
- if multiple laps exist for a driver, let you choose the exact lap number or use the default fastest lap with `D`

## Run

### Windows

Built-in sample laps:

```bat
.\build\Release\f1_ghost_app.exe
```

Two CSV files with labels:

```bat
.\build\Release\f1_ghost_app.exe data\fastf1_ref.csv data\fastf1_cmp.csv LEC VER
```

Interactive picker from a full exported session folder:

```bat
.\build\Release\f1_ghost_app.exe data\monaco_q
```

The picker accepts:
- a driver number or driver code like `LEC`
- a lap list number, an actual lap number, or `D` for the fastest exported lap

After the selection step, the app keeps terminal output minimal:
- `Loaded telemetry for ...`
- `Wrote ... viewer.html`

### Linux

Built-in sample laps:

```bash
./build/f1_ghost_app
```

Two CSV files with labels:

```bash
./build/f1_ghost_app data/fastf1_ref.csv data/fastf1_cmp.csv LEC VER
```

Interactive picker from a full exported session folder:

```bash
./build/f1_ghost_app data/monaco_q
```

## Output

Running the app writes:
- `output/frame_0.bmp`, `output/frame_1.bmp`, ...
- `output/viewer.html`

The HTML viewer shows:
- reference and compare driver
- session name, using labels like `Race`, `Qualifying`, and `Free Practice 1`
- selected lap number and lap time for each driver
- the rendered replay frames

Open the viewer in a browser:

### Windows

```bat
explorer .\output\viewer.html
```

### Linux

```bash
xdg-open output/viewer.html
```

## Quick Start

### Windows

```bat
set CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2
set PATH=%CUDA_PATH%\bin;%PATH%
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 -T "cuda=%CUDA_PATH%"
cmake --build build --config Release
python scripts\export_fastf1_laps.py --year 2025 --event Monaco --session R --export-all-dir data\monaco_2025_r_all --lap-mode all-laps
.\build\Release\f1_ghost_app.exe data\monaco_2025_r_all
explorer .\output\viewer.html
```

### Linux

```bash
cmake -S . -B build
cmake --build build -j
python scripts/export_fastf1_laps.py --year 2025 --event Monaco --session R --export-all-dir data/monaco_2025_r_all --lap-mode all-laps
./build/f1_ghost_app data/monaco_2025_r_all
xdg-open output/viewer.html
```
