#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/upstream.env"
if (( $# < 2 )) || [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 X.Y.Z OUTPUT-DIRECTORY [core build options and targets]" >&2
    exit 2
fi
tag=$1
output=$(mkdir -p -- "$2" && cd -- "$2" && pwd)
shift 2
if [[ $(go env GOVERSION) != "go$(cat "$HERE/GO_VERSION")" ]]; then
    echo "Use Go $(cat "$HERE/GO_VERSION") to build this core" >&2
    exit 1
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
"$HERE/prepare.sh" "$work/source"
export SOURCE_DATE_EPOCH=$CORE_SOURCE_DATE_EPOCH
"$work/source/build.sh" "$@" --version "$CORE_VERSION" --output "$work/output"
shopt -s nullglob
packages=("$work/output/"*.ipk "$work/output/"*.apk)
if (( ${#packages[@]} == 0 )); then
    echo "The core build produced no packages" >&2
    exit 1
fi
cp -- "${packages[@]}" "$output/"
tar -C "$work/source" --exclude=./.git --sort=name --mtime="@$CORE_SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner -cf - . | gzip -9n > "$output/core-source-$CORE_VERSION.tar.gz"
python3 - "$output" "$tag" "$CORE_VERSION" <<'PY'
import json
from pathlib import Path
import sys
output, tag, version = sys.argv[1:]
manifest = {
    'schema': 1, 'name': 'sing-box-forkop', 'version': version, 'tag': tag,
    'page': f'https://github.com/Zagorsky17/LoKi/releases/tag/{tag}',
    'requires': {'forkop': tag},
}
(Path(output) / 'core-release.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
cd -- "$output"
find . -maxdepth 1 -type f \( -name '*.ipk' -o -name '*.apk' -o -name release.json \
    -o -name core-release.json -o -name install.sh -o -name 'core-source-*.tar.gz' \) -printf '%f\0' |
    LC_ALL=C sort -z | xargs -0 sha256sum -- > SHA256SUMS
