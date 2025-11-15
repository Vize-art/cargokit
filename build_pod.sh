#!/bin/sh
set -e

BASEDIR=$(dirname "$0")

# Workaround for https://github.com/dart-lang/pub/issues/4010
BASEDIR=$(cd "$BASEDIR" ; pwd -P)

# Remove XCode SDK from path. Otherwise this breaks tool compilation when building iOS project
NEW_PATH=`echo $PATH | tr ":" "\n" | grep -v "Contents/Developer/" | tr "\n" ":"`

export PATH=${NEW_PATH%?} # remove trailing :

env

# Platform name (macosx, iphoneos, iphonesimulator)
export CARGOKIT_DARWIN_PLATFORM_NAME=$PLATFORM_NAME

# Smart architecture detection for iOS builds
# For debug builds, try to detect if we're building for a specific device
if [ "$CONFIGURATION" = "Debug" ]; then
    # Xcode sets PLATFORM_NAME to indicate target type
    if [ "$PLATFORM_NAME" = "iphonesimulator" ]; then
        # Building for simulator
        # Use only the architecture matching the host Mac
        HOST_ARCH="$(uname -m)"

        if [ "$HOST_ARCH" = "arm64" ]; then
            # Apple Silicon Mac - use arm64 simulator
            echo "CargoKit: Debug build for Apple Silicon simulator (arm64)"
            export CARGOKIT_DARWIN_ARCHS="arm64"
        else
            # Intel Mac - use x86_64 simulator
            echo "CargoKit: Debug build for Intel simulator (x86_64)"
            export CARGOKIT_DARWIN_ARCHS="x86_64"
        fi
    elif [ "$PLATFORM_NAME" = "iphoneos" ]; then
        # Building for physical device
        # Check if we're building for a single architecture
        ARCH_COUNT=$(echo "$ARCHS" | wc -w)

        if [ "$ARCH_COUNT" -eq 1 ]; then
            # Single architecture - use it
            echo "CargoKit: Debug build for device architecture: $ARCHS"
            export CARGOKIT_DARWIN_ARCHS=$ARCHS
        else
            # Multiple architectures but debug build for device
            # This is unusual, but respect what Xcode wants
            echo "CargoKit: Debug device build with multiple architectures: $ARCHS"
            export CARGOKIT_DARWIN_ARCHS=$ARCHS
        fi
    elif [ "$PLATFORM_NAME" = "macosx" ]; then
        # macOS build
        # Check if building for current architecture only
        if [ -n "$NATIVE_ARCH" ]; then
            echo "CargoKit: Debug macOS build for native architecture: $NATIVE_ARCH"
            export CARGOKIT_DARWIN_ARCHS=$NATIVE_ARCH
        elif [ "$ARCHS" = "x86_64 arm64" ] || [ "$ARCHS" = "arm64 x86_64" ]; then
            # Universal binary requested, but for debug we can use just native arch
            HOST_ARCH="$(uname -m)"
            if [ "$HOST_ARCH" = "arm64" ]; then
                echo "CargoKit: Debug macOS build, using native arm64"
                export CARGOKIT_DARWIN_ARCHS="arm64"
            else
                echo "CargoKit: Debug macOS build, using native x86_64"
                export CARGOKIT_DARWIN_ARCHS="x86_64"
            fi
        else
            echo "CargoKit: Debug macOS build: $ARCHS"
            export CARGOKIT_DARWIN_ARCHS=$ARCHS
        fi
    else
        # Unknown platform, use what Xcode provides
        export CARGOKIT_DARWIN_ARCHS=$ARCHS
    fi
else
    # Release build - use all architectures that Xcode specifies
    echo "CargoKit: Release build for architectures: $ARCHS"
    export CARGOKIT_DARWIN_ARCHS=$ARCHS
fi

# Current build configuration (Debug, Release)
export CARGOKIT_CONFIGURATION=$CONFIGURATION

# Path to directory containing Cargo.toml.
export CARGOKIT_MANIFEST_DIR=$PODS_TARGET_SRCROOT/$1

# Temporary directory for build artifacts.
export CARGOKIT_TARGET_TEMP_DIR=$TARGET_TEMP_DIR

# Output directory for final artifacts.
export CARGOKIT_OUTPUT_DIR=$PODS_CONFIGURATION_BUILD_DIR/$PRODUCT_NAME

# Directory to store built tool artifacts.
export CARGOKIT_TOOL_TEMP_DIR=$TARGET_TEMP_DIR/build_tool

# Directory inside root project. Not necessarily the top level directory of root project.
export CARGOKIT_ROOT_PROJECT_DIR=$SRCROOT

FLUTTER_EXPORT_BUILD_ENVIRONMENT=(
  "$PODS_ROOT/../Flutter/ephemeral/flutter_export_environment.sh" # macOS
  "$PODS_ROOT/../Flutter/flutter_export_environment.sh" # iOS
)

for path in "${FLUTTER_EXPORT_BUILD_ENVIRONMENT[@]}"
do
  if [[ -f "$path" ]]; then
    source "$path"
  fi
done

sh "$BASEDIR/run_build_tool.sh" build-pod "$@"

# Make a symlink from built framework to phony file, which will be used as input to
# build script. This should force rebuild (podspec currently doesn't support alwaysOutOfDate
# attribute on custom build phase)
ln -fs "$OBJROOT/XCBuildData/build.db" "${BUILT_PRODUCTS_DIR}/cargokit_phony"
ln -fs "${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}" "${BUILT_PRODUCTS_DIR}/cargokit_phony_out"
