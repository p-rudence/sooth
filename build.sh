#!/bin/zsh
# Builds Sooth.app and installs it to /Applications.
set -e
cd "${0:A:h}"
APP=build/Sooth.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Native (Apple silicon) by default; --universal adds Intel for release builds.
if [[ " $* " == *" --universal "* ]]; then
  swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o build/Sooth-arm64 Sources/*.swift -framework AppKit -framework Accelerate -framework Vision
  swiftc -O -swift-version 5 -target x86_64-apple-macos14.0 -o build/Sooth-x86_64 Sources/*.swift -framework AppKit -framework Accelerate -framework Vision
  lipo -create build/Sooth-arm64 build/Sooth-x86_64 -output "$APP/Contents/MacOS/Sooth"
  rm build/Sooth-arm64 build/Sooth-x86_64
else
  swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/Sooth" Sources/*.swift \
    -framework AppKit -framework Accelerate -framework Vision
fi

if [ ! -f Resources/AppIcon.icns ]; then
  swift tools/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/"
[ -d Resources/Looks ] && cp -R Resources/Looks "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sooth</string>
  <key>CFBundleDisplayName</key><string>Sooth</string>
  <key>CFBundleIdentifier</key><string>org.tianmu.sooth</string>
  <key>CFBundleExecutable</key><string>Sooth</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Tianmu Labs. Free and open source (MIT).</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.png</string><string>public.jpeg</string><string>public.heic</string><string>public.heif</string>
        <string>public.tiff</string><string>com.microsoft.bmp</string><string>com.compuserve.gif</string><string>org.webmproject.webp</string>
        <string>com.adobe.photoshop-image</string><string>public.camera-raw-image</string><string>com.apple.icns</string>
        <string>com.truevision.tga-image</string><string>public.jpeg-2000</string><string>com.adobe.pdf</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Sooth Image</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>org.tianmu.sooth.image</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Paint.NET Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>pdn</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>org.tianmu.sooth.image</string>
      <key>UTTypeDescription</key><string>Sooth Image</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>sooth</string><string>easel</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
if [[ " $* " != *" --no-install "* ]]; then
  rm -rf /Applications/Sooth.app
  cp -R "$APP" /Applications/Sooth.app
  echo "Installed /Applications/Sooth.app"
fi
