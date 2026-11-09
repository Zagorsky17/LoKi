#!/bin/sh
# shellcheck shell=dash
# Separate removal entry; the worker preserves saved configuration and unrelated packages.
[ "$#" = 2 ] || { printf 'Usage: sh uninstall.sh CANDIDATE_DIRECTORY MANIFEST_SHA256\n' >&2; exit 2; }
exec /bin/sh "$(dirname -- "$0")/component-update.sh" uninstall "$1" "$2"
