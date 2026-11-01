#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
"$HERE/prepare.sh" "$work/source"
cd -- "$work/source"
export GOTOOLCHAIN=local
go mod verify
unformatted=$(gofmt -l adapter/dns.go dns/router.go common/dialer/resolve*.go)
if [[ -n "$unformatted" ]]; then
    printf 'Unformatted core patch files:\n%s\n' "$unformatted" >&2
    exit 1
fi
tags=$(./build.sh --print-tags --variant base amd64)
go vet -tags "$tags" ./common/dialer ./dns/...
go test -tags "$tags" -ldflags="$(tr '\n' ' ' < release/LDFLAGS)" ./common/dialer ./dns/... "$@"
