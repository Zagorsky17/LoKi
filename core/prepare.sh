#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/upstream.env"
if (( $# != 1 )) || [[ -e "$1" || -L "$1" ]]; then
    echo "Usage: $0 NEW-SOURCE-DIRECTORY" >&2
    exit 2
fi
destination=$1
cache=${XDG_CACHE_HOME:-$HOME/.cache}/loki/core
archive=$cache/$CORE_COMMIT.tar.gz
mkdir -p -- "$cache"
if [[ ! -f "$archive" ]]; then
    download=$(mktemp "$cache/download.XXXXXX")
    trap 'rm -f -- "$download"' EXIT
    curl --fail --location --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 20 --max-time 300 \
        "https://codeload.github.com/ushan0v/sing-box-forkop/tar.gz/$CORE_COMMIT" -o "$download"
    printf '%s  %s\n' "$CORE_ARCHIVE_SHA256" "$download" | sha256sum --check --status
    mv -- "$download" "$archive"
fi
printf '%s  %s\n' "$CORE_ARCHIVE_SHA256" "$archive" | sha256sum --check --status
mkdir -- "$destination"
tar -xzf "$archive" --strip-components=1 -C "$destination"
for patch in "$HERE"/patches/*.patch; do
    git -C "$destination" apply --check --whitespace=error-all "$patch"
    git -C "$destination" apply --whitespace=error-all "$patch"
done
cp -- "$HERE/COPYING" "$destination/LICENSE"
# The inherited builder checks indexed files for CRLF; no commit or remote is needed.
git -C "$destination" init --quiet --initial-branch=vendor
git -C "$destination" add .
