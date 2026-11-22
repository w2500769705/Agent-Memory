#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

configuration=${CONFIGURATION:-release}
swift build -c "$configuration" -j "${SWIFT_BUILD_JOBS:-6}"
bin=$(swift build -c "$configuration" --show-bin-path)
app="dist/Agent Memory.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin/AgentMemory" "$app/Contents/MacOS/AgentMemory"
install -m 755 "$bin/agent-memory-mcp" "$app/Contents/MacOS/agent-memory-mcp"
install -m 755 scripts/review-codex-hooks.command "$app/Contents/Resources/review-codex-hooks.command"
if [ -f Resources/AppIcon.icns ]; then
    install -m 644 Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>AgentMemory</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.agentmemory.app</string>
    <key>CFBundleName</key><string>Agent Memory</string>
    <key>CFBundleDisplayName</key><string>Agent Memory</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/agent-memory-mcp"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$PWD/$app"
