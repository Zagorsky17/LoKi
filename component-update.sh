#!/bin/sh
# shellcheck shell=dash
# Run only from a trusted private offline kit or the protected installed directory.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
refuse() { printf '{"success":false,"reason":"%s"}\n' "$1"; exit 1; }
[ "$(id -u)" = 0 ] || refuse root-required
[ -r /etc/openwrt_release ] || refuse openwrt-required
available=$(awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ && $3 == "kB" { print $2; exit }' /proc/meminfo)
case "$available" in ''|*[!0-9]*) refuse resource-memory-unavailable ;; esac
[ "$available" -ge 49152 ] 2>/dev/null || refuse resource-candidate-memory-insufficient
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || refuse source-directory-unavailable
if [ -d "$root/loki/files/usr/lib" ]; then
    library=$root/loki/files/usr/lib
else
    library=/usr/lib/loki
fi
case "${1:-}" in
    install|update|uninstall) [ "$#" = 3 ] || refuse invalid-transaction-arguments ;;
    recover) [ "$#" = 1 ] || refuse invalid-transaction-arguments ;;
    *) refuse invalid-transaction-arguments ;;
esac
# Initialize the existing kernel-lock protocol before handing an inheritable FD to the worker.
ucode -L "$library" "$root/component-update.uc" prepare || refuse transaction-busy-or-unsafe-lock
exec 9<>/var/lock/loki-install.lock/.kernel || refuse transaction-lock-unavailable
/bin/busybox flock -n 9 || refuse transaction-busy-or-unsafe-lock
exec env -i PATH="$PATH" LC_ALL=C ucode -L "$library" "$root/component-update.uc" "$@"
