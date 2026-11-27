cmake_minimum_required(VERSION 3.14)
project(transnap_native_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/refs/tags/v1.17.0.zip
)
FetchContent_MakeAvailable(googletest)

set(RUNNER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../runner")
set(WRAPPER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../flutter/ephemeral/cpp_client_wrapper/include")

add_executable(native_tests
  "json_codec_test.cpp"
  "key_names_test.cpp"
  "language_detection_test.cpp"
  "preferences_store_test.cpp"
  "selection_context_test.cpp"
  "text_file_test.cpp"
  "tooltip_layout_test.cpp"
  "${RUNNER_DIR}/json_codec.cpp"
  "${RUNNER_DIR}/key_names.cpp"
  "${RUNNER_DIR}/language_detection.cpp"
  "${RUNNER_DIR}/preferences_store.cpp"
  "${RUNNER_DIR}/selection_context.cpp"
  "${RUNNER_DIR}/text_file.cpp"
  "${RUNNER_DIR}/tooltip_layout.cpp"
  "${RUNNER_DIR}/utils.cpp"
)
target_include_directories(native_tests PRIVATE "${RUNNER_DIR}" "${WRAPPER_DIR}")
target_compile_options(native_tests PRIVATE /W4 /WX /utf-8)
target_link_libraries(native_tests PRIVATE GTest::gtest_main elscore.lib)

enable_testing()
include(GoogleTest)
gtest_discover_tests(native_tests)
