#
# SPDX-FileCopyrightText: 2025 Eduard Valeyev <eduard@valeyev.net>
#
# SPDX-License-Identifier: BSD-2-Clause
#

include(CheckCXXSourceCompiles)
include(CMakePushCheckState)

# if TBB_FOUND is true will check for usable <execution> without TBB, then with TBB
macro(vgkit_check_cxx_execution_header _prefix)

  ##############################################
  # compilation checks
  ##############################################
  set(_prereq_list "_STANDALONE")
  if (TARGET TBB::tbb)
    list(APPEND _prereq_list _WITH_TBB)
  endif ()

  foreach (_prereq ${_prereq_list})
    cmake_push_check_state()

    if (_prereq STREQUAL _WITH_TBB)
      list(APPEND CMAKE_REQUIRED_LIBRARIES TBB::tbb)
    endif ()

    CHECK_CXX_SOURCE_COMPILES(
        "
  #include <algorithm>
  #include <vector>
  #include <execution>
  int main(int argc, char** argv) {
    std::vector<int> v{0,1,2};
    std::for_each(std::execution::par_unseq, begin(v), end(v),
                  [](auto&& i) {i *= 2;});
    return 0;
  }
  " ${_prefix}_HAS_EXECUTION_HEADER${_prereq})

    cmake_pop_check_state()
    if (${_prefix}_HAS_EXECUTION_HEADER${_prereq})
      break()
    endif ()

  endforeach (_prereq)

endmacro(vgkit_check_cxx_execution_header)

# Non-Apple Clang (e.g. Homebrew LLVM) may use its own libc++ headers
# but link against the system's older libc++.  This causes linker errors
# for symbols (like std::__1::__hash_memory) that exist in the newer headers
# but not the system library.  Detect the mismatch and, if possible, derive
# -L/-rpath flags pointing to the toolchain's own libc++.
#
# Usage:
#   vgkit_check_libcxx_linker_mismatch()                    # detect only, warn if mismatch found
#   vgkit_check_libcxx_linker_mismatch(MODIFY_GLOBAL_FLAGS) # detect and fix via global linker flags
#
# The MODIFY_GLOBAL_FLAGS option should only be used by the top-level project;
# subprojects and package configs should call without it and let the top-level
# project handle global linker state.
macro(vgkit_check_libcxx_linker_mismatch)

  set(_clmm_modify_global FALSE)
  foreach(_clmm_arg ${ARGN})
    if (_clmm_arg STREQUAL "MODIFY_GLOBAL_FLAGS")
      set(_clmm_modify_global TRUE)
    endif()
  endforeach()

  if (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND
      NOT CMAKE_CXX_COMPILER_ID STREQUAL "AppleClang")
    cmake_push_check_state(RESET)
    check_cxx_source_compiles("
#include <unordered_map>
#include <string>
int main() { std::unordered_map<std::string,int> m; m[\"k\"]=1; return 0; }
" VGKIT_LIBCXX_LINKS)
    cmake_pop_check_state()

    if (NOT VGKIT_LIBCXX_LINKS)
      # Derive libc++ lib dir: -print-resource-dir gives <root>/lib/clang/<ver>
      execute_process(
        COMMAND ${CMAKE_CXX_COMPILER} -print-resource-dir
        OUTPUT_VARIABLE _clang_resource_dir OUTPUT_STRIP_TRAILING_WHITESPACE)
      cmake_path(GET _clang_resource_dir PARENT_PATH _clang_lib_dir)   # <root>/lib/clang
      cmake_path(GET _clang_lib_dir PARENT_PATH _clang_lib_dir)        # <root>/lib
      set(_clang_libcxx_dir "${_clang_lib_dir}/c++")

      if (EXISTS "${_clang_libcxx_dir}/libc++.dylib" OR
          EXISTS "${_clang_libcxx_dir}/libc++.so")
        cmake_push_check_state(RESET)
        set(CMAKE_REQUIRED_LINK_OPTIONS
          "-L${_clang_libcxx_dir}" "-Wl,-rpath,${_clang_libcxx_dir}")
        check_cxx_source_compiles("
#include <unordered_map>
#include <string>
int main() { std::unordered_map<std::string,int> m; m[\"k\"]=1; return 0; }
" VGKIT_LIBCXX_LINKS_WITH_FLAGS)
        cmake_pop_check_state()

        if (VGKIT_LIBCXX_LINKS_WITH_FLAGS)
          if (_clmm_modify_global)
            message(STATUS "libc++ linker mismatch detected; adding -L${_clang_libcxx_dir} to global linker flags")
            string(APPEND CMAKE_EXE_LINKER_FLAGS
              " -L${_clang_libcxx_dir} -Wl,-rpath,${_clang_libcxx_dir}")
            string(APPEND CMAKE_SHARED_LINKER_FLAGS
              " -L${_clang_libcxx_dir} -Wl,-rpath,${_clang_libcxx_dir}")
          else()
            message(WARNING
              "Clang's libc++ headers do not match the linked libc++ library. "
              "Call vgkit_check_libcxx_linker_mismatch(MODIFY_GLOBAL_FLAGS) from your "
              "top-level CMakeLists.txt, or manually add to "
              "CMAKE_EXE_LINKER_FLAGS / CMAKE_SHARED_LINKER_FLAGS:\n"
              "  -L${_clang_libcxx_dir} -Wl,-rpath,${_clang_libcxx_dir}")
          endif()
        else()
          message(FATAL_ERROR
            "Clang's libc++ headers do not match the linked libc++ library, "
            "and adding -L${_clang_libcxx_dir} did not help. "
            "Set CMAKE_EXE_LINKER_FLAGS and CMAKE_SHARED_LINKER_FLAGS to point "
            "to the matching libc++.")
        endif()
      else()
        message(FATAL_ERROR
          "Clang's libc++ headers do not match the linked libc++ library, "
          "and no libc++ was found in ${_clang_libcxx_dir}. "
          "Set CMAKE_EXE_LINKER_FLAGS and CMAKE_SHARED_LINKER_FLAGS to point "
          "to the matching libc++.")
      endif()
      unset(_clang_resource_dir)
      unset(_clang_lib_dir)
      unset(_clang_libcxx_dir)
    endif()
  endif()

  unset(_clmm_modify_global)

endmacro(vgkit_check_libcxx_linker_mismatch)