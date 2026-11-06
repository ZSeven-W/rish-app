# The probe reuses the native runtime's JNI shim source.
cmake_minimum_required(VERSION 3.22.1)
project(guestprobe)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../src/main/cpp rish_jni)

# The probe's own diagnostics, deliberately independent of the guest runtime:
# they have to keep working when the runtime is the thing that failed.
add_library(guestprobe_jni SHARED probe_jni.cpp)
target_compile_features(guestprobe_jni PRIVATE cxx_std_17)
target_compile_options(guestprobe_jni PRIVATE -fvisibility=hidden -Wall -Wextra)
