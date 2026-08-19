#!/bin/bash
# Build "Window Arranger.app" — the merged body (Nat 2026-07-15: "เปิดมามี
# Status Bar แล้วก็ Run Server ด้วย"): NSStatusItem tray + search hotkeys +
# embedded :8900 server (only when no external one owns the port) + the
# Oracle Display dashboard window. Installs to /Applications.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Window Arranger.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▶ swift build -c release"
(cd "$REPO/menubar" && swift build -c release --product WindowArrangerMenuBar | tail -1)

echo "▶ render 🎭 icon"
mkdir -p "$WORK/icon.iconset"
swift -e '
import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor(calibratedRed: 0.04, green: 0.055, blue: 0.08, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: size-120, height: size-120), xRadius: 180, yRadius: 180).fill()
let s = "🎭" as NSString
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 620)]
let b = s.size(withAttributes: attrs)
s.draw(at: NSPoint(x: (size-b.width)/2, y: (size-b.height)/2), withAttributes: attrs)
img.unlockFocus()
let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
' "$WORK/icon-1024.png"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$WORK/icon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$WORK/icon-1024.png" --out "$WORK/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
cp "$WORK/icon-1024.png" "$WORK/icon.iconset/icon_512x512@2x.png"
iconutil -c icns "$WORK/icon.iconset" -o "$WORK/AppIcon.icns"

echo "▶ assemble $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/menubar/.build/release/WindowArrangerMenuBar" "$APP/Contents/MacOS/"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.soulbrews.window-arranger</string>
    <key>CFBundleName</key><string>Window Arranger</string>
    <key>CFBundleDisplayName</key><string>Window Arranger</string>
    <key>CFBundleExecutable</key><string>WindowArrangerMenuBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- tray-only app: no Dock icon (the app itself calls setActivationPolicy(.accessory)) -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- census local runs on plain http://127.0.0.1:8899; API on :8900 -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "✅ $APP"
