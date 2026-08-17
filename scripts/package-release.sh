#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_ROOT="${OUTPUT_ROOT:-$PROJECT_DIR/outputs}"
. "$SCRIPT_DIR/version.sh"
load_project_version "$PROJECT_DIR/VERSION"

RELEASE_NAME="Codex Export $MARKETING_VERSION"
SOURCE_NAME="$RELEASE_NAME Source"
UPDATE_SIGNING_ENABLED=0

if [[ -n "${CODEX_EXPORT_UPDATE_REPOSITORY:-}" \
        || -n "${CODEX_EXPORT_UPDATE_PUBLIC_KEY:-}" \
        || -n "${CODEX_EXPORT_UPDATE_PRIVATE_KEY:-}" ]]; then
    if [[ -z "${CODEX_EXPORT_UPDATE_REPOSITORY:-}" \
            || -z "${CODEX_EXPORT_UPDATE_PUBLIC_KEY:-}" \
            || -z "${CODEX_EXPORT_UPDATE_PRIVATE_KEY:-}" ]]; then
        echo "Repository, public key, and private signing key are all required for update assets" >&2
        exit 1
    fi
    UPDATE_SIGNING_ENABLED=1
fi

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd -P)"

case "$OUTPUT_ROOT" in
    ''|/|"$PROJECT_DIR")
        echo "Refusing unsafe output root: $OUTPUT_ROOT" >&2
        exit 1
        ;;
esac
case "$PROJECT_DIR/" in
    "$OUTPUT_ROOT/"*)
        echo "Refusing an output root that contains the project: $OUTPUT_ROOT" >&2
        exit 1
        ;;
esac
case "$OUTPUT_ROOT" in
    "$PROJECT_DIR/.github"|"$PROJECT_DIR/.github/"* \
        |"$PROJECT_DIR/Resources"|"$PROJECT_DIR/Resources/"* \
        |"$PROJECT_DIR/Sources"|"$PROJECT_DIR/Sources/"* \
        |"$PROJECT_DIR/Tests"|"$PROJECT_DIR/Tests/"* \
        |"$PROJECT_DIR/scripts"|"$PROJECT_DIR/scripts/"* \
        |"$PROJECT_DIR/dist"|"$PROJECT_DIR/dist/"*)
        echo "Refusing an output root inside a packaged source tree: $OUTPUT_ROOT" >&2
        exit 1
        ;;
esac

RELEASE_DIR="$OUTPUT_ROOT/$RELEASE_NAME"
SOURCE_DIR="$OUTPUT_ROOT/$SOURCE_NAME"
RELEASE_ZIP="$OUTPUT_ROOT/$RELEASE_NAME.zip"
SOURCE_ZIP="$OUTPUT_ROOT/$SOURCE_NAME.zip"
UPDATE_MANIFEST="$OUTPUT_ROOT/Codex-Export-update.json"
UPDATE_SIGNATURE="$OUTPUT_ROOT/Codex-Export-update.sig"

STAGING_ROOT="$(mktemp -d "$OUTPUT_ROOT/.codex-export-package.XXXXXX")"
STAGED_RELEASE="$STAGING_ROOT/$RELEASE_NAME"
STAGED_SOURCE="$STAGING_ROOT/$SOURCE_NAME"
STAGED_RELEASE_ZIP="$STAGING_ROOT/$RELEASE_NAME.zip"
STAGED_SOURCE_ZIP="$STAGING_ROOT/$SOURCE_NAME.zip"
STAGED_UPDATE_MANIFEST="$STAGING_ROOT/Codex-Export-update.json"
STAGED_UPDATE_SIGNATURE="$STAGING_ROOT/Codex-Export-update.sig"
BACKUP_ROOT="$STAGING_ROOT/previous"
DIST_APP="$PROJECT_DIR/dist/Codex Export.app"
DIST_BACKUP="$STAGING_ROOT/previous-dist-app"
DIST_HAD_ORIGINAL=0
DIST_REBUILD_STARTED=0
targets=("$RELEASE_DIR" "$SOURCE_DIR" "$RELEASE_ZIP" "$SOURCE_ZIP")
staged=(
    "$STAGED_RELEASE"
    "$STAGED_SOURCE"
    "$STAGED_RELEASE_ZIP"
    "$STAGED_SOURCE_ZIP"
)
if [[ "$UPDATE_SIGNING_ENABLED" -eq 1 ]]; then
    targets+=("$UPDATE_MANIFEST" "$UPDATE_SIGNATURE")
    staged+=("$STAGED_UPDATE_MANIFEST" "$STAGED_UPDATE_SIGNATURE")
fi
COMMITTED=0
INSTALLING_INDEX=-1
had_original=()
installed=()
for index in "${!targets[@]}"; do
    had_original[$index]=0
    installed[$index]=0
done

cleanup() {
    local status=$?
    local restore_failed=0
    if [[ "$COMMITTED" -eq 0 ]]; then
        for index in "${!targets[@]}"; do
            if [[ -e "$BACKUP_ROOT/$index" || -L "$BACKUP_ROOT/$index" ]]; then
                rm -rf "${targets[$index]}"
                if ! mv "$BACKUP_ROOT/$index" "${targets[$index]}"; then
                    echo "Could not restore output backup: $BACKUP_ROOT/$index" >&2
                    restore_failed=1
                fi
            elif [[ "${had_original[$index]}" -eq 0 ]] \
                    && { [[ "${installed[$index]}" -eq 1 ]] \
                        || [[ "$INSTALLING_INDEX" -eq "$index" ]]; }; then
                rm -rf "${targets[$index]}"
            fi
        done
        if [[ "$DIST_REBUILD_STARTED" -eq 1 ]]; then
            rm -rf "$DIST_APP"
            if [[ "$DIST_HAD_ORIGINAL" -eq 1 ]]; then
                if ! /usr/bin/ditto "$DIST_BACKUP" "$DIST_APP"; then
                    echo "Could not restore the previous dist app: $DIST_BACKUP" >&2
                    restore_failed=1
                fi
            fi
        fi
    fi
    if [[ "$restore_failed" -eq 0 ]]; then
        rm -rf "$STAGING_ROOT"
    else
        echo "Packaging staging was preserved for manual recovery: $STAGING_ROOT" >&2
        [[ "$status" -ne 0 ]] || status=1
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGED_RELEASE" "$STAGED_SOURCE" "$BACKUP_ROOT"
if [[ -L "$DIST_APP" ]]; then
    echo "Refusing symbolic-link dist app: $DIST_APP" >&2
    exit 1
fi
if [[ -e "$DIST_APP" ]]; then
    /usr/bin/ditto "$DIST_APP" "$DIST_BACKUP"
    DIST_HAD_ORIGINAL=1
fi
DIST_REBUILD_STARTED=1
env -u CODEX_EXPORT_UPDATE_PRIVATE_KEY "$SCRIPT_DIR/build-app.sh"
/usr/bin/ditto "$PROJECT_DIR/dist/Codex Export.app" \
    "$STAGED_RELEASE/Codex Export.app"
for item in README.md LICENSE THIRD_PARTY_NOTICES.md; do
    cp "$PROJECT_DIR/$item" "$STAGED_RELEASE/$item"
done

source_items=(
    .github
    .gitignore
    LICENSE
    Package.swift
    README.md
    Resources
    Sources
    Tests
    THIRD_PARTY_NOTICES.md
    VERSION
    scripts
)
for item in "${source_items[@]}"; do
    /usr/bin/ditto "$PROJECT_DIR/$item" "$STAGED_SOURCE/$item"
done

if find "$STAGED_SOURCE" \
    \( -name .build -o -name dist -o -name .DS_Store \) \
    -print -quit | grep -q .; then
    echo "Source package contains a generated or system artifact" >&2
    exit 1
fi
if LC_ALL=C grep -RlaF "$PROJECT_DIR" "$STAGED_SOURCE" >/dev/null; then
    echo "Source package contains a local absolute build path" >&2
    exit 1
fi

(
    cd "$STAGING_ROOT"
    /usr/bin/zip -qry --symlinks "$STAGED_RELEASE_ZIP" "$RELEASE_NAME"
    /usr/bin/zip -qry --symlinks "$STAGED_SOURCE_ZIP" "$SOURCE_NAME"
)
unzip -tq "$STAGED_RELEASE_ZIP" >/dev/null
unzip -tq "$STAGED_SOURCE_ZIP" >/dev/null

if [[ "$UPDATE_SIGNING_ENABLED" -eq 1 ]]; then
    swift "$PROJECT_DIR/scripts/make-update-manifest.swift" \
        --version-file "$PROJECT_DIR/VERSION" \
        --zip "$STAGED_RELEASE_ZIP" \
        --bundle-id com.codexexport.menubar \
        --manifest "$STAGED_UPDATE_MANIFEST" \
        --signature "$STAGED_UPDATE_SIGNATURE"
    [[ -s "$STAGED_UPDATE_MANIFEST" ]]
    [[ "$(stat -f %z "$STAGED_UPDATE_SIGNATURE")" -eq 64 ]]
fi

for index in "${!targets[@]}"; do
    target="${targets[$index]}"
    if [[ -e "$target" || -L "$target" ]]; then
        had_original[$index]=1
        mv "$target" "$BACKUP_ROOT/$index"
    fi
done

for index in "${!targets[@]}"; do
    INSTALLING_INDEX=$index
    mv "${staged[$index]}" "${targets[$index]}"
    installed[$index]=1
    INSTALLING_INDEX=-1
done

COMMITTED=1
rm -rf "$BACKUP_ROOT"
echo "Packaged $RELEASE_NAME in $OUTPUT_ROOT"
