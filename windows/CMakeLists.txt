# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(tsumugi LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "tsumugi")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)
# flutter_inappwebview_windows 通过 C++/WinRT 引入 <experimental/coroutine>，
# VS 2026（MSVC 14.51）起默认报错 STL1011；在插件迁移到 C++20 协程之前先按 MSVC 提示静默。
add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# === 自建 libmpv（docs/architecture.md §6.4.6 第 2 项）===
# media_kit_libs_windows_video 固定的是 2023-09 的 libmpv（FFmpeg 6.0）。这里改用本项目自建的版本
# （Shiroha23/Tsumugi-libmpv 的 Release，地址与 sha256 固定在 windows/libmpv.lock），校验后解压到插件使用的
# 同一目录 ${CMAKE_BINARY_DIR}/libmpv（libmpv-2.dll、libmpv.dll.a、include/*.h）。
# 插件只在该目录为空时才解压它自己的旧版本，打包列表与 media_kit_video 的头文件 / 导入库路径都指向这里，
# 因此必须在 include(flutter/generated_plugins.cmake) 之前完成。
set(TSUMUGI_LIBMPV_LOCK "${CMAKE_CURRENT_SOURCE_DIR}/libmpv.lock")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${TSUMUGI_LIBMPV_LOCK}")
file(STRINGS "${TSUMUGI_LIBMPV_LOCK}" _tsumugi_libmpv_lines REGEX "^[a-z_0-9]+\t")
foreach(_line IN LISTS _tsumugi_libmpv_lines)
  string(REGEX MATCH "^([a-z_0-9]+)\t(.+)$" _m "${_line}")
  set(_tsumugi_lock_${CMAKE_MATCH_1} "${CMAKE_MATCH_2}")
endforeach()
set(TSUMUGI_LIBMPV_TAG "${_tsumugi_lock_tag}")
set(TSUMUGI_LIBMPV_URL "${_tsumugi_lock_zip_url}")
string(TOLOWER "${_tsumugi_lock_zip_sha256}" TSUMUGI_LIBMPV_SHA256)
if(NOT TSUMUGI_LIBMPV_TAG MATCHES "^libmpv-win-[0-9a-z.+-]+$"
    OR NOT TSUMUGI_LIBMPV_URL MATCHES "^https://github\\.com/Shiroha23/Tsumugi-libmpv/releases/download/"
    OR NOT TSUMUGI_LIBMPV_SHA256 MATCHES "^[0-9a-f]+$")
  message(FATAL_ERROR "windows/libmpv.lock: invalid tag / zip_url / zip_sha256")
endif()
string(LENGTH "${TSUMUGI_LIBMPV_SHA256}" _tsumugi_len)
if(NOT _tsumugi_len EQUAL 64)
  message(FATAL_ERROR "windows/libmpv.lock: zip_sha256 must be 64 hex digits")
endif()
set(TSUMUGI_LIBMPV_DIR "${CMAKE_BINARY_DIR}/libmpv")
set(TSUMUGI_LIBMPV_STAMP "${TSUMUGI_LIBMPV_DIR}/.tsumugi-libmpv")
set(TSUMUGI_LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${TSUMUGI_LIBMPV_TAG}.zip")
set(TSUMUGI_LIBMPV_FILES libmpv-2.dll libmpv.dll.a include/client.h include/render.h include/render_gl.h)
if(CMAKE_VERSION VERSION_LESS 3.18)
  message(FATAL_ERROR "CMake 3.18 or newer is required (file(ARCHIVE_EXTRACT))")
endif()

# 已解压的副本只在三者都成立时复用：标记中的 zip sha256 与清单一致、文件齐全、DLL 的 sha256 与解压时记录的一致。
set(_tsumugi_libmpv_reuse FALSE)
if(EXISTS "${TSUMUGI_LIBMPV_STAMP}")
  file(STRINGS "${TSUMUGI_LIBMPV_STAMP}" _tsumugi_stamp LIMIT_COUNT 2)
  list(LENGTH _tsumugi_stamp _tsumugi_stamp_len)
  if(_tsumugi_stamp_len EQUAL 2)
    list(GET _tsumugi_stamp 0 _tsumugi_stamp_zip)
    list(GET _tsumugi_stamp 1 _tsumugi_stamp_dll)
    set(_tsumugi_libmpv_reuse TRUE)
    foreach(_f IN LISTS TSUMUGI_LIBMPV_FILES)
      if(NOT EXISTS "${TSUMUGI_LIBMPV_DIR}/${_f}")
        set(_tsumugi_libmpv_reuse FALSE)
      endif()
    endforeach()
    if(_tsumugi_libmpv_reuse AND _tsumugi_stamp_zip STREQUAL TSUMUGI_LIBMPV_SHA256)
      file(SHA256 "${TSUMUGI_LIBMPV_DIR}/libmpv-2.dll" _tsumugi_dll_hash)
      if(NOT _tsumugi_dll_hash STREQUAL _tsumugi_stamp_dll)
        set(_tsumugi_libmpv_reuse FALSE)
      endif()
    else()
      set(_tsumugi_libmpv_reuse FALSE)
    endif()
  endif()
endif()

if(NOT _tsumugi_libmpv_reuse)
  set(_tsumugi_libmpv_ok FALSE)
  if(EXISTS "${TSUMUGI_LIBMPV_ARCHIVE}")
    file(SHA256 "${TSUMUGI_LIBMPV_ARCHIVE}" _tsumugi_libmpv_hash)
    if(_tsumugi_libmpv_hash STREQUAL TSUMUGI_LIBMPV_SHA256)
      set(_tsumugi_libmpv_ok TRUE)
    endif()
  endif()
  if(NOT _tsumugi_libmpv_ok)
    message(STATUS "Downloading ${TSUMUGI_LIBMPV_URL}")
    # 内容由 sha256 校验；时限防止下载无限挂起（zip 约 8 MB）。
    file(DOWNLOAD "${TSUMUGI_LIBMPV_URL}" "${TSUMUGI_LIBMPV_ARCHIVE}.part"
      TLS_VERIFY ON TIMEOUT 600 INACTIVITY_TIMEOUT 60 STATUS _tsumugi_libmpv_status)
    list(GET _tsumugi_libmpv_status 0 _tsumugi_libmpv_code)
    if(NOT _tsumugi_libmpv_code EQUAL 0)
      file(REMOVE "${TSUMUGI_LIBMPV_ARCHIVE}.part")
      message(FATAL_ERROR "libmpv download failed: ${_tsumugi_libmpv_status}")
    endif()
    file(SHA256 "${TSUMUGI_LIBMPV_ARCHIVE}.part" _tsumugi_libmpv_hash)
    if(NOT _tsumugi_libmpv_hash STREQUAL TSUMUGI_LIBMPV_SHA256)
      file(REMOVE "${TSUMUGI_LIBMPV_ARCHIVE}.part")
      message(FATAL_ERROR "libmpv sha256 mismatch: expected ${TSUMUGI_LIBMPV_SHA256}, got ${_tsumugi_libmpv_hash}")
    endif()
    file(RENAME "${TSUMUGI_LIBMPV_ARCHIVE}.part" "${TSUMUGI_LIBMPV_ARCHIVE}")
  endif()
  # 旧版本（含插件解压的 2023 版）整个删除后再解压，避免残留文件。
  file(REMOVE_RECURSE "${TSUMUGI_LIBMPV_DIR}" "${CMAKE_BINARY_DIR}/libmpv-extract")
  file(ARCHIVE_EXTRACT INPUT "${TSUMUGI_LIBMPV_ARCHIVE}" DESTINATION "${CMAKE_BINARY_DIR}/libmpv-extract")
  file(RENAME "${CMAKE_BINARY_DIR}/libmpv-extract/${TSUMUGI_LIBMPV_TAG}" "${TSUMUGI_LIBMPV_DIR}")
  file(REMOVE_RECURSE "${CMAKE_BINARY_DIR}/libmpv-extract")
  foreach(_f IN LISTS TSUMUGI_LIBMPV_FILES)
    if(NOT EXISTS "${TSUMUGI_LIBMPV_DIR}/${_f}")
      message(FATAL_ERROR "libmpv archive is missing ${_f}")
    endif()
  endforeach()
  file(SHA256 "${TSUMUGI_LIBMPV_DIR}/libmpv-2.dll" _tsumugi_dll_hash)
  file(WRITE "${TSUMUGI_LIBMPV_STAMP}" "${TSUMUGI_LIBMPV_SHA256}\n${_tsumugi_dll_hash}\n")
endif()

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# 防止插件改变目录约定后悄悄打包它自己的旧 libmpv。
if(NOT "${TSUMUGI_LIBMPV_DIR}/libmpv-2.dll" IN_LIST PLUGIN_BUNDLED_LIBRARIES)
  message(FATAL_ERROR "media_kit_libs_windows_video no longer bundles ${TSUMUGI_LIBMPV_DIR}/libmpv-2.dll")
endif()

# media_kit_libs_windows_video 随 ANGLE 打包了 d3dcompiler_47.dll（微软可再分发组件，非开源）。
# 不随本项目分发：ANGLE 使用 Windows 10 起系统自带的同名 DLL（architecture §6.4.1）。
list(FILTER PLUGIN_BUNDLED_LIBRARIES EXCLUDE REGEX "[/\\\\]d3dcompiler_47\\.dll$")


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# 删除旧构建留在输出目录中的 d3dcompiler_47.dll（install 不会清理已排除的文件）。
install(CODE "
  file(REMOVE \"${INSTALL_BUNDLE_LIB_DIR}/d3dcompiler_47.dll\")
  " COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
