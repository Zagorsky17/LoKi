#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
"$HERE/prepare.sh" "$work/source"
cd -- "$work/source"
export GOTOOLCHAIN=local
go mod verify
unformatted=$(gofmt -l adapter/dns.go dns/router.go common/dialer/resolve*.go log/observable.go log/error_repeats*.go \
    adapter/provider.go adapter/experimental.go adapter/provider/{adapter,graph}.go \
    adapter/provider/{adapter_test.go,identity_test.go,identity_utf8_test.go} experimental/cachefile/{cache.go,selector_state_test.go} \
    protocol/group/{selector.go,selector_identity_test.go} experimental/clashapi/proxies.go \
    adapter/outbound/{manager.go,commit_test.go} provider/remote/*.go \
    experimental/cachefile/*.go dns/transport/fakeip/store_cachefile_test.go box.go)
if [[ -n "$unformatted" ]]; then
    printf 'Unformatted core patch files:\n%s\n' "$unformatted" >&2
    exit 1
fi
tags=$(./build.sh --print-tags --variant base amd64)
packages=(./common/dialer ./dns/... ./log ./adapter/provider ./adapter/outbound ./provider/remote ./protocol/group ./experimental/cachefile ./experimental/clashapi)
go vet -tags "$tags" "${packages[@]}"
go test -tags "$tags" -ldflags="$(tr '\n' ' ' < release/LDFLAGS)" "${packages[@]}" "$@"
