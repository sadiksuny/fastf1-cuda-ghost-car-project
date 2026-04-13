cmake_minimum_required(VERSION 3.22)
project(f1_cuda_ghost_car LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

add_library(lap_core
    src/telemetry_loader.cpp
    src/lap_processing.cu
    src/renderer.cpp
    src/ui.cpp)

target_include_directories(lap_core PUBLIC src)

target_compile_options(lap_core PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:--expt-relaxed-constexpr>
    $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=/Zc:preprocessor>)

add_executable(f1_ghost_app src/main.cpp)
target_link_libraries(f1_ghost_app PRIVATE lap_core)
