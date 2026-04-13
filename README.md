# F1 Driver-vs-Driver Lap Delta Visualizer with Ghost Car (CUDA C++)

This prototype compares two laps, aligns them by cumulative distance, computes lap delta on the GPU, and writes rendered track frames with two ghost markers.

## Current prototype scope

- Loads laps from CSV (`x,y,t[,speed,throttle,brake]`) or built-in sample laps.
- Computes segment lengths and cumulative distance.
- Resamples both laps onto one uniform distance grid.
- Computes `delta_t(s) = t_compare(s) - t_reference(s)` with CUDA kernels.
- Optional smoothing with a shared-memory box filter.
- Renders a simple 2D track map to PPM frames color-coded by delta.
- Draws two ghost markers per frame:
  - Green: reference lap marker
  - Yellow: compare lap marker

## Build

```bash
cmake -S . -B build
cmake --build build -j
```

## Run

With built-in sample data:

```bash
./build/f1_ghost_app
```

With CSV files:

```bash
./build/f1_ghost_app data/sample_ref.csv data/sample_cmp.csv
```

The app writes frames into `output/frame_*.ppm`.

## Run tests

```bash
ctest --test-dir build --output-on-failure
```

## CUDA container (recommended)

This repo includes a CUDA dev container so you can build/run without installing toolchains locally.

Build image:

```bash
docker build -f Dockerfile.cuda -t f1-cuda-ghost:dev .
```

Run container (with GPU):

```bash
docker run --rm -it --gpus all -v "$PWD":/workspace/f1 -w /workspace/f1 f1-cuda-ghost:dev
```

Inside the container:

```bash
cmake -S . -B build
cmake --build build -j
ctest --test-dir build --output-on-failure
```

## Project layout

- `src/telemetry_loader.*`: CSV loader + sample lap generator.
- `src/lap_processing.cu/.cuh`: CUDA distance, resampling, delta, smoothing pipeline.
- `src/renderer.*`: Render-ready frame generation and PPM output.
- `src/ui.*`: Minimal prototype loop and toggles.
- `tests/`: correctness tests for cumulative distance and interpolation/delta.
