cmake_minimum_required(VERSION 3.22.1)
project(rish_gpui_host LANGUAGES CXX)
if(NOT DEFINED RISH_ANDROID_CPP)
  message(FATAL_ERROR "RISH_ANDROID_CPP must name the shared Android JNI source directory")
endif()
# Reuse the source-built JNI shims and shared Git implementation verbatim.
add_subdirectory("${RISH_ANDROID_CPP}" "${CMAKE_BINARY_DIR}/rish-runtime")
