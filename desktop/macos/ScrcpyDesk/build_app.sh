#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR/dist}"
APP_DIR="$OUTPUT_DIR/Scrcpy Desk.app"
SERVER_APK="$ROOT_DIR/server/build/outputs/apk/release/server-release-unsigned.apk"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
DEPS_PREFIX="$ROOT_DIR/app/deps/work/install/macos-native-shared"
"$SCRIPT_DIR/prepare_portable_dependencies.sh"
export SCRCPY_DESK_DEPS_PREFIX="$DEPS_PREFIX"

if [[ ! -f "$SERVER_APK" ]]; then
    export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    if [[ -z "${JAVA_HOME:-}" ]] || ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -Eq 'version "(17|18|19|2[0-9])'; then
        export JAVA_HOME="$(/usr/libexec/java_home -v 17+)"
    fi
    "$ROOT_DIR/gradlew" -p "$ROOT_DIR/server" assembleRelease
fi

if [[ -z "${SDKROOT:-}" ]] && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/scrcpy-desk-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${TMPDIR:-/tmp}/scrcpy-desk-swiftpm-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

SWIFT_ARGS=(-c release --disable-sandbox --package-path "$ROOT_DIR")
if [[ -n "${SDKROOT:-}" ]]; then
    SWIFT_ARGS+=(--sdk "$SDKROOT")
fi

swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

# Always assemble a clean bundle so stale resources from a previous version
# (especially cached icon filenames) cannot remain in Contents/Resources.
rm -rf "$APP_DIR"
mkdir -p \
    "$APP_DIR/Contents/MacOS" \
    "$APP_DIR/Contents/Resources" \
    "$APP_DIR/Contents/Frameworks"
cp "$BIN_DIR/ScrcpyDesk" "$APP_DIR/Contents/MacOS/ScrcpyDesk"
cp "$SCRIPT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$SCRIPT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/ScrcpyDeskAppIcon.icns"
cp "$SCRIPT_DIR/Assets/AppIcon.png" "$APP_DIR/Contents/Resources/ScrcpyDeskAppIcon.png"
cp "$SERVER_APK" "$APP_DIR/Contents/Resources/scrcpy-server"
cp "$ROOT_DIR/app/data/scrcpy.png" "$APP_DIR/Contents/Resources/scrcpy.png"
cp "$ROOT_DIR/app/data/disconnected.png" "$APP_DIR/Contents/Resources/disconnected.png"

ADB_BIN="$(command -v adb || true)"
if [[ -z "$ADB_BIN" ]] && [[ -x "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb" ]]; then
    ADB_BIN="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
fi
if [[ -z "$ADB_BIN" ]]; then
    echo "ADB not found locally; downloading the pinned Android Platform Tools."
    "$ROOT_DIR/app/deps/adb_macos.sh"
    ADB_BIN="$ROOT_DIR/app/deps/work/install/adb-macos/adb"
fi
cp "$ADB_BIN" "$APP_DIR/Contents/Resources/adb"

EXECUTABLE="$APP_DIR/Contents/MacOS/ScrcpyDesk"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
BUNDLED_NAMES=()
BUNDLED_SOURCES=()

macho_dependencies() {
    otool -L "$1" | sed '1d' | awk '{print $1}'
}

is_system_dependency() {
    case "$1" in
        /System/Library/*|/usr/lib/*) return 0 ;;
        *) return 1 ;;
    esac
}

canonical_path() {
    local path="$1"
    local directory
    directory="$(cd "$(dirname "$path")" && pwd -P)"
    printf '%s/%s\n' "$directory" "$(basename "$path")"
}

resolve_dependency() {
    local dependency="$1"
    local owner="$2"
    local suffix
    local candidate

    if [[ "$dependency" == /* ]] && [[ -e "$dependency" ]]; then
        canonical_path "$dependency"
        return
    fi

    case "$dependency" in
        @loader_path/*)
            suffix="${dependency#@loader_path/}"
            candidate="$(dirname "$owner")/$suffix"
            ;;
        @executable_path/*)
            suffix="${dependency#@executable_path/}"
            candidate="$(dirname "$EXECUTABLE")/$suffix"
            ;;
        @rpath/*)
            suffix="${dependency#@rpath/}"
            for candidate in \
                "$(dirname "$owner")/$suffix" \
                "$DEPS_PREFIX/lib/$suffix"; do
                if [[ -e "$candidate" ]]; then
                    canonical_path "$candidate"
                    return
                fi
            done
            candidate=""
            ;;
        *)
            candidate=""
            ;;
    esac

    if [[ -n "$candidate" ]] && [[ -e "$candidate" ]]; then
        canonical_path "$candidate"
        return
    fi

    echo "Unable to resolve dependency '$dependency' required by '$owner'" >&2
    return 1
}

bundle_dependency() {
    local source="$1"
    local resolved
    local name
    local destination
    local index
    local dependency
    local child_source

    resolved="$(canonical_path "$source")"
    name="$(basename "$resolved")"

    for ((index = 0; index < ${#BUNDLED_NAMES[@]}; index++)); do
        if [[ "${BUNDLED_NAMES[$index]}" == "$name" ]]; then
            if [[ "${BUNDLED_SOURCES[$index]}" != "$resolved" ]]; then
                echo "Conflicting libraries named '$name':" >&2
                echo "  ${BUNDLED_SOURCES[$index]}" >&2
                echo "  $resolved" >&2
                return 1
            fi
            return
        fi
    done

    destination="$FRAMEWORKS_DIR/$name"
    cp -L "$resolved" "$destination"
    chmod u+w "$destination"
    BUNDLED_NAMES+=("$name")
    BUNDLED_SOURCES+=("$resolved")

    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        if is_system_dependency "$dependency"; then
            continue
        fi

        child_source="$(resolve_dependency "$dependency" "$resolved")"
        bundle_dependency "$child_source"
        install_name_tool \
            -change "$dependency" "@loader_path/$(basename "$child_source")" \
            "$destination"
    done < <(macho_dependencies "$resolved")

    install_name_tool -id "@rpath/$name" "$destination"
}

while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue
    if is_system_dependency "$dependency"; then
        continue
    fi

    source="$(resolve_dependency "$dependency" "$BIN_DIR/ScrcpyDesk")"
    bundle_dependency "$source"
    install_name_tool \
        -change "$dependency" "@executable_path/../Frameworks/$(basename "$source")" \
        "$EXECUTABLE"
done < <(macho_dependencies "$BIN_DIR/ScrcpyDesk")

version_is_greater() {
    awk -v left="$1" -v right="$2" '
        BEGIN {
            split(left, a, ".")
            split(right, b, ".")
            for (i = 1; i <= 3; i++) {
                av = (a[i] == "" ? 0 : a[i]) + 0
                bv = (b[i] == "" ? 0 : b[i]) + 0
                if (av > bv) exit 0
                if (av < bv) exit 1
            }
            exit 1
        }
    '
}

validate_macho() {
    local file="$1"
    local dependency
    local minos
    local architectures

    architectures="$(lipo -archs "$file")"
    if [[ " $architectures " != *" arm64 "* ]]; then
        echo "Missing arm64 architecture: $file ($architectures)" >&2
        return 1
    fi

    minos="$(xcrun vtool -show-build "$file" 2>/dev/null | awk '/minos / {print $2; exit}')"
    if [[ -n "$minos" ]] && version_is_greater "$minos" "$DEPLOYMENT_TARGET"; then
        echo "$file requires macOS $minos, newer than target $DEPLOYMENT_TARGET" >&2
        return 1
    fi

    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@loader_path/*|@executable_path/../Frameworks/*)
                ;;
            @rpath/*)
                if [[ "$dependency" != "@rpath/$(basename "$file")" ]]; then
                    echo "Unexpected rpath dependency '$dependency' remains in '$file'" >&2
                    return 1
                fi
                ;;
            *)
                echo "Non-portable dependency '$dependency' remains in '$file'" >&2
                return 1
                ;;
        esac
    done < <(macho_dependencies "$file")
}

validate_macho "$EXECUTABLE"
for library in "$FRAMEWORKS_DIR"/*.dylib; do
    validate_macho "$library"
    codesign --force --sign - "$library"
done

codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
