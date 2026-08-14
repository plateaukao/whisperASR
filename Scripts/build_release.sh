#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="WhisperASR"
BUNDLE_ID="com.whisperasr.app"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "==> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

echo "==> Generating app icon..."
# Create a small Swift script to generate the .icns from AppIconGenerator
ICON_SCRIPT=$(mktemp /tmp/gen_icon.XXXXXX.swift)
cat > "$ICON_SCRIPT" << 'SWIFT'
import AppKit

// Render icon at multiple sizes for .icns
let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let iconsetPath = CommandLine.arguments[1]

func generateIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    let s = size
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.22
    let path = CGPath(roundedRect: rect.insetBy(dx: s * 0.008, dy: s * 0.008),
                      cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.08, green: 0.75, blue: 0.72, alpha: 1.0),
        CGColor(red: 0.10, green: 0.30, blue: 0.65, alpha: 1.0),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
    let barHeights: [CGFloat] = [0.12, 0.25, 0.42, 0.65, 0.85, 0.65, 0.42, 0.25, 0.12]
    let barWidth = s * 0.05
    let barSpacing = s * 0.025
    let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barSpacing
    let startX = (s - totalWidth) / 2
    let centerY = s * 0.52
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    for (i, hf) in barHeights.enumerated() {
        let barH = s * 0.55 * hf
        let x = startX + CGFloat(i) * (barWidth + barSpacing)
        let y = centerY - barH / 2
        let barRect = CGRect(x: x, y: y, width: barWidth, height: barH)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.addPath(barPath)
        ctx.fillPath()
    }
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.08, weight: .bold),
        .foregroundColor: NSColor(white: 1, alpha: 0.7)
    ]
    let text = NSAttributedString(string: "ASR", attributes: attrs)
    let textSize = text.size()
    text.draw(at: NSPoint(x: (s - textSize.width) / 2, y: s * 0.12))
    image.unlockFocus()
    return image
}

let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let img = generateIcon(size: size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    let filePath = "\(iconsetPath)/\(name).png"
    try! data.write(to: URL(fileURLWithPath: filePath))
}
print("Iconset created at \(iconsetPath)")
SWIFT

ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
swift "$ICON_SCRIPT" "$ICONSET_DIR"
ICNS_PATH="$PROJECT_DIR/.build/AppIcon.icns"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
rm -rf "$(dirname "$ICONSET_DIR")"
rm "$ICON_SCRIPT"
echo "==> Icon generated at $ICNS_PATH"

echo "==> Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy icon
cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>WhisperASR</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.10.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisperASR needs microphone access to record audio for transcription.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>WhisperASR needs to control other applications for screen recording.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>whisperasr</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    # Create entitlements for hardened runtime
    ENTITLEMENTS=$(mktemp /tmp/entitlements.XXXXXX.plist)
    cat > "$ENTITLEMENTS" << 'ENTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENTPLIST

    echo "==> Signing app bundle..."
    codesign --deep --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE"
    rm -f "$ENTITLEMENTS"
    echo "==> Verifying signature..."
    codesign --verify --deep --strict "$APP_BUNDLE"
    spctl --assess --type execute "$APP_BUNDLE" && echo "    Gatekeeper: OK" || echo "    Gatekeeper: not yet notarized (run notarytool to fix)"
else
    echo "==> Skipping code signing (set CODESIGN_IDENTITY to sign)"
fi

echo "==> Done! App bundle created at:"
echo "    $APP_BUNDLE"
echo ""
echo "    To run:  open $APP_BUNDLE"
echo "    To move: cp -r $APP_BUNDLE /Applications/"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo ""
    echo "    Signed with: $CODESIGN_IDENTITY"
fi
