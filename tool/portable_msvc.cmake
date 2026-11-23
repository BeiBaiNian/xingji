# Flutter passes -G explicitly. Initialize the unregistered VS instance in
# CMake's cache during the first configure and keep that selection on rebuilds.
if(CMAKE_GENERATOR MATCHES "^Visual Studio" AND NOT CMAKE_GENERATOR_INSTANCE AND DEFINED ENV{XINGJI_PORTABLE_VS_INSTANCE})
  set(CMAKE_GENERATOR_INSTANCE "$ENV{XINGJI_PORTABLE_VS_INSTANCE}" CACHE INTERNAL "Portable Visual Studio instance")
endif()
