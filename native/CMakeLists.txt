cmake_minimum_required(VERSION 3.24)

project(local_image_optimizer LANGUAGES CXX)

add_executable(image_optimizer src/main.cpp)
target_compile_features(image_optimizer PRIVATE cxx_std_17)

if(WIN32)
  target_link_libraries(image_optimizer PRIVATE windowscodecs ole32 oleaut32)
else()
  message(FATAL_ERROR "The native optimizer currently uses Windows Imaging Component and must be built on Windows.")
endif()
