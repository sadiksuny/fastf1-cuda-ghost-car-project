cmake_minimum_required(VERSION 3.22)
project(f1_cuda_ghost_car LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

option(BUILD_TESTS "Build unit tests" ON)

add_library(lap_core
    src/telemetry_loader.cpp
    src/lap_processing.cu
    src/renderer.cpp
    src/ui.cpp)

target_include_directories(lap_core PUBLIC src)

target_compile_options(lap_core PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:--expt-relaxed-constexpr>)

add_executable(f1_ghost_app src/main.cpp)
target_link_libraries(f1_ghost_app PRIVATE lap_core)

if(BUILD_TESTS)
  enable_testing()

  add_executable(test_distance tests/test_distance.cpp)
  target_link_libraries(test_distance PRIVATE lap_core)
  add_test(NAME distance_alignment_test COMMAND test_distance)

  add_executable(test_interpolation tests/test_interpolation.cpp)
  target_link_libraries(test_interpolation PRIVATE lap_core)
  add_test(NAME interpolation_test COMMAND test_interpolation)
endif()
