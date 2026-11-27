cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

add_executable(${BINARY_NAME} WIN32
  "auxiliary_window.cpp"
  "bubble_layout.cpp"
  "clipboard.cpp"
  "credentials.cpp"
  "file_dialogs.cpp"
  "flutter_window.cpp"
  "global_hotkeys.cpp"
  "input_bubble.cpp"
  "json_codec.cpp"
  "key_names.cpp"
  "language_detection.cpp"
  "main.cpp"
  "main_thread.cpp"
  "overlay_window.cpp"
  "platform_bridge.cpp"
  "preferences_store.cpp"
  "selection_capture.cpp"
  "selection_context.cpp"
  "selection_monitor.cpp"
  "selection_watcher.cpp"
  "shortcut_rules.cpp"
  "speech_service.cpp"
  "synthetic_input.cpp"
  "text_encoding.cpp"
  "text_file.cpp"
  "tray_icon.cpp"
  "uia_selection.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "windows_system.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

apply_standard_settings(${BINARY_NAME})

target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_20)

target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib" "elscore.lib" "version.lib" "windowsapp.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

add_dependencies(${BINARY_NAME} flutter_assemble)
