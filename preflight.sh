#!/bin/sh
# shellcheck shell=dash
# BusyBox ash and dash provide the required process resource limits.
# Runs from trusted unpacked source without installing LoKi or executing package hooks.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
incomplete() {
    printf '{"schema":1,"result":"incomplete","complete":false,"install_allowed":false,"reason":"%s"}\n' "$1"
    exit 2
}
[ "$#" -eq 0 ] || incomplete unsupported-arguments
command -v ucode >/dev/null 2>&1 || incomplete ucode-unavailable
command -v timeout >/dev/null 2>&1 || incomplete timeout-unavailable
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || incomplete source-directory-unavailable
umask 077
scratch=$(mktemp -d /tmp/loki-preflight.XXXXXX) || incomplete scratch-unavailable
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 2' HUP INT TERM
result=$(
    ulimit -c 0 && ulimit -v 65536 && ulimit -t 10 || exit 3
    exec env -i PATH="$PATH" timeout -s KILL 15 ucode -L "$root/loki/files/usr/lib" "$root/preflight.uc" \
        "$root/candidate-manifest.json" "$root/loki/files/etc/config/loki" "$scratch" "$root"
) 2>/dev/null
status=$?
rm -rf -- "$scratch" || incomplete scratch-cleanup-failed
trap - EXIT HUP INT TERM
case "$status" in
    1|2) [ -n "$result" ] || incomplete reader-failed ;;
    *) incomplete reader-failed-or-timeout ;;
esac
printf '%s\n' "$result"
exit "$status"
