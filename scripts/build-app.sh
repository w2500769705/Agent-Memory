#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

version=$(LC_ALL=C awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if (length) print }' VERSION)
if [ -z "$version" ]; then
    printf '%s\n' 'VERSION 不能为空。' >&2
    exit 1
fi
build=1
git_sha=unknown
if [ -e .git ] && head_sha=$(git rev-parse --short HEAD 2>/dev/null); then
    build=$(git rev-list --count HEAD)
    git_changes=$(git status --porcelain --untracked-files=normal)
    git_sha=$head_sha
    if [ -n "$git_changes" ]; then
        git_sha="$git_sha-dirty"
    fi
fi

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
plist="$app/Contents/Info.plist"
cat > "$plist" <<'PLIST'
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
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -insert CFBundleShortVersionString -string "$version" "$plist"
plutil -insert CFBundleVersion -string "$build" "$plist"
plutil -insert AgentMemoryGitSHA -string "$git_sha" "$plist"
codesign --force --sign - "$app/Contents/MacOS/agent-memory-mcp"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built Agent Memory v%s (build %s · %s)\n' "$version" "$build" "$git_sha"
printf '%s\n' "$PWD/$app"
