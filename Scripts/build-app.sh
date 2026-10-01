#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d .build/ub500-venv ]; then
    echo "missing .build/ub500-venv. Run ./Scripts/setup.sh first." >&2
    exit 1
fi

libusb_dir="$(find "$PWD/.build/ub500-venv/lib" -path '*/site-packages/libusb_package' -type d | head -n 1)"
if [ -z "$libusb_dir" ] || [ ! -f "$libusb_dir/libusb-1.0.dylib" ]; then
    echo "missing libusb-package. Run ./Scripts/setup.sh first." >&2
    exit 1
fi

if [ ! -f .build/ub500-firmware/rtl8761bu_fw.bin ]; then
    echo "missing rtl8761bu_fw.bin. Run ./Scripts/setup.sh first." >&2
    exit 1
fi

export TMPDIR="/private/tmp/shareMK-build-tmp"
mkdir -p "$TMPDIR"
export CLANG_MODULE_CACHE_PATH="$TMPDIR/clang-cache"
export SWIFT_MODULE_CACHE_PATH="$TMPDIR/swift-cache"

developer_dir="$(/usr/bin/xcode-select -p)"
arch="$(uname -m)"
mkdir -p .build

"$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
    -O -swift-version 6 -target "${arch}-apple-macosx13.0" \
    -sdk "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I/opt/homebrew/include \
    -L"$libusb_dir" \
    -lusb-1.0 \
    -Xlinker -rpath -Xlinker "$libusb_dir" \
    -o .build/shareMK \
    Sources/shareMK/LibUSB.swift \
    Sources/shareMK/NativeUB500Controller.swift \
    Sources/shareMK/HIDReport.swift \
    Sources/shareMK/AppSettings.swift \
    Sources/shareMK/InputCapture.swift \
    Sources/shareMK/SettingsWindowController.swift \
    Sources/shareMK/RuntimeLog.swift \
    Sources/shareMK/SwitchOSD.swift \
    Sources/shareMK/main.swift

app="dist/shareMK.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Frameworks"
mkdir -p "$app/Contents/Resources/ub500-firmware"
cp .build/shareMK "$app/Contents/MacOS/shareMK"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp .build/ub500-firmware/rtl8761bu_fw.bin "$app/Contents/Resources/ub500-firmware/rtl8761bu_fw.bin"
if [ -f .build/ub500-firmware/rtl8761bu_config.bin ]; then
    cp .build/ub500-firmware/rtl8761bu_config.bin "$app/Contents/Resources/ub500-firmware/rtl8761bu_config.bin"
fi
cp "$libusb_dir/libusb-1.0.dylib" "$app/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -change /usr/local/lib/libusb-1.0.0.dylib @executable_path/../Frameworks/libusb-1.0.0.dylib "$app/Contents/MacOS/shareMK" || true
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app"
echo "$PWD/$app"
