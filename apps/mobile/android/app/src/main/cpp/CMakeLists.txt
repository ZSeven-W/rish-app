# Included from ../jni/CMakeLists.txt, which is the CMake entry point Gradle
# builds. No `project()` here: the top-level project is `appmodules`, and
# React Native's application setup uses CMAKE_PROJECT_NAME as its library name.
cmake_minimum_required(VERSION 3.22.1)
enable_language(CXX)

# Both Rust libraries are staged as prebuilt cdylibs per ABI plus their
# headers — the guest runtime by scripts/prepare-rish-android.sh, the agent
# core by scripts/prepare-rish-agent-core-android.sh. Gradle passes whichever
# staging directories exist; nothing here downloads or builds Rust, and each
# shim is built only when its own runtime is staged.
if(NOT DEFINED RISH_FFI_DIR AND NOT DEFINED RISH_AGENT_CORE_DIR)
  message(FATAL_ERROR "RISH_FFI_DIR or RISH_AGENT_CORE_DIR is required; run scripts/prepare-rish-android.sh first")
endif()

# Rust cdylibs carry no ELF SONAME by default. Without IMPORTED_NO_SONAME,
# CMake can record the build-machine absolute path in DT_NEEDED instead of the
# bare file name the Android loader resolves from nativeLibraryDir.
function(rish_import_staged_library target directory library)
  set(path "${directory}/jniLibs/${ANDROID_ABI}/${library}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "no staged ${library} for ${ANDROID_ABI}: ${path}")
  endif()
  add_library(${target} SHARED IMPORTED)
  set_target_properties(
    ${target}
    PROPERTIES IMPORTED_LOCATION "${path}" IMPORTED_NO_SONAME TRUE
  )
endfunction()

function(rish_add_shim target source directory linked)
  add_library(${target} SHARED ${source})
  target_include_directories(${target} PRIVATE "${directory}/include")
  target_compile_features(${target} PRIVATE cxx_std_17)
  target_compile_options(${target} PRIVATE -fvisibility=hidden -Wall -Wextra)
  target_link_libraries(${target} PRIVATE ${linked})
endfunction()

if(DEFINED RISH_FFI_DIR)
  rish_import_staged_library(rish_ffi "${RISH_FFI_DIR}" librish_ffi.so)
  rish_add_shim(rish_guest_jni rish_guest_jni.cpp "${RISH_FFI_DIR}" rish_ffi)
endif()

if(DEFINED RISH_AGENT_CORE_DIR)
  rish_import_staged_library(rish_agent_ffi "${RISH_AGENT_CORE_DIR}" librish_agent_ffi.so)
  rish_add_shim(rish_agent_core_jni rish_agent_core_jni.cpp
                "${RISH_AGENT_CORE_DIR}" rish_agent_ffi)
endif()

# libgit2 and its two dependencies are staged as static archives per ABI by
# scripts/prepare-libgit2-android.sh. Unlike the Rust cdylibs above they are
# linked into a shim rather than loaded beside it, so the app ships one more
# .so rather than four.
if(DEFINED RISH_LIBGIT2_DIR)
  foreach(library libgit2 libssh2 libssl libcrypto)
    set(archive "${RISH_LIBGIT2_DIR}/${ANDROID_ABI}/${library}.a")
    if(NOT EXISTS "${archive}")
      message(FATAL_ERROR "no staged ${library} for ${ANDROID_ABI}: ${archive}")
    endif()
    add_library(rish_${library} STATIC IMPORTED)
    set_target_properties(rish_${library} PROPERTIES IMPORTED_LOCATION "${archive}")
  endforeach()
  add_library(rish_libgit2_jni SHARED rish_libgit2_jni.cpp rish_project_git.cpp rish_project_panel.cpp rish_project_capture.cpp rish_project_agent.cpp rish_project_remote.cpp)
  target_include_directories(rish_libgit2_jni PRIVATE "${RISH_LIBGIT2_DIR}/include")
  target_compile_features(rish_libgit2_jni PRIVATE cxx_std_17)
  target_compile_options(rish_libgit2_jni PRIVATE -fvisibility=hidden -Wall -Wextra)
  # libgit2 needs libssh2, which needs OpenSSL; the order is what the static
  # linker resolves against.
  target_link_libraries(
    rish_libgit2_jni PRIVATE rish_libgit2 rish_libssh2 rish_libssl rish_libcrypto
  )
endif()
