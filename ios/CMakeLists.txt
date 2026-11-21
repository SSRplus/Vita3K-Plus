# Vita3KiOS: UIKit front-end + the emulator core (static libs) for iOS 16+
cmake_minimum_required(VERSION 3.22)

set(VITA3K_ROOT "${CMAKE_SOURCE_DIR}")
set(BUNDLE_ID "com.github.Vita3K.ios" CACHE STRING "CFBundleIdentifier of the app")
set(APP_MARKETING_VERSION "0.1.0" CACHE STRING "CFBundleShortVersionString")

set(IOS_CORE_SOURCES
	core/ios_jit.cpp
	core/ios_jit.h
	core/vita3k_ios.cpp
	core/vita3k_ios.h
)

set(IOS_APP_SOURCES
	app/main.mm
	app/AppDelegate.mm
	app/LibraryViewController.mm
	app/SettingsViewController.mm
	app/GameViewController.mm
	app/VirtualGamepadView.mm
	app/InstallHelper.mm
)

add_executable(Vita3KiOS MACOSX_BUNDLE ${IOS_CORE_SOURCES} ${IOS_APP_SOURCES})

target_include_directories(Vita3KiOS PRIVATE
	core
	app
	${VITA3K_ROOT}/vita3k
)

set_source_files_properties(${IOS_APP_SOURCES} PROPERTIES COMPILE_FLAGS "-fobjc-arc")
set_source_files_properties(${IOS_APP_SOURCES} PROPERTIES SKIP_PRECOMPILE_HEADERS ON)

# the entire emulator is reused: the `vita3k` static library already links every module
target_link_libraries(Vita3KiOS PRIVATE
	vita3k
	SDL3::SDL3
	pugixml::pugixml
	"-framework UIKit"
	"-framework Foundation"
	"-framework QuartzCore"
	"-framework Metal"
	"-framework AVFoundation"
	"-framework AudioToolbox"
	"-framework CoreAudio"
	"-framework CoreMotion"
	"-framework CoreHaptics"
	"-framework GameController"
	"-framework CoreGraphics"
	"-framework CoreVideo"
	"-framework CoreMedia"
	"-framework UniformTypeIdentifiers"
	"-framework IOSurface"
	"-framework Security"
	"-framework SystemConfiguration"
)

set_target_properties(Vita3KiOS PROPERTIES
	OUTPUT_NAME "Vita3KiOS"
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
	MACOSX_BUNDLE_GUI_IDENTIFIER "${BUNDLE_ID}"
	MACOSX_BUNDLE_BUNDLE_NAME "Vita3K"
	MACOSX_BUNDLE_BUNDLE_VERSION "1"
	MACOSX_BUNDLE_SHORT_VERSION_STRING "${APP_MARKETING_VERSION}"
	XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
	BUILD_RPATH "@executable_path/Frameworks"
	INSTALL_RPATH "@executable_path/Frameworks"
	BUILD_WITH_INSTALL_RPATH ON
	RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/ios-bin"
)

# whole-archive for static module registries is not needed (modules are referenced explicitly),
# but dead stripping and ICF keep the binary small and the I-cache footprint low.
target_link_options(Vita3KiOS PRIVATE -Wl,-dead_strip -Wl,-dead_strip_dylibs)

# resources the emulator expects in <static assets>: data/, shaders-builtin/, icons/
set(APP_DIR "$<TARGET_BUNDLE_DIR:Vita3KiOS>")
add_custom_command(TARGET Vita3KiOS POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E make_directory "${APP_DIR}/Frameworks"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${VITA3K_ROOT}/data" "${APP_DIR}/data"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${VITA3K_ROOT}/vita3k/shaders-builtin" "${APP_DIR}/shaders-builtin"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${VITA3K_ROOT}/vita3k/icons" "${APP_DIR}/icons"
	COMMAND ${CMAKE_COMMAND} -E copy_if_different "${MOLTENVK_DYLIB}" "${APP_DIR}/Frameworks/libMoltenVK.dylib"
	COMMAND sips -z 120 120 "${VITA3K_ROOT}/vita3k/Vita3K.png" --out "${APP_DIR}/AppIcon60x60@2x.png"
	COMMAND sips -z 180 180 "${VITA3K_ROOT}/vita3k/Vita3K.png" --out "${APP_DIR}/AppIcon60x60@3x.png"
	COMMAND sips -z 152 152 "${VITA3K_ROOT}/vita3k/Vita3K.png" --out "${APP_DIR}/AppIcon76x76@2x~ipad.png"
	COMMENT "Bundling resources, MoltenVK and icons"
	VERBATIM
)
