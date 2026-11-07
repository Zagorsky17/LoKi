#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
(umask 0002; "$HERE/prepare.sh" "$work/source")
if [[ -n "$(find "$work/source" -type f -perm /022 -print -quit)" ]]; then
    echo "Core preparation left group- or world-writable source files" >&2
    exit 1
fi
cd -- "$work/source"
python3 -B "$HERE/tests/package_namespace.py" "$PWD"
export GOTOOLCHAIN=local
go mod verify
unformatted=$(gofmt -l adapter/dns.go dns/router.go common/dialer/resolve*.go log/observable.go log/error_repeats*.go \
    adapter/provider.go adapter/experimental.go adapter/provider/{adapter,graph}.go \
    adapter/provider/{adapter_test.go,identity_test.go,identity_utf8_test.go} experimental/cachefile/{cache.go,selector_state_test.go} \
    protocol/group/{selector.go,selector_identity_test.go,fallback.go,fallback_test.go} experimental/clashapi/proxies.go \
    adapter/outbound/{manager.go,commit_test.go} provider/remote/*.go \
    experimental/cachefile/*.go dns/transport/fakeip/store_cachefile_test.go box.go \
    common/lokicontroller/*.go common/lokigateway/*.go cmd/sing-box/cmd_gateway_linux.go cmd/sing-box/cmd_check*.go \
    experimental/clashapi/common.go experimental/clashapi/common_gateway_test.go \
    experimental/clashapi/server.go experimental/clashapi/server_private_controller_test.go option/experimental.go)
if [[ -n "$unformatted" ]]; then
    printf 'Unformatted core patch files:\n%s\n' "$unformatted" >&2
    exit 1
fi
tags=$(./build.sh --print-tags --variant base amd64)
packages=(./common/dialer ./dns/... ./log ./adapter/provider ./adapter/outbound ./provider/remote ./protocol/group ./experimental/cachefile ./experimental/clashapi ./route/rule ./common/lokicontroller ./common/lokigateway ./cmd/sing-box)
go vet -tags "$tags" "${packages[@]}"
go test -tags "$tags" -ldflags="$(tr '\n' ' ' < release/LDFLAGS)" "${packages[@]}" "$@"
