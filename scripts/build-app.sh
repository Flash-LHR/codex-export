#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$PROJECT_DIR/VERSION"
DIST_DIR="$PROJECT_DIR/dist"
FINAL_APP="$DIST_DIR/Codex Export.app"
ASSET_CATALOG="$PROJECT_DIR/Resources/Assets.xcassets"
APP_ICON="$PROJECT_DIR/Resources/AppIcon.icns"
APP_ICON_MASTER="$PROJECT_DIR/Resources/AppIcon.png"
STATUS_ICON="$ASSET_CATALOG/StatusIcon.imageset/StatusIcon.png"
STATUS_ICON_2X="$ASSET_CATALOG/StatusIcon.imageset/StatusIcon@2x.png"
. "$SCRIPT_DIR/version.sh"
if [[ ! -d "$ASSET_CATALOG" ]]; then
    echo "Missing status-icon asset catalog: $ASSET_CATALOG" >&2
    exit 1
fi
if [[ ! -f "$APP_ICON" ]]; then
    echo "Missing application icon: $APP_ICON" >&2
    exit 1
fi
for icon in "$APP_ICON_MASTER" "$STATUS_ICON" "$STATUS_ICON_2X"; do
    if [[ ! -f "$icon" ]]; then
        echo "Missing icon source: $icon" >&2
        exit 1
    fi
done

load_project_version "$VERSION_FILE"
mkdir -p "$DIST_DIR"

STAGING_ROOT="$(mktemp -d "$DIST_DIR/.codex-export-build.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Codex Export.app"
CONTENTS_DIR="$STAGED_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PREVIOUS_APP="$STAGING_ROOT/Previous Codex Export.app"
HAD_ORIGINAL=0
INSTALLING=0
COMMITTED=0

cleanup() {
    local status=$?
    local restore_failed=0
    if [[ "$COMMITTED" -eq 0 && -e "$PREVIOUS_APP" ]]; then
        rm -rf "$FINAL_APP"
        if ! mv "$PREVIOUS_APP" "$FINAL_APP"; then
            echo "Could not restore the previous app; backup kept at $PREVIOUS_APP" >&2
            restore_failed=1
        fi
    elif [[ "$COMMITTED" -eq 0 && "$HAD_ORIGINAL" -eq 0 \
            && "$INSTALLING" -eq 1 ]]; then
        rm -rf "$FINAL_APP"
    fi
    if [[ "$restore_failed" -eq 0 ]]; then
        rm -rf "$STAGING_ROOT"
    else
        [[ "$status" -ne 0 ]] || status=1
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! /usr/bin/sips -g pixelWidth -g pixelHeight "$APP_ICON_MASTER" \
        | grep -q 'pixelWidth: 1024' \
        || ! /usr/bin/sips -g pixelWidth -g pixelHeight "$APP_ICON_MASTER" \
        | grep -q 'pixelHeight: 1024'; then
    echo "Application icon master must be 1024x1024" >&2
    exit 1
fi
for icon_spec in "$STATUS_ICON:18" "$STATUS_ICON_2X:36"; do
    icon="${icon_spec%:*}"
    expected="${icon_spec##*:}"
    metadata="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$icon")"
    if ! grep -q "pixelWidth: $expected" <<<"$metadata" \
            || ! grep -q "pixelHeight: $expected" <<<"$metadata"; then
        echo "Status icon must be ${expected}x${expected}: $icon" >&2
        exit 1
    fi
done

ICONSET_CHECK="$STAGING_ROOT/AppIcon.iconset"
iconutil -c iconset "$APP_ICON" -o "$ICONSET_CHECK"
for representation in \
        icon_16x16.png icon_16x16@2x.png \
        icon_32x32.png icon_32x32@2x.png \
        icon_128x128.png icon_128x128@2x.png \
        icon_256x256.png icon_256x256@2x.png \
        icon_512x512.png icon_512x512@2x.png; do
    if [[ ! -s "$ICONSET_CHECK/$representation" ]]; then
        echo "Application icon is missing representation: $representation" >&2
        exit 1
    fi
done

swift build --package-path "$PROJECT_DIR" -c release --arch arm64
BIN_DIR="$(
    swift build --package-path "$PROJECT_DIR" -c release \
        --arch arm64 \
        --show-bin-path
)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/CodexExportApp" "$MACOS_DIR/CodexExportApp"
/usr/bin/strip -S -x "$MACOS_DIR/CodexExportApp"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/bin/ditto "$PROJECT_DIR/Resources/WebRenderer" "$RESOURCES_DIR/WebRenderer"
cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"

UPDATE_REPOSITORY="${CODEX_EXPORT_UPDATE_REPOSITORY:-}"
UPDATE_PUBLIC_KEY="${CODEX_EXPORT_UPDATE_PUBLIC_KEY:-}"
if [[ -n "$UPDATE_REPOSITORY" || -n "$UPDATE_PUBLIC_KEY" ]]; then
    if [[ -z "$UPDATE_REPOSITORY" || -z "$UPDATE_PUBLIC_KEY" ]]; then
        echo "Both CODEX_EXPORT_UPDATE_REPOSITORY and CODEX_EXPORT_UPDATE_PUBLIC_KEY are required" >&2
        exit 1
    fi
fi

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CodexExportUpdateRepository $UPDATE_REPOSITORY" \
    -c "Set :CodexExportUpdatePublicKey $UPDATE_PUBLIC_KEY" \
    "$CONTENTS_DIR/Info.plist"

xcrun actool "$ASSET_CATALOG" \
    --compile "$RESOURCES_DIR" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --target-device mac \
    --output-format human-readable-text \
    --warnings \
    --notices

chmod 755 "$MACOS_DIR/CodexExportApp"
codesign --force --deep --sign - "$STAGED_APP"

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
codesign --verify --deep --strict "$STAGED_APP"

if [[ ! -s "$RESOURCES_DIR/Assets.car" ]]; then
    echo "Asset catalog was not compiled into the app" >&2
    exit 1
fi
for required_asset in StatusIcon GitHubMark; do
    if ! xcrun assetutil --info "$RESOURCES_DIR/Assets.car" \
        | grep -q "\"Name\" : \"$required_asset\""; then
        echo "Compiled assets do not contain $required_asset" >&2
        exit 1
    fi
done
if LC_ALL=C /usr/bin/strings - "$MACOS_DIR/CodexExportApp" \
    | grep -Eq '/Users/|/\.build/|/var/folders/|/private/tmp/'; then
    echo "Release binary contains a local absolute build path" >&2
    exit 1
fi

"$MACOS_DIR/CodexExportApp" --renderer-smoke
"$MACOS_DIR/CodexExportApp" --termination-smoke

case "$FINAL_APP" in
    "$PROJECT_DIR"/dist/*.app) ;;
    *)
        echo "Refusing to replace unexpected app path: $FINAL_APP" >&2
        exit 1
        ;;
esac

if [[ -e "$FINAL_APP" ]]; then
    HAD_ORIGINAL=1
    mv "$FINAL_APP" "$PREVIOUS_APP"
fi
INSTALLING=1
mv "$STAGED_APP" "$FINAL_APP"
COMMITTED=1
INSTALLING=0
rm -rf "$PREVIOUS_APP"

echo "Built Codex Export $MARKETING_VERSION ($BUILD_NUMBER) at $FINAL_APP"
