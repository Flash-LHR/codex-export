#!/usr/bin/env bash

load_project_version() {
    local version_file="$1"
    local key value

    if [[ ! -f "$version_file" ]]; then
        echo "Missing version source: $version_file" >&2
        return 1
    fi

    MARKETING_VERSION=""
    BUILD_NUMBER=""
    while IFS='=' read -r key value; do
        case "$key" in
            MARKETING_VERSION) MARKETING_VERSION="$value" ;;
            BUILD_NUMBER) BUILD_NUMBER="$value" ;;
            ''|'#'*) ;;
            *)
                echo "Unknown key in VERSION: $key" >&2
                return 1
                ;;
        esac
    done < "$version_file"

    if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Invalid MARKETING_VERSION in VERSION" >&2
        return 1
    fi
    if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid BUILD_NUMBER in VERSION" >&2
        return 1
    fi
}
