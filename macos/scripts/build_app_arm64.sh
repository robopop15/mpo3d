#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MPO3D-AppleSilicon"
EXECUTABLE_NAME="MPO3DMac"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DEPLOYMENT_TARGET="13.0"
ARM_TRIPLE="arm64-apple-macosx$MACOS_DEPLOYMENT_TARGET"
ARM_BUILD_DIR="$BUILD_DIR/.build-arm64-only"
SWIFT_HOME_DIR="$BUILD_DIR/.swift-home-arm64"
CLANG_MODULE_CACHE_DIR="$BUILD_DIR/.clang-module-cache-arm64"
SWIFTPM_MODULE_CACHE_DIR="$BUILD_DIR/.swiftpm-module-cache-arm64"
ICON_SOURCE="$ROOT_DIR/../mpo3dico.png"
ICON_RENDERED_SOURCE="$BUILD_DIR/AppIconSource-arm64.png"
ICONSET_DIR="$BUILD_DIR/AppIcon-arm64.iconset"
ICON_OUTPUT="$APP_DIR/Contents/Resources/AppIcon.icns"
FALLBACK_ICON="$ROOT_DIR/build/MPO3D.app/Contents/Resources/AppIcon.icns"

rm -rf "$ARM_BUILD_DIR"
mkdir -p "$SWIFT_HOME_DIR" "$CLANG_MODULE_CACHE_DIR" "$SWIFTPM_MODULE_CACHE_DIR"
echo "Building $ARM_TRIPLE..."
HOME="$SWIFT_HOME_DIR" \
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_DIR" \
SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_MODULE_CACHE_DIR" \
swift build \
    --package-path "$ROOT_DIR" \
    -c release \
    --disable-sandbox \
    --scratch-path "$ARM_BUILD_DIR" \
    --triple "$ARM_TRIPLE"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ARM_BUILD_DIR/release/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -f "$ICON_SOURCE" ]]; then
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    ICON_INPUT="$ICON_SOURCE"
    if command -v magick >/dev/null 2>&1; then
        magick "$ICON_SOURCE" \
            -alpha on \
            -fuzz 8% \
            -transparent '#f2f2f2' \
            -trim \
            +repage \
            -resize 640x640 \
            "$BUILD_DIR/AppIconArt-arm64.png"

        magick \
            -size 860x860 gradient:'#f8f5ee-#e9e1d6' \
            -rotate 90 \
            \( -size 860x860 xc:none -fill white -draw "roundrectangle 0,0 859,859 180,180" \) \
            -compose CopyOpacity \
            -composite \
            \( -size 1024x1024 xc:none \) \
            +swap \
            -gravity center \
            -compose over \
            -composite \
            "$BUILD_DIR/AppIconBase-arm64.png"

        magick "$BUILD_DIR/AppIconBase-arm64.png" "$BUILD_DIR/AppIconArt-arm64.png" \
            -gravity center \
            -compose over \
            -composite \
            "$ICON_RENDERED_SOURCE"

        ICON_INPUT="$ICON_RENDERED_SOURCE"
    fi

    sips -z 16 16 "$ICON_INPUT" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_INPUT" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_INPUT" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_INPUT" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_INPUT" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_INPUT" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_INPUT" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_INPUT" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_INPUT" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    cp "$ICON_INPUT" "$ICONSET_DIR/icon_512x512@2x.png"

    if ! iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUTPUT"; then
        if [[ -f "$FALLBACK_ICON" ]]; then
            cp "$FALLBACK_ICON" "$ICON_OUTPUT"
        else
            echo "Warning: could not generate AppIcon.icns for the arm64 app." >&2
        fi
    fi
elif [[ -f "$FALLBACK_ICON" ]]; then
    cp "$FALLBACK_ICON" "$ICON_OUTPUT"
fi

chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo
echo "Apple Silicon app generated at:"
echo "  $APP_DIR"
echo
echo "This build is arm64-only and targets macOS $MACOS_DEPLOYMENT_TARGET+."
