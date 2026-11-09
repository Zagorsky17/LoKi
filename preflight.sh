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
expected=''
if [ "$#" -ne 0 ]; then
    [ "$#" = 2 ] || incomplete unsupported-arguments
    [ "$1" = --manifest-sha256 ] || incomplete unsupported-arguments
    expected=$2
    case "$expected" in ''|*[!a-f0-9]*) incomplete invalid-manifest-sha256 ;; esac
    [ "${#expected}" = 64 ] || incomplete invalid-manifest-sha256
fi
command -v ucode >/dev/null 2>&1 || incomplete ucode-unavailable
[ -x /bin/busybox ] || incomplete busybox-unavailable
available=$(awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ && $3 == "kB" { print $2; exit }' /proc/meminfo)
case "$available" in ''|*[!0-9]*) incomplete resource-memory-unavailable ;; esac
[ "$available" -ge 49152 ] 2>/dev/null || incomplete resource-candidate-memory-insufficient
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || incomplete source-directory-unavailable
umask 077
scratch=$(mktemp -d /tmp/loki-preflight.XXXXXX) || incomplete scratch-unavailable
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 2' HUP INT TERM
result=$(
    ulimit -c 0 && ulimit -S -v 65536 && ulimit -t 10 || exit 3
    # The RPC worker uses the same watchdog; stock BusyBox need not enable timeout.
    # Expand these variables in the isolated child, not in this launcher.
    # shellcheck disable=SC2016
    exec env -i PATH="$PATH" /bin/busybox setsid /bin/busybox ash -c '
        umask 077
        /bin/busybox mkfifo "$0/ready" || exit 125
        exec 3<>"$0/ready"
        (
            exec >/dev/null 2>&1
            trap '\''kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0'\'' TERM
            /bin/busybox sleep 15 & sleeper=$!
            printf "ready\n" >&3
            exec 3>&-
            wait "$sleeper"
            kill -KILL -- "-$$"
        ) & guard=$!
        read -r -t 1 ready <&3; ready_status=$?
        exec 3>&-
        code=125
        if [ "$ready_status" = 0 ] && [ "$ready" = ready ]; then "$@"; code=$?; fi
        kill "$guard" 2>/dev/null
        wait "$guard" 2>/dev/null
        exit "$code"
    ' "$scratch" ucode -L "$root/loki/files/usr/lib" "$root/preflight.uc" \
        "$root/candidate-manifest.json" "$root/loki/files/etc/config/loki" "$scratch" "$root" "$expected"
) 2>/dev/null
status=$?
rm -rf -- "$scratch" || incomplete scratch-cleanup-failed
trap - EXIT HUP INT TERM
case "$status" in
    0|1|2) [ -n "$result" ] || incomplete reader-failed ;;
    *) incomplete reader-failed-or-timeout ;;
esac
printf '%s\n' "$result"
exit "$status"
