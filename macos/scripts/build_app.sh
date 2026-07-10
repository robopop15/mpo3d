#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MPO3D"
EXECUTABLE_NAME="MPO3DMac"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DEPLOYMENT_TARGET="13.0"
X86_TRIPLE="x86_64-apple-macosx$MACOS_DEPLOYMENT_TARGET"
ARM_TRIPLE="arm64-apple-macosx$MACOS_DEPLOYMENT_TARGET"
X86_BUILD_DIR="$BUILD_DIR/.build-x86_64"
ARM_BUILD_DIR="$BUILD_DIR/.build-arm64"
ICON_SOURCE="$ROOT_DIR/../mpo3dico.png"
ICON_RENDERED_SOURCE="$BUILD_DIR/AppIconSource.png"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_OUTPUT="$APP_DIR/Contents/Resources/AppIcon.icns"

build_for_triple() {
    local triple="$1"
    local scratch_dir="$2"

    rm -rf "$scratch_dir"
    echo "Building $triple..."
    swift build \
        --package-path "$ROOT_DIR" \
        -c release \
        --scratch-path "$scratch_dir" \
        --triple "$triple"
}

SUCCESSFUL_BINARIES=()

if build_for_triple "$X86_TRIPLE" "$X86_BUILD_DIR"; then
    SUCCESSFUL_BINARIES+=("$X86_BUILD_DIR/release/$EXECUTABLE_NAME")
fi

if build_for_triple "$ARM_TRIPLE" "$ARM_BUILD_DIR"; then
    SUCCESSFUL_BINARIES+=("$ARM_BUILD_DIR/release/$EXECUTABLE_NAME")
fi

if [[ ${#SUCCESSFUL_BINARIES[@]} -eq 0 ]]; then
    echo "Nenhum binario foi gerado." >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

if [[ ${#SUCCESSFUL_BINARIES[@]} -gt 1 ]]; then
    lipo -create "${SUCCESSFUL_BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
else
    cp "${SUCCESSFUL_BINARIES[1]}" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
    echo "Aviso: app gerado com uma arquitetura so." >&2
fi

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
            "$BUILD_DIR/AppIconArt.png"

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
            "$BUILD_DIR/AppIconBase.png"

        magick "$BUILD_DIR/AppIconBase.png" "$BUILD_DIR/AppIconArt.png" \
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

    iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUTPUT"
fi

chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo
echo "App gerado em:"
echo "  $APP_DIR"
echo
echo "Voce pode arrastar esse .app para a pasta Aplicativos."
