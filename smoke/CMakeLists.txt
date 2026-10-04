# Builds smoke (and generate) against an UNPACKED release archive, the way
# a consumer links it: include/, lib/ (import libraries on Windows), and
# nothing from the build tree.
#
#   cmake -S smoke -B build-smoke -DPREBUILT=<unpacked archive root>
cmake_minimum_required(VERSION 3.14)
project(llama_cpp_prebuilt_smoke C)

if(NOT PREBUILT)
  message(FATAL_ERROR "-DPREBUILT=<unpacked archive root> is required")
endif()

set(libs)
foreach(name llama ggml ggml-base)
  find_library(LIB_${name} NAMES ${name} PATHS "${PREBUILT}/lib" NO_DEFAULT_PATH REQUIRED)
  list(APPEND libs "${LIB_${name}}")
endforeach()

foreach(exe smoke generate)
  add_executable(${exe} ${exe}.c)
  target_include_directories(${exe} PRIVATE "${PREBUILT}/include")
  target_link_libraries(${exe} PRIVATE ${libs})
  if(UNIX)
    target_link_libraries(${exe} PRIVATE ${CMAKE_DL_LIBS})
    # The archive's lib/ on the executable's rpath; what each library
    # needs after that it must find through its own $ORIGIN/@loader_path.
    set_target_properties(${exe} PROPERTIES BUILD_RPATH "${PREBUILT}/lib")
  endif()
endforeach()
