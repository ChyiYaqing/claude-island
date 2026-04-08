#!/bin/bash
# Build Claude Island for release
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ClaudeIsland.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

echo "=== Building Claude Island ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Build and archive
echo "Archiving..."
XCODEBUILD_ARGS=(
    archive
    -scheme ClaudeIsland
    -configuration Release
    -archivePath "$ARCHIVE_PATH"
    -destination "generic/platform=macOS"
    ENABLE_HARDENED_RUNTIME=YES
    CODE_SIGN_STYLE=Automatic
)
if command -v xcpretty &>/dev/null; then
    xcodebuild "${XCODEBUILD_ARGS[@]}" | xcpretty
else
    xcodebuild "${XCODEBUILD_ARGS[@]}"
fi

# Create ExportOptions.plist if it doesn't exist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>debugging</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

# Export the archive
echo ""
echo "Exporting..."
EXPORT_ARGS=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_PATH"
    -exportOptionsPlist "$EXPORT_OPTIONS"
)
if command -v xcpretty &>/dev/null; then
    xcodebuild "${EXPORT_ARGS[@]}" | xcpretty
else
    xcodebuild "${EXPORT_ARGS[@]}"
fi

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/Claude Island.app"
echo ""
echo "Next: Run ./scripts/create-release.sh to notarize and create DMG"
