#!/bin/sh
# Compatibility URL for the same architecture-based installer used by SSH and LuCI.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
script=$(mktemp /tmp/loki-bootstrap.XXXXXX) || exit 1
trap 'rm -f "$script"' EXIT
trap 'exit 1' HUP INT TERM
wget -T 30 -O "$script" https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install.sh || exit 1
sh "$script" "$@"
