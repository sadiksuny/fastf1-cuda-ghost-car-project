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

### Linux

Built-in sample laps:

```bash
./build/f1_ghost_app
```

Two CSV files with labels:

```bash
./build/f1_ghost_app data/fastf1_ref.csv data/fastf1_cmp.csv LEC VER
```

## Output

Running the app writes:
- `output/frame_*.ppm`
- `output/frame_*.bmp`
- `output/viewer.html`

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
.\build\Release\f1_ghost_app.exe data\fastf1_ref.csv data\fastf1_cmp.csv LEC VER
explorer .\output\viewer.html
```

### Linux

```bash
cmake -S . -B build
cmake --build build -j
./build/f1_ghost_app data/fastf1_ref.csv data/fastf1_cmp.csv LEC VER
xdg-open output/viewer.html
```
