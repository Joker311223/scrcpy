#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPS_DIR="$ROOT_DIR/app/deps"
INSTALL_DIR="$DEPS_DIR/work/install/macos-native-shared"
MARKER="$INSTALL_DIR/.scrcpy-desk-portable"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
EXPECTED_MARKER="format=2;deployment-target=$DEPLOYMENT_TARGET;ffmpeg=8.1.2;sdl=3.4.12"

required_tools=(cmake meson ninja nasm pkg-config)
missing_formulae=()

for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        case "$tool" in
            pkg-config) missing_formulae+=(pkgconf) ;;
            *) missing_formulae+=("$tool") ;;
        esac
    fi
done

if (( ${#missing_formulae[@]} > 0 )); then
    if ! command -v brew >/dev/null 2>&1; then
        echo "Missing build tools: ${missing_formulae[*]}" >&2
        echo "Install Homebrew from https://brew.sh, then rerun this script." >&2
        exit 1
    fi

    echo "Installing missing build tools: ${missing_formulae[*]}"
    brew install "${missing_formulae[@]}"
fi

if [[ -f "$MARKER" ]] && [[ "$(cat "$MARKER")" == "$EXPECTED_MARKER" ]]; then
    required_libraries=(
        "$INSTALL_DIR/lib/libavformat.dylib"
        "$INSTALL_DIR/lib/libavcodec.dylib"
        "$INSTALL_DIR/lib/libavutil.dylib"
        "$INSTALL_DIR/lib/libswresample.dylib"
        "$INSTALL_DIR/lib/libSDL3.dylib"
    )
    all_present=true
    for library in "${required_libraries[@]}"; do
        if [[ ! -e "$library" ]]; then
            all_present=false
            break
        fi
    done
    if [[ "$all_present" == true ]]; then
        echo "Portable dependencies are ready: $INSTALL_DIR"
        printf '%s\n' "$INSTALL_DIR"
        exit 0
    fi
fi

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
if [[ -z "${SDKROOT:-}" ]] && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CFLAGS="-O2 -mmacosx-version-min=$DEPLOYMENT_TARGET"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET"

# Cached build directories encode compiler and deployment-target settings.
# Reconfigure them whenever the portable dependency marker is absent or stale.
rm -rf \
    "$DEPS_DIR/work/build/sdl-3.4.12/macos-native-shared" \
    "$DEPS_DIR/work/build/dav1d-1.5.3/macos-native-shared" \
    "$DEPS_DIR/work/build/ffmpeg-8.1.2/macos-native-shared" \
    "$INSTALL_DIR"

"$DEPS_DIR/sdl.sh" macos native shared
"$DEPS_DIR/dav1d.sh" macos native shared
"$DEPS_DIR/ffmpeg.sh" macos native shared

mkdir -p "$INSTALL_DIR"
printf '%s' "$EXPECTED_MARKER" > "$MARKER"

echo "Portable dependencies are ready: $INSTALL_DIR"
printf '%s\n' "$INSTALL_DIR"
