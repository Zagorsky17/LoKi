#!/bin/sh
# Modified for LoKi on 2026-10-31: use the project release repository.
# shellcheck shell=dash
#
# Installs, updates and removes Forkop and its core, sing-box-forkop, on OpenWrt 24.10 and newer.
# Its options and exit codes are the interface Forkop's page runs it through, so they change only
# in ways an older page understands.
#
# Options: --variant base|full|tiny, the core's build (the installed one, or base, by default),
# with no value asked for at the terminal; --uninstall [--purge], with --purge the settings too;
# --quiet, the package manager's output in the log alone, as the page has it; --lang ru|en, by
# default LuCI's language, Russian while that is auto, since a console has no browser to follow.
# Exit codes: 0 done or nothing to do, 1 failed before anything changed, 2 bad options, 3 failed
# after changes began, 4 installed but Forkop did not start.
# Colors follow whether stdout is a terminal, questions whether /dev/tty opens: a page that runs it
# on a pseudo-terminal without making it the controlling one gets colors and no questions.
#
# The releases come through api.github.com, which takes 60 requests an hour from an address
# without an account; FORKOP_DOWNLOAD_URL names a mirror with github.com's release paths instead.
# https_proxy and http_proxy are honored, NO_COLOR turns colors off.
#
# Every release carries release.json beside its packages, install.sh and SHA256SUMS:
#   {"schema":1,"name":"forkop","version":"2.0.0","tag":"2.0.0","page":URL,
#    "requires":{"sing-box-forkop":"1.14.4-r1"},"min_config_version":"1.0.2"}
# The core's says "name":"sing-box-forkop" and requires the oldest Forkop it works with. An
# "install_command" field says the release installs only with that command, not from the page.

set -u

FORKOP_REPO=Zagorsky17/LoKi
CORE_REPO=ushan0v/sing-box-forkop
# github.com answers a release link with a header line longer than uclient-fetch reads
API_URL=https://api.github.com
MIRROR=${FORKOP_DOWNLOAD_URL:-}
LOG=/tmp/forkop-install.log
LOCK_DIR=/var/lock/forkop-install.lock
OUR_PACKAGES="forkop luci-app-forkop luci-i18n-forkop-ru sing-box-forkop"
# The other packages known to install /usr/bin/sing-box; any other package that owns it counts too.
FOREIGN_CORES="sing-box sing-box-tiny sing-box-extended podkop-engine podkop-engine-full sing-box-lx sing-box-x rust-x steer-box-connector"
# What sing-box-forkop provides: a package that needs it stays when a foreign core goes.
CORE_PROVIDES=sing-box
# What a core outside the package managers leaves: Forkop 1.0.x's binary builds and the installer
# of EikeiDev/OpenWRT-sing-box-extended, whose wrapper runs the core from /usr/libexec.
FOREIGN_CORE_FILES="/usr/bin/sing-box /etc/init.d/sing-box /usr/libexec/sing-box-core /etc/sing-box-version.cache /usr/lib/libcronet.so"
# Forkop 1.0.x's own state about its cores, and the backups its updater left when it failed.
LEGACY_FILES="/etc/forkop/sing-box-variant /etc/forkop/sing-box-version /usr/bin/sing-box.forkop-backup.* /usr/lib/libcronet.so.forkop-backup.* /etc/init.d/sing-box.forkop.*"
# What the builds of the core speak, by the variants of its build.sh: tiny, what base adds to it,
# and what full adds to base (full_adds).
TINY_HAS='VLESS, Trojan, Shadowsocks, Hysteria, Hysteria2, TUIC, SOCKS, HTTP'
BASE_ADDS='WireGuard, AmneziaWG, WARP, OpenVPN, TrustTunnel, VMess, AnyTLS'
# apk offline still opens every feed's index and warns for each one no apk update fetched since boot.
APK_OFFLINE="--no-network --repositories-file /dev/null"
# The defaults a package manager leaves beside a config it keeps.
CONFFILE_COPIES="/etc/config/forkop-opkg /etc/config/forkop.apk-new /etc/config/sing-box-opkg /etc/config/sing-box.apk-new /etc/sing-box/config.json-opkg /etc/sing-box/config.json.apk-new"

MODE=install VARIANT='' ASK_VARIANT=0 PURGE=0 QUIET=0 LANG_OPT='' BAD_ARG=''
RU=0 INTERACTIVE=0 ASKED=0 PROMPTING=0 ANSWER='' C_STEP='' C_OK='' C_WARN='' C_ERR='' C_BOLD='' C_OFF=''
WORK='' LOCKED=0
PM='' PM_DB='' EXT='' ARCH='' RELEASE='' FLASH_MOUNT=/ FLASH_FS=''
FORKOP_OLD='' APP_OLD='' I18N_OLD='' CORE_OLD='' CORE_OLD_VARIANT='' CONFIG_VERSION='' FORK_URL=''
FORKOP_ENABLED=0 FORKOP_RUNNING=0 STARTED=0
FOREIGN_PKGS='' FOREIGN_WORLD='' FOREIGN_FILES='' LEFTOVERS=''
F_VERSION='' F_TAG='' F_CORE_MIN='' C_VERSION='' C_TAG='' C_FORKOP_MIN=''
I18N=0 NEED_FORKOP=0 NEED_APP=0 NEED_I18N=0
CORE_ACTION=none CORE_VARIANT='' CORE_REINSTALL=0
FILE_FORKOP='' FILE_APP='' FILE_I18N='' FILE_CORE='' FILE_IP='' GOT=''
CONFIG_PLAN=none CONFIG_FROM='' CONFIG_REASON=''
REMOVE_PKGS='' REMOVE_FILES='' DEPS_MISSING='' DEPS_KB=0 LISTS_FAILED=0 PREDELETE_CORE=0 OPKG_FLAGS='' OPKG_DB_COPY=''
RESULT_FORKOP='' RESULT_CORE='' RESULT_VARIANT='' BACKUP=''

# --- output ---------------------------------------------------------------------------------

log() {
	printf '%s\n' "$*" >>"$LOG" 2>/dev/null
}

t() { # t ENGLISH RUSSIAN [ARG]...: the message in the output language, printf-formatted
	local format="$1"
	[ "$RU" = 1 ] && format="$2"
	shift 2
	# shellcheck disable=SC2059
	printf "$format" "$@"
}

say() { # say MARK COLOR TEXT
	printf '%s%s%s %s\n' "$2" "$1" "$C_OFF" "$3" 2>/dev/null
}

step() { # step ID TEXT: a stage the person waits through
	log "== $1: $2"
	say '[*]' "$C_STEP" "$2"
}

info() { # a fact worth knowing: what goes in, what came out
	log "info: $1"
	say '[+]' "$C_OK" "$1"
}

removed() { # a package or file that is gone
	log "removed: $1"
	say '[-]' "$C_ERR" "$(t 'Removed %s' 'Удалён %s' "$1")"
}

warn() { # warn CODE TEXT
	log "warn ($1): $2"
	say '[!]' "$C_WARN" "$2"
}

detail() { # a hint under the line before: what to do or where to look
	log "   $1"
	say '[!]' "$C_WARN" "$1"
}

fail() { # fail EXIT CODE TEXT [HINT]...
	local status="$1" code="$2" text="$3" hint joined=''
	shift 3
	for hint in "$@"; do [ -z "$hint" ] || joined="${joined:+$joined. }$hint"; done
	log "error ($code): $text${joined:+ | $joined}"
	if [ "$code" = interrupted ]; then
		say '[!]' "$C_WARN" "$text" >&2
	else
		say '[x]' "$C_ERR" "$text" >&2
		for hint in "$@"; do [ -z "$hint" ] || detail "$hint" >&2; done
	fi
	finish "$status" "$code"
}

finish() { # finish EXIT [CODE]
	if [ "$1" = 3 ] || [ "$1" = 4 ] ||
		{ [ "$1" = 1 ] && contains "${2:-}" "network release checksum migration check package_manager no_memory"; }; then
		[ -z "$BACKUP" ] || detail "$(t 'The old config is kept as %s' 'Прежний конфиг сохранён как %s' "$BACKUP")" >&2
		detail "$(t 'Installer log: %s' 'Журнал установщика: %s' "$LOG")" >&2
	fi
	cleanup
	exit "$1"
}

cleanup() {
	[ -z "$WORK" ] || rm -rf "$WORK"
	[ "$LOCKED" = 0 ] || rm -rf "$LOCK_DIR"
}

# shellcheck disable=SC2317
on_signal() { # before any change: apply and uninstall ignore these signals while they change things
	trap '' INT TERM HUP PIPE
	# a question cut short leaves its line open
	[ "$PROMPTING" = 0 ] || printf '\n' >/dev/tty 2>/dev/null
	fail 1 interrupted "$(t 'Interrupted: nothing was changed' 'Прервано, ничего не изменено')"
}

usage_error() {
	local message
	case "$BAD_ARG" in
	variant) message=$(t 'The option --variant takes base, full or tiny' 'Параметр --variant принимает base, full или tiny') ;;
	lang) message=$(t 'The option --lang takes ru or en' 'Параметр --lang принимает ru или en') ;;
	purge) message=$(t 'The option --purge goes with --uninstall' 'Параметр --purge работает только с --uninstall') ;;
	uninstall) message=$(t 'The option --uninstall takes no --variant' 'Параметр --uninstall не сочетается с --variant') ;;
	variant_tty) message=$(t 'The option --variant with no value asks for the build and needs a terminal' 'Параметр --variant без значения спрашивает сборку и работает только в терминале') ;;
	value:*) message=$(t '%s needs a value' 'Параметру %s нужно значение' "${BAD_ARG#value:}") ;;
	*) message=$(t 'Unknown option: %s' 'Неизвестный параметр: %s' "${BAD_ARG#unknown:}") ;;
	esac
	say '[x]' "$C_ERR" "$message" >&2
	detail "$(t 'Options: --variant [base|full|tiny], --uninstall [--purge], --quiet, --lang ru|en' 'Параметры: --variant [base|full|tiny], --uninstall [--purge], --quiet, --lang ru|en')" >&2
	exit 2
}

prompt() { # prompt TEXT CHOICES: TEXT and [CHOICES], what Enter gives, on the terminal; ANSWER from it
	printf '%s%s%s %s[%s]%s: ' "$C_BOLD" "$1" "$C_OFF" "$C_STEP" "$2" "$C_OFF" >/dev/tty
	ANSWER=''
	PROMPTING=1
	read -r ANSWER </dev/tty || ANSWER=''
	PROMPTING=0
}

ask() { # ask QUESTION [DEFAULT]: 0 when the answer is yes; DEFAULT 1 makes Enter a yes
	local choices=y/N
	[ "${2:-0}" = 0 ] || choices=Y/n
	while :; do
		prompt "$1" "$choices"
		case "$ANSWER" in
		y | Y | yes | Yes | YES | д | Д | да | Да | ДА) return 0 ;;
		n | N | no | No | NO | н | Н | нет | Нет | НЕТ) return 1 ;;
		'') [ "${2:-0}" = 1 ]; return ;;
		esac
	done
}

question_block() { # the questions on what to install go together, a blank line above and below them
	[ "$ASKED" = 1 ] || printf '\n' >/dev/tty
	ASKED=1
}

may_ask() { # a person at a terminal
	[ "$INTERACTIVE" = 1 ]
}

full_adds() { # what full adds to base, as the core's build.sh builds it for this processor
	printf 'Tailscale, OpenConnect, '
	# NaiveProxy links cronet, which cronet-go builds for these processors only
	case "$ARCH" in
	x86_64 | i386_pentium4 | aarch64_* | arm_cortex-a*_* | mipsel_24kc | mipsel_24kc_24kf | mipsel_74kc | riscv64_* | loongarch64_*)
		printf 'NaiveProxy, '
		;;
	esac
	printf 'Mieru, Snell, SSH, ShadowTLS, Tor'
}

menu_card() { # menu_card NUMBER NAME TAG [TAG_COLOR] [DETAILS]: an option of the build menu, its details under it, a blank line after
	printf '%s%s)%s %s%s%s — %s%s%s\n' "$C_STEP" "$1" "$C_OFF" "$C_BOLD" "$2" "$C_OFF" "${4:-}" "$3" "$C_OFF"
	[ -z "${5:-}" ] || printf '   %s\n' "$5"
	printf '\n'
}

choose_variant() { # choose_variant [KEEP]: CORE_VARIANT from a menu at the terminal; KEEP offers to keep the custom core
	local default=2
	case "$CORE_VARIANT" in tiny) default=1 ;; full) default=3 ;; esac
	[ -z "${1:-}" ] || default=0
	question_block
	{
		if [ -z "$CORE_OLD" ]; then
			printf '%s\n\n' "$(t 'Forkop runs on its own core, sing-box-forkop' 'Forkop работает на собственном ядре sing-box-forkop')"
		elif [ "$CORE_VARIANT" != custom ]; then
			printf '%s\n\n' "$(t 'Installed: sing-box-forkop %s (%s)' 'Установлен sing-box-forkop %s (%s)' "$CORE_OLD" "$CORE_VARIANT")"
		fi
		[ -z "${1:-}" ] || menu_card 0 custom "$(t 'keep the custom build %s' 'оставить кастомную сборку %s' "$1")"
		menu_card 1 tiny "$(t minimal минимальная)" '' "$TINY_HAS"
		menu_card 2 base "$(t recommended рекомендуемая)" "$C_OK" "+ $BASE_ADDS"
		menu_card 3 full "$(t maximal максимальная)" '' "+ $(full_adds)"
	} >/dev/tty
	while :; do
		prompt "$(t 'Which build of sing-box-forkop to install?' 'Какую сборку sing-box-forkop установить?')" "$default"
		case "${ANSWER:-$default}" in
		0 | custom) [ "$default" = 0 ] && break ;;
		1 | tiny) CORE_VARIANT=tiny && break ;;
		2 | base) CORE_VARIANT=base && break ;;
		3 | full) CORE_VARIANT=full && break ;;
		esac
	done
	log "build chosen: $CORE_VARIANT"
}

ask_translation() { # a first install asks whether Forkop's page gets its Russian translation
	[ -z "$FORKOP_OLD" ] && may_ask || return 0
	question_block
	if ask "$(t 'Install the Russian translation of the Forkop page?' 'Установить русский перевод страницы Forkop?')" "$I18N"; then
		I18N=1
	else
		I18N=0
	fi
	NEED_I18N=$I18N
	log "translation chosen: $I18N"
}

# --- helpers --------------------------------------------------------------------------------

is_number() {
	case "$1" in '' | *[!0-9]*) return 1 ;; esac
}

mb() { # kilobytes as megabytes with one decimal
	awk -v k="$1" 'BEGIN { printf "%.1f", k / 1024 }'
}

contains() { # contains WORD LIST
	case " $2 " in *" $1 "*) return 0 ;; esac
	return 1
}

commas() { # the words given, sorted and comma-separated
	# shellcheck disable=SC2048,SC2086
	printf '%s\n' $* | sort | awk 'NR > 1 { printf ", " } { printf "%s", $0 }'
}

openwrt_value() {
	sed -n "s/^$1='\(.*\)'\$/\1/p" /etc/openwrt_release | head -n 1
}

free_kb() {
	df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

mem_available_kb() {
	awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo
}

file_kb() {
	[ -f "$1" ] || { echo 0; return; }
	wc -c <"$1" | awk '{ printf "%d", ($1 + 1023) / 1024 }'
}

upper_kb() { # what file $1 takes on the flash: nothing when it lives in the read-only image
	if [ "$FLASH_MOUNT" = /overlay ]; then file_kb "/overlay/upper$1"; else file_kb "$1"; fi
}

deadline() { # deadline SECONDS COMMAND...: the command's status, 124 once it ran out of time
	local seconds="$1" pid waited=0
	shift
	"$@" &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$waited" -ge "$seconds" ]; then
			kill "$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			return 124
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "$pid"
}

run() { # run COMMAND...: as perform, for a command whose output nothing reads
	perform "$WORK/run.out" "$@"
}

# apk and opkg set their own SIGINT handler: in a session of their own Ctrl+C and hangups miss them
# shellcheck disable=SC2317
detached() {
	if command -v setsid >/dev/null 2>&1; then setsid "$@"; else "$@"; fi
}

capture() { # capture FILE COMMAND...: its output into FILE and the log
	local file="$1" status
	shift
	log "\$ $*"
	"$@" >"$file" 2>&1
	status=$?
	cat "$file" >>"$LOG" 2>/dev/null
	return "$status"
}

# A lost terminal fails only the echo: the pipe is drained, so the package manager never stalls.
perform() { # perform FILE COMMAND...: as capture, and on the terminal
	local file="$1" status line
	shift
	if [ "$QUIET" = 1 ]; then
		capture "$file" "$@"
		return
	fi
	log "\$ $*"
	: >"$file"
	{ "$@" 2>&1; echo "$?" >"$file.status"; } | while IFS= read -r line || [ -n "$line" ]; do
		printf '%s\n' "$line" >>"$file"
		printf '%s\n' "$line" 2>/dev/null
	done
	read -r status <"$file.status" 2>/dev/null || status=1
	rm -f "$file.status"
	cat "$file" >>"$LOG" 2>/dev/null
	return "$status"
}

pm_errors() { # what the package manager complained of in its output file $1, on one line
	local errors
	if [ "$PM" = apk ]; then
		errors=$(grep -A 3 '^ERROR' "$1")
	else
		errors=$(grep -m 3 -e '^ \* ' -e '^Unknown package' "$1")
	fi
	errors=$(printf '%s' "$errors" | tr -s ' \n' ' ')
	printf '%s' "${errors:-$(t 'see the log' 'подробности в журнале')}"
}

vercmp() { # vercmp A B: -1, 0 or 1 in the order of the package manager
	if [ "$PM" = apk ]; then
		case "$(apk version -t "$1" "$2" 2>/dev/null)" in
		'<') echo -1 ;; '>') echo 1 ;; *) echo 0 ;;
		esac
	elif opkg compare-versions "$1" = "$2"; then
		echo 0
	elif opkg compare-versions "$1" '<<' "$2"; then
		echo -1
	else
		echo 1
	fi
}

older() { # older A B: A is a version before B
	[ "$(vercmp "$1" "$2")" = -1 ]
}

# --- packages -------------------------------------------------------------------------------

refresh_db() { # name, version, depends and provides of every installed package
	if [ "$PM" = apk ]; then
		awk '
			/^P:/ { n = substr($0, 3) } /^V:/ { v = substr($0, 3) }
			/^D:/ { d = substr($0, 3) } /^p:/ { p = substr($0, 3) }
			/^$/ { if (n != "") print n "\t" v "\t" d "\t" p; n = v = d = p = "" }
			END { if (n != "") print n "\t" v "\t" d "\t" p }' /lib/apk/db/installed
	else
		awk '
			/^Package: / { n = $2 } /^Version: / { v = $2 } /^Status: / { s = $0 }
			/^Depends: / { d = substr($0, 10) } /^Provides: / { p = substr($0, 11) }
			/^$/ { if (n != "" && s ~ / installed$/) print n "\t" v "\t" d "\t" p; n = v = d = p = s = "" }
			END { if (n != "" && s ~ / installed$/) print n "\t" v "\t" d "\t" p }' /usr/lib/opkg/status
	fi >"$WORK/db" 2>/dev/null
}

pkg_version() { # the installed version of package $1, nothing when it is not installed
	awk -F '\t' -v p="$1" '$1 == p { print $2; exit }' "$WORK/db"
}

pkg_url() { # the project URL installed package $1 names
	if [ "$PM" = apk ]; then
		awk -v p="$1" '/^P:/ { n = substr($0, 3) } /^U:/ && n == p { print substr($0, 3); exit }' /lib/apk/db/installed
	else
		sed -n 's/^URL: *//p' "/usr/lib/opkg/info/$1.control" 2>/dev/null | head -n 1
	fi
}

pkg_depends() { # the dependencies of installed package $1
	awk -F '\t' -v p="$1" '$1 == p { print $3; exit }' "$WORK/db"
}

core_requirement() { # the sing-box-forkop version a Depends field asks for: opkg "(>= V)", apk ">=V"
	printf '%s\n' "$1" | sed -n 's/.*sing-box-forkop *(* *>= *\([^), ]*\).*/\1/p'
}

provided() { # an installed package is or provides $1
	awk -F '\t' -v p="$1" '
		$1 == p { found = 1; exit }
		{ n = split($4, a, /[ ,]+/); for (i = 1; i <= n; i++) { w = a[i]; sub(/[<>=~(].*/, "", w); if (w == p) { found = 1; exit } } }
		END { exit !found }' "$WORK/db"
}

file_owner() { # the installed package that owns file $1
	if [ "$PM" = apk ]; then
		awk -v f="${1#/}" '/^P:/ { n = substr($0, 3) } /^F:/ { d = substr($0, 3) } /^R:/ { if (d "/" substr($0, 3) == f) { print n; exit } }' /lib/apk/db/installed
	else
		grep -l -x -F "$1" /usr/lib/opkg/info/*.list 2>/dev/null | head -n 1 | sed 's|.*/||; s|\.list$||'
	fi
}

in_world() {
	[ "$PM" = apk ] && grep -q -E "^$1([<>=~].*)?\$" /etc/apk/world 2>/dev/null
}

world_drop() { # remove the exact lines given from /etc/apk/world
	[ "$PM" = apk ] && [ -n "$*" ] || return 0
	awk -v drop=" $* " 'index(drop, " " $0 " ") == 0' /etc/apk/world >"$WORK/world" &&
		cat "$WORK/world" >/etc/apk/world
}

dependents() { # the installed packages in $1 and every installed package that needs one of them
	awk -F '\t' -v set=" $1 " -v keep=" $OUR_PACKAGES " -v stays=" $CORE_PROVIDES " '
		function names(s, out,    n, i, a, w) {
			gsub(/\([^)]*\)/, "", s); gsub(/[,|]/, " ", s)
			n = split(s, a, " ")
			for (i = 1; i <= n; i++) { w = a[i]; sub(/[<>=~].*/, "", w); if (w != "" && w !~ /^!/) out[w] = 1 }
		}
		{ name[NR] = $1; deps[NR] = $3; prov[NR] = $4; if (index(set, " " $1 " ")) rm[$1] = 1 }
		END {
			do {
				changed = 0
				split("", gone)
				for (i = 1; i <= NR; i++) if (name[i] in rm) { gone[name[i]] = 1; names(prov[i], gone) }
				n = split(stays, kept, " "); for (j = 1; j <= n; j++) delete gone[kept[j]]
				for (i = 1; i <= NR; i++) {
					if ((name[i] in rm) || index(keep, " " name[i] " ")) continue
					split("", need); names(deps[i], need)
					for (w in need) if (w in gone) { rm[name[i]] = 1; changed = 1; break }
				}
			} while (changed)
			for (i = 1; i <= NR; i++) if (name[i] in rm) printf "%s ", name[i]
		}' "$WORK/db"
}

needed_by() { # needed_by NAME...: the installed packages other than Forkop's that depend on one of NAMES
	awk -F '\t' -v want=" $* " -v ours=" $OUR_PACKAGES " '
		index(ours, " " $1 " ") { next }
		{
			s = $3; gsub(/\([^)]*\)/, "", s); gsub(/[,|]/, " ", s)
			n = split(s, a, " ")
			for (i = 1; i <= n; i++) { w = a[i]; sub(/[<>=~].*/, "", w); if (index(want, " " w " ")) { printf "%s ", $1; break } }
		}' "$WORK/db"
}

removal_order() { # the packages in $1 ordered so that nothing is removed before what needs it
	awk -F '\t' -v set=" $1 " '
		function needs(s, w,    n, i, a, x) {
			gsub(/\([^)]*\)/, "", s); gsub(/[,|]/, " ", s)
			n = split(s, a, " ")
			for (i = 1; i <= n; i++) { x = a[i]; sub(/[<>=~].*/, "", x); if (x == w) return 1 }
			return 0
		}
		index(set, " " $1 " ") { k++; name[k] = $1; deps[k] = $3; prov[k] = $4 }
		END {
			left = k
			while (left > 0) {
				progress = 0
				for (i = 1; i <= k; i++) {
					if (done[i]) continue
					blocked = 0
					for (j = 1; j <= k; j++) {
						if (j == i || done[j]) continue
						if (needs(deps[j], name[i])) { blocked = 1; break }
						n = split(prov[i], p, " ")
						for (m = 1; m <= n; m++) { x = p[m]; sub(/[<>=~].*/, "", x); if (needs(deps[j], x)) { blocked = 1; break } }
						if (blocked) break
					}
					if (!blocked) { printf "%s ", name[i]; done[i] = 1; left--; progress = 1 }
				}
				if (!progress) for (i = 1; i <= k; i++) if (!done[i]) { printf "%s ", name[i]; done[i] = 1; left-- }
			}
		}' "$WORK/db"
}

control_of() { # control_of FILE: the package's control fields, read once per run
	local saved="$WORK/control/${1##*/}"
	if [ ! -f "$saved" ]; then
		mkdir -p "$WORK/control"
		read_control "$1" >"$saved.new" && mv "$saved.new" "$saved"
	fi
	cat "$saved" 2>/dev/null
}

read_control() { # apk lists conflicts among the dependencies, as !name
	local file="$1" dir="$WORK/control.$$"
	if [ "$EXT" = apk ]; then
		apk adbdump "$file" 2>/dev/null | awk '
			/^info:/ { info = 1; next }
			/^[^ ]/ { info = 0 }
			!info { next }
			/^  [a-z-]+:/ {
				key = $1; sub(/:$/, "", key); value = $0; sub(/^  [a-z-]+: */, "", value); list = (key == "depends")
				if (key == "name") print "Package: " value
				else if (key == "version") print "Version: " value
				else if (key == "arch") print "Architecture: " value
				else if (key == "installed-size") print "Installed-Size: " value
				next
			}
			list && /^    - / {
				d = substr($0, 7); gsub(/\047/, "", d)
				if (d !~ /^!/) depends = depends (depends == "" ? "" : ", ") d
			}
			END { print "Depends: " depends }'
	else
		rm -rf "$dir" && mkdir -p "$dir" || return 1
		tar -xzf "$file" -C "$dir" ./control.tar.gz 2>/dev/null || tar -xzf "$file" -C "$dir" control.tar.gz 2>/dev/null
		tar -xzOf "$dir/control.tar.gz" ./control 2>/dev/null || tar -xzOf "$dir/control.tar.gz" control 2>/dev/null
		rm -rf "$dir"
	fi
}

field() { # field CONTROL NAME
	printf '%s\n' "$1" | sed -n "s/^$2: *//p" | head -n 1
}

dep_names() { # the package names a Depends field lists
	# shellcheck disable=SC2020
	printf '%s\n' "$1" | sed 's/([^)]*)//g' | tr ',| ' '\n\n\n' | sed 's/[<>=~].*//' | grep -v -e '^$' -e '^!'
}

# --- downloads ------------------------------------------------------------------------------

fetch() { # fetch URL FILE [ACCEPT]: 0; 2 when the server answered with an HTTP error, 3 when that was GitHub's rate limit; 1 when it was not reached
	local status
	wget -T 30 ${3:+"--header=Accept: $3"} -O "$2" "$1" 2>"$WORK/fetch.log"
	status=$?
	cat "$WORK/fetch.log" >>"$LOG"
	# uclient-fetch exits 8 when the server answers with an error, which it names unless -q, 4 when it
	# is not reached; GitHub's API answers 403 or 429 once an address spent its requests
	if [ "$status" = 8 ]; then
		grep -q -e 'HTTP error 403' -e 'HTTP error 429' -e 'ERROR 403' -e 'ERROR 429' "$WORK/fetch.log" && return 3
		return 2
	fi
	[ "$status" = 0 ]
}

download() { # download URL FILE [ACCEPT], three tries: 0; 2 when the server has no such file, 3 for GitHub's rate limit; 1 when it was not reached
	local try status
	for try in 1 2 3; do
		rm -f "$2"
		log "download $1"
		fetch "$1" "$2" "${3:-}"
		status=$?
		[ "$status" != 0 ] || [ ! -s "$2" ] || return 0
		case $status in 2 | 3) rm -f "$2"; return "$status" ;; esac
		if [ "$(mem_available_kb)" -lt 4096 ] 2>/dev/null || [ "$(free_kb /tmp)" -lt 1024 ] 2>/dev/null; then
			rm -f "$2"
			fail 1 no_memory "$(t 'Not enough RAM for the downloads' 'Не хватает оперативной памяти для загрузки')" \
				"$(t 'Free some RAM and run the installer again' 'Освободите память и запустите установщик снова')"
		fi
		[ "$try" = 3 ] || sleep 2
	done
	rm -f "$2"
	return 1
}

release_url() { # release_url REPO TAG FILE: FILE at the mirror, TAG empty for the latest release
	if [ -n "$2" ]; then
		printf '%s/%s/releases/download/%s/%s' "$MIRROR" "$1" "$2" "$3"
	else
		printf '%s/%s/releases/latest/download/%s' "$MIRROR" "$1" "$3"
	fi
}

asset_url() { # asset_url forkop|core FILE: where FILE of the release is, empty when the release has none
	if [ -n "$MIRROR" ]; then
		if [ "$1" = core ]; then release_url "$CORE_REPO" "$C_TAG" "$2"; else release_url "$FORKOP_REPO" "$F_TAG" "$2"; fi
	else
		jsonfilter -i "$WORK/$1.release" -e "@.assets[@.name=\"$2\"].url" 2>/dev/null
	fi
}

rate_limited() {
	fail 1 rate_limit "$(t 'GitHub refuses more requests from this address for now: it takes 60 an hour without an account' 'GitHub пока не принимает запросы с этого адреса: без входа он даёт 60 запросов в час')" \
		"$(t 'Run the installer again later: the limit is reset within the hour' 'Запустите установщик снова позже: лимит сбрасывается в течение часа')"
}

checksum_of() { # checksum_of NAME SUMS
	awk -v n="$1" '$2 == n || $2 == "*" n { print $1; exit }' "$2"
}

verify() { # verify FILE SUMS: 0 matches, 1 differs, 2 SUMS has no line for it
	local expected
	expected=$(checksum_of "${1##*/}" "$2")
	[ -n "$expected" ] || return 2
	[ "$(sha256sum "$1" | cut -d ' ' -f 1)" = "$expected" ]
}

resolves() { # resolves HOST: an address, or a name the router resolves
	case "$1" in *[!0-9.]*) nslookup "$1" >/dev/null 2>&1 ;; esac
}

network_hint() {
	local host=${MIRROR:-$API_URL}
	host=${host#*://}
	host=${host%%/*}
	host=${host%:*}
	if [ "$FORKOP_ENABLED" = 0 ] && pidof sing-box sing-box-core >/dev/null 2>&1; then
		t 'Another application runs sing-box, and the internet of the router may go through it: stop it and run the installer again' \
			'Работает sing-box другого приложения, и интернет роутера может идти через него: остановите его и запустите установщик снова'
	elif ! resolves "$host"; then
		t 'The router cannot resolve %s: check its DNS and internet connection' 'Роутер не может определить адрес %s: проверьте DNS и подключение к интернету' "$host"
	else
		t 'Check that %s opens from the router' 'Проверьте, открывается ли %s с роутера' "$host"
	fi
}

# --- the system -----------------------------------------------------------------------------

pick_language() {
	local lang="$LANG_OPT"
	[ -n "$lang" ] || lang=$(uci -q get luci.main.lang 2>/dev/null)
	case "$lang" in
	'' | auto | ru | ru_* | ru-*) RU=1 ;;
	esac
}

setup_output() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
		C_STEP=$(printf '\033[1;36m') C_OK=$(printf '\033[1;32m') C_WARN=$(printf '\033[1;33m')
		C_ERR=$(printf '\033[1;31m') C_BOLD=$(printf '\033[1m') C_OFF=$(printf '\033[0m')
	fi
	if ( : </dev/tty ) 2>/dev/null; then
		INTERACTIVE=1
	fi
}

detect_package_manager() {
	if command -v apk >/dev/null 2>&1; then
		PM=apk EXT=apk PM_DB=/lib/apk/db/installed
	elif command -v opkg >/dev/null 2>&1; then
		PM=opkg EXT=ipk PM_DB=/usr/lib/opkg/status
	else
		fail 1 no_package_manager "$(t 'Neither opkg nor apk is installed' 'Не найден ни opkg, ни apk')"
	fi
}

pm_works() {
	if [ "$PM" = apk ]; then apk info >/dev/null 2>&1; else opkg list-installed >/dev/null 2>&1; fi
}

lock() {
	local pid
	mkdir -p "${LOCK_DIR%/*}"
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			fail 1 locked "$(t 'Another installer is running (PID %s)' 'Уже работает другой установщик (PID %s)' "$pid")"
		fi
		rm -rf "$LOCK_DIR"
		mkdir "$LOCK_DIR" || fail 1 locked "$(t 'Cannot take %s' 'Не удалось занять %s' "$LOCK_DIR")"
	fi
	echo "$$" >"$LOCK_DIR/pid"
	LOCKED=1
}

package_arch() { # what packages are built for: apk --print-arch names its own build, aarch64 for aarch64_cortex-a53
	if [ "$PM" = apk ]; then
		cat /etc/apk/arch 2>/dev/null
	else
		opkg print-architecture 2>/dev/null |
			awk '$1 == "arch" && $2 != "all" && $2 != "noarch" && $3 + 0 > p { p = $3 + 0; a = $2 } END { print a }'
	fi
}

unbuilt_reason() { # why no sing-box-forkop exists for architecture $1
	case "$1" in
	arm_fa526) t 'ARMv4 is too old' 'ARMv4 слишком старый' ;;
	armeb_xscale) t 'big-endian ARM is not supported' 'ARM с обратным порядком байт не поддерживается' ;;
	powerpc_464fp | powerpc_8548) t '32-bit PowerPC is not supported' '32-битный PowerPC не поддерживается' ;;
	powerpc64_e5500) t 'the e5500 is too old, POWER8 or newer is needed' 'e5500 слишком старый, нужен POWER8 или новее' ;;
	esac
}

identify_system() {
	RELEASE=$(openwrt_value DISTRIB_RELEASE)
	ARCH=$(package_arch)
	[ -n "$ARCH" ] || ARCH=$(openwrt_value DISTRIB_ARCH)
	printf '%s%s%s · OpenWrt %s · %s\n\n' "$C_STEP" "$(t 'Forkop installer' 'Установщик Forkop')" "$C_OFF" "${RELEASE:-?}" "${ARCH:-?}"
}

check_system() {
	local major minor reason ram year servers server waited=0
	major=${RELEASE%%.*}
	minor=${RELEASE#*.}
	minor=${minor%%.*}
	minor=${minor%%-*}
	case "$RELEASE" in
	*SNAPSHOT*) ;;
	*)
		if ! is_number "$major" || ! is_number "$minor" || [ "$major" -lt 24 ] ||
			{ [ "$major" -eq 24 ] && [ "$minor" -lt 10 ]; }; then
			fail 1 unsupported_openwrt "$(t 'Forkop needs OpenWrt 24.10 or newer' 'Для Forkop нужна OpenWrt 24.10 или новее')"
		fi
		;;
	esac
	reason=$(unbuilt_reason "$ARCH")
	[ -z "$reason" ] || fail 1 unsupported_arch "$(t 'Forkop does not run on this processor: %s' 'Forkop не работает на этом процессоре: %s' "$reason")"
	grep -q ' /overlay ' /proc/mounts && FLASH_MOUNT=/overlay
	FLASH_FS=$(awk -v m="$FLASH_MOUNT" '$2 == m { t = $3 } END { print t }' /proc/mounts)
	ram=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
	log "OpenWrt $RELEASE, $ARCH, $PM; flash $(free_kb "$FLASH_MOUNT") KB free ($FLASH_FS); RAM $ram MB, $(mem_available_kb) KB available"
	if [ "$ram" -lt 100 ] 2>/dev/null; then
		warn low_memory "$(t 'Forkop needs about 128 MB of RAM, and this router has %s MB' 'Для Forkop нужно около 128 МБ оперативной памяти, а у роутера %s МБ' "$ram")"
	fi

	year=$(date +%Y)
	if [ "$year" -lt 2025 ] 2>/dev/null; then
		servers=$(uci -q get system.ntp.server)
		set --
		for server in ${servers:-0.openwrt.pool.ntp.org 1.openwrt.pool.ntp.org}; do set -- "$@" -p "$server"; done
		deadline 20 ntpd -n -q "$@" >>"$LOG" 2>&1
		if [ "$(date +%Y)" -ge 2025 ]; then
			info "$(t 'The clock was wrong and is set now: %s' 'Часы роутера выставлены: %s' "$(date '+%Y-%m-%d %H:%M')")"
		else
			warn clock "$(t 'The clock reads %s and could not be set: downloads may fail' 'Часы роутера показывают %s и не выставились: загрузка может не пройти' "$(date '+%Y-%m-%d')")"
		fi
	fi

	while pidof opkg apk >/dev/null 2>&1; do
		[ "$waited" = 0 ] && step wait "$(t 'Waiting for another %s' 'Ожидание другого %s' "$PM")"
		[ "$waited" -lt 120 ] || fail 1 locked "$(t '%s has been busy for two minutes' '%s занят уже две минуты' "$PM")" \
			"$(t 'Let it finish and run the installer again' 'Дождитесь, пока он закончит, и запустите установщик снова')"
		sleep 2
		waited=$((waited + 2))
	done
	pm_works || fail 1 package_manager "$(t '%s does not work' '%s не работает' "$PM")" \
		"$(t 'Its database may be damaged: %s' 'Возможно, повреждена его база %s' "$PM_DB")"
}

# --- what is installed ----------------------------------------------------------------------

forkop_status() { # running or enabled, from the installed Forkop
	local status
	[ -x /etc/init.d/forkop ] && /etc/init.d/forkop enabled 2>/dev/null && FORKOP_ENABLED=1
	[ -x /usr/bin/forkop ] || return 0
	status=$(deadline 15 /usr/bin/forkop get_status 2>/dev/null)
	log "forkop get_status: $status"
	case "$(printf '%s' "$status" | jsonfilter -e '@.running' 2>/dev/null)" in 1 | true) FORKOP_RUNNING=1 ;; esac
	# get_status counts a core that started less than two seconds ago, or a capture being set up
	# again, as stopped; procd runs Forkop's core as its sing-box service all the same
	if [ "$FORKOP_RUNNING" = 0 ] && [ "$FORKOP_ENABLED" = 1 ] &&
		ubus call service list '{"name":"sing-box"}' 2>/dev/null | jsonfilter -e '@["sing-box"].instances[*].running' 2>/dev/null | grep -q true; then
		FORKOP_RUNNING=1
	fi
	log "forkop: enabled $FORKOP_ENABLED, running $FORKOP_RUNNING"
}

read_state() {
	local name file owner
	refresh_db
	FORKOP_OLD=$(pkg_version forkop)
	# every release of Forkop names this project; a fork built under its package names names its own
	FORK_URL=$(pkg_url forkop)
	[ -n "$FORKOP_OLD" ] && [ "$FORK_URL" != "https://github.com/$FORKOP_REPO" ] || FORK_URL=''
	APP_OLD=$(pkg_version luci-app-forkop)
	I18N_OLD=$(pkg_version luci-i18n-forkop-ru)
	CORE_OLD=$(pkg_version sing-box-forkop)
	[ -z "$CORE_OLD" ] || CORE_OLD_VARIANT=$(cat /usr/share/sing-box-forkop/variant 2>/dev/null)
	[ ! -f /etc/config/forkop ] || CONFIG_VERSION=$(uci -q get forkop.settings.config_version)
	forkop_status

	for name in $FOREIGN_CORES; do
		if [ -n "$(pkg_version "$name")" ]; then
			FOREIGN_PKGS="$FOREIGN_PKGS $name"
		elif in_world "$name"; then
			FOREIGN_WORLD="$FOREIGN_WORLD $name"
		fi
	done
	for file in $FOREIGN_CORE_FILES; do
		[ -e "$file" ] || continue
		# sing-box-forkop installs these itself, and an opkg run that ran out of space cuts its file list
		[ -z "$CORE_OLD" ] || case "$file" in /usr/bin/sing-box | /etc/init.d/sing-box) continue ;; esac
		owner=$(file_owner "$file")
		[ -n "$owner" ] || FOREIGN_FILES="$FOREIGN_FILES $file"
	done
	for file in $LEGACY_FILES; do
		[ ! -e "$file" ] || LEFTOVERS="$LEFTOVERS $file"
	done
	owner=$(file_owner /usr/bin/sing-box)
	if [ -n "$owner" ] && ! contains "$owner" "$OUR_PACKAGES $FOREIGN_PKGS"; then
		FOREIGN_PKGS="$FOREIGN_PKGS $owner"
	fi
	log "installed: forkop ${FORKOP_OLD:-none}${FORK_URL:+ from $FORK_URL}, sing-box-forkop ${CORE_OLD:-none} ${CORE_OLD_VARIANT}," \
		"other cores:${FOREIGN_PKGS:- none}, files of no package:${FOREIGN_FILES:- none}, config ${CONFIG_VERSION:-none}"
}

# --- the releases ---------------------------------------------------------------------------

read_manifest() { # read_manifest FILE NAME: prints version, tag and requirement, one per line
	local name schema
	name=$(jsonfilter -i "$1" -e '@.name' 2>/dev/null)
	schema=$(jsonfilter -i "$1" -e '@.schema' 2>/dev/null)
	[ "$name" = "$2" ] && [ "$schema" = 1 ] || return 1
	jsonfilter -i "$1" -e '@.version' 2>/dev/null || return 1
	jsonfilter -i "$1" -e '@.tag' 2>/dev/null || echo
	if [ "$2" = forkop ]; then
		jsonfilter -i "$1" -e '@.requires["sing-box-forkop"]' 2>/dev/null || echo
	else
		jsonfilter -i "$1" -e '@.requires.forkop' 2>/dev/null || echo
	fi
}

fetch_or_fail() { # fetch_or_fail URL FILE NAME RELEASE: a file of a release, or the reason it is not there
	local status=2
	[ -z "$1" ] || { download "$1" "$2" application/octet-stream; status=$?; }
	case $status in
	0) return 0 ;;
	2) fail 1 release "$(t 'Release %s has no %s' 'В релизе %s нет %s' "$4" "$3")" ;;
	3) rate_limited ;;
	esac
	fail 1 network "$(t 'Cannot download %s' 'Не удалось скачать %s' "$3")" "$(network_hint)"
}

fetch_release() { # fetch_release forkop|core: the latest release's manifest, and from the API its files
	local repo=$FORKOP_REPO name=Forkop package=forkop manifest="$WORK/$1.json" url status=0
	[ "$1" = forkop ] || repo=$CORE_REPO name=sing-box-forkop package=sing-box-forkop
	if [ -z "$MIRROR" ]; then
		download "$API_URL/repos/$repo/releases/latest" "$WORK/$1.release"
		status=$?
	fi
	if [ "$status" = 0 ]; then
		url=$(asset_url "$1" release.json)
		status=2
		[ -z "$url" ] || { download "$url" "$manifest" application/octet-stream; status=$?; }
	fi
	case $status in
	0) ;;
	2)
		fail 1 release "$(t 'The latest %s release has no release.json' 'В последнем релизе %s нет release.json' "$name")" \
			"$(t 'Download the latest install.sh' 'Скачайте свежий install.sh')"
		;;
	3) rate_limited ;;
	*) fail 1 network "$(t 'Cannot download the information on the %s release' 'Не удалось скачать сведения о релизе %s' "$name")" "$(network_hint)" ;;
	esac
	read_manifest "$manifest" "$package" >"$WORK/$1.fields" ||
		fail 1 release "$(t 'Cannot read the information on the %s release' 'Не удалось прочитать сведения о релизе %s' "$name")" \
			"$(t 'Download the latest install.sh' 'Скачайте свежий install.sh')"
	if [ "$1" = forkop ]; then
		{
			read -r F_VERSION
			read -r F_TAG
			read -r F_CORE_MIN
		} <"$WORK/forkop.fields"
		F_TAG=${F_TAG:-$F_VERSION}
	else
		{
			read -r C_VERSION
			read -r C_TAG
			read -r C_FORKOP_MIN
		} <"$WORK/core.fields"
		C_TAG=${C_TAG:-v$C_VERSION}
	fi
}

resolve_release() {
	step release "$(t 'Looking for the latest version' 'Поиск последней версии')"
	fetch_release forkop
	fetch_release core
	decide_forkop
	decide_core
	ask_translation
	[ "$ASKED" = 0 ] || printf '\n' >/dev/tty
	# opkg keeps an installed package of the version it is given and refuses an older one: a fork's
	# go and Forkop's come in, whatever versions the fork took
	[ -z "$FORK_URL" ] || OPKG_FLAGS='--force-downgrade --force-reinstall'
}

decide_forkop() { # the Forkop packages to install, NEED_*, and the Forkop that will run
	if [ -n "$FORKOP_OLD" ]; then
		[ -z "$I18N_OLD" ] || I18N=1
	else
		# a first install brings the page's Russian translation unless LuCI is set to another language
		case "$(uci -q get luci.main.lang)" in '' | auto | ru*) I18N=1 ;; esac
	fi
	RESULT_FORKOP=$F_VERSION
	if [ -n "$FORK_URL" ]; then
		# a fork goes whatever its version says: Forkop's packages take its place
		NEED_FORKOP=1 NEED_APP=1 NEED_I18N=$I18N
		return 0
	fi
	if [ -n "$FORKOP_OLD" ] && [ "$(vercmp "$FORKOP_OLD" "$F_VERSION")" = 1 ]; then
		info "$(t 'forkop %s is newer than the latest release %s and stays' 'forkop %s новее последнего релиза %s и остаётся' "$FORKOP_OLD" "$F_VERSION")"
		RESULT_FORKOP=$FORKOP_OLD
		F_CORE_MIN=$(core_requirement "$(pkg_depends forkop)")
		return 0
	fi
	# the page and its translation go with the backend they talk to
	[ "$FORKOP_OLD" = "$F_VERSION" ] || NEED_FORKOP=1
	[ "$NEED_FORKOP" = 0 ] && [ "$APP_OLD" = "$F_VERSION" ] || NEED_APP=1
	[ "$I18N" = 0 ] || { [ "$NEED_APP" = 0 ] && [ "$I18N_OLD" = "$F_VERSION" ]; } || NEED_I18N=1
}

decide_core() { # the build, the core release and whether the core is installed
	local order text
	if [ -n "$VARIANT" ]; then
		CORE_VARIANT=$VARIANT
	elif [ -n "$CORE_OLD" ]; then
		case "$CORE_OLD_VARIANT" in base | full | tiny) CORE_VARIANT=$CORE_OLD_VARIANT ;; *) CORE_VARIANT=custom ;; esac
		[ "$ASK_VARIANT" = 0 ] || [ "$CORE_VARIANT" = custom ] || choose_variant
	else
		CORE_VARIANT=base
		! may_ask || choose_variant
	fi
	if [ "$CORE_VARIANT" = custom ]; then
		if [ -n "$F_CORE_MIN" ] && older "$CORE_OLD" "$F_CORE_MIN"; then
			text=$(t 'The custom build of sing-box-forkop %s is too old: forkop %s needs %s or newer' 'Кастомная сборка sing-box-forkop %s слишком старая: forkop %s требует %s или новее' "$CORE_OLD" "$RESULT_FORKOP" "$F_CORE_MIN")
			may_ask || fail 1 incompatible "$text" "$(t 'Install an official build: --variant base, full or tiny' 'Поставьте официальную сборку: --variant base, full или tiny')"
			warn custom_outdated "$text"
			choose_variant
		elif older "$CORE_OLD" "$C_VERSION"; then
			warn custom_outdated "$(t 'The custom build of sing-box-forkop %s is outdated: %s is available' 'Кастомная сборка sing-box-forkop %s устарела: доступна %s' "$CORE_OLD" "$C_VERSION")"
			! may_ask || choose_variant "$CORE_OLD"
		elif [ "$ASK_VARIANT" = 1 ]; then
			choose_variant "$CORE_OLD"
		fi
	fi
	if [ "$CORE_VARIANT" = custom ]; then
		RESULT_CORE=$CORE_OLD RESULT_VARIANT=custom
		return 0
	fi
	RESULT_CORE=$C_VERSION RESULT_VARIANT=$CORE_VARIANT
	if [ -z "$CORE_OLD" ]; then
		CORE_ACTION=install
	else
		order=$(vercmp "$CORE_OLD" "$C_VERSION")
		if [ "$order" = 1 ]; then
			info "$(t 'sing-box-forkop %s is newer than the latest release %s and stays' 'sing-box-forkop %s новее последнего релиза %s и остаётся' "$CORE_OLD" "$C_VERSION")"
			RESULT_CORE=$CORE_OLD RESULT_VARIANT=$CORE_OLD_VARIANT
		elif [ "$order" != 0 ] || [ "$CORE_VARIANT" != "$CORE_OLD_VARIANT" ]; then
			CORE_ACTION=install
			[ "$order" != 0 ] || CORE_REINSTALL=1
		fi
	fi
	check_compatible
}

check_compatible() { # the Forkop and the core that will run work together
	# what a core needs of Forkop only its release says
	if [ "$RESULT_CORE" = "$C_VERSION" ] && [ -n "$C_FORKOP_MIN" ] && older "$RESULT_FORKOP" "$C_FORKOP_MIN"; then
		fail 1 incompatible "$(t 'sing-box-forkop %s needs forkop %s or newer, and forkop %s would run' 'sing-box-forkop %s требует forkop %s или новее, а будет forkop %s' "$C_VERSION" "$C_FORKOP_MIN" "$RESULT_FORKOP")"
	fi
	if [ -n "$F_CORE_MIN" ] && older "$RESULT_CORE" "$F_CORE_MIN"; then
		fail 1 incompatible "$(t 'forkop %s needs sing-box-forkop %s or newer, and the latest is %s' 'forkop %s требует sing-box-forkop %s или новее, а последний релиз — %s' "$RESULT_FORKOP" "$F_CORE_MIN" "$C_VERSION")" \
			"$(t 'That release is not out yet: run the installer later' 'Этот релиз ещё не вышел, запустите установщик позже')"
	fi
}

stop_if_current() { # nothing to install: the installed versions, and the run ends
	[ "$NEED_FORKOP$NEED_APP$NEED_I18N" = 000 ] && [ "$CORE_ACTION" = none ] || return 0
	info "$(t 'Up to date: forkop %s, sing-box-forkop %s (%s)' 'Обновлений нет: forkop %s, sing-box-forkop %s (%s)' "$RESULT_FORKOP" "$RESULT_CORE" "$RESULT_VARIANT")"
	finish 0
}

# --- getting the packages -------------------------------------------------------------------

core_file() { # core_file VARIANT
	printf 'sing-box-forkop_%s_%s_%s.%s' "$C_VERSION" "$1" "$ARCH" "$EXT"
}

get_package() { # get_package forkop|core FILE: GOT is FILE of that release, checked against its SHA256SUMS
	local sums="$WORK/$1.sums" file="$WORK/$2" url name="Forkop $F_VERSION"
	[ "$1" = forkop ] || name="sing-box-forkop $C_VERSION"
	[ -s "$sums" ] || fetch_or_fail "$(asset_url "$1" SHA256SUMS)" "$sums" SHA256SUMS "$name"
	if [ -z "$(checksum_of "$2" "$sums")" ]; then
		[ "$1" = forkop ] || fail 1 release "$(t 'Release sing-box-forkop %s has no %s build for %s' 'В релизе sing-box-forkop %s нет сборки %s для %s' "$C_VERSION" "$CORE_VARIANT" "$ARCH")"
		fail 1 release "$(t 'Release %s has no %s' 'В релизе %s нет %s' "$name" "$2")"
	fi
	url=$(asset_url "$1" "$2")
	fetch_or_fail "$url" "$file" "$2" "$name"
	if ! verify "$file" "$sums"; then
		if ! download "$url" "$file" application/octet-stream || ! verify "$file" "$sums"; then
			fail 1 checksum "$(t '%s is damaged: its SHA256 sum does not match' 'Файл %s повреждён: сумма SHA256 не совпадает' "$2")"
		fi
	fi
	info "$(t 'Downloaded %s' 'Загружен %s' "$2")"
	GOT=$file
}

need_ram_kb() { # what the run puts in RAM while Forkop still runs: the downloads, the core's as the largest
	# package of its build, and the largest of the checks run beside them
	local kb=6144
	[ "$NEED_FORKOP$NEED_APP$NEED_I18N" = 000 ] || kb=$((kb + 1024))
	if [ "$CORE_ACTION" = install ]; then
		case "$CORE_VARIANT" in full) kb=$((kb + 24576)) ;; tiny) kb=$((kb + 11264)) ;; *) kb=$((kb + 13312)) ;; esac
	fi
	echo "$kb"
}

enough_ram() { # enough_ram KB downloads|dependencies: the run stops here unless RAM and /tmp have KB
	local free text
	free=$(mem_available_kb)
	[ "$(free_kb /tmp)" -ge "$free" ] 2>/dev/null || free=$(free_kb /tmp)
	log "ram for the $2: $1 KB needed, $free KB free"
	[ "$free" -lt "$1" ] 2>/dev/null || return 0
	if [ "$2" = downloads ]; then
		text=$(t 'Not enough RAM for the downloads: %s MB needed, %s MB free' 'Не хватает оперативной памяти для загрузки: нужно %s МБ, свободно %s МБ' "$(mb "$1")" "$(mb "$free")")
	else
		text=$(t 'Not enough RAM to install the dependencies: %s MB needed, %s MB free' 'Не хватает оперативной памяти для установки зависимостей: нужно %s МБ, свободно %s МБ' "$(mb "$1")" "$(mb "$free")")
	fi
	[ "$FORKOP_RUNNING" = 0 ] || fail 1 no_memory "$text" \
		"$(t 'Stop Forkop: /etc/init.d/forkop stop' 'Остановите Forkop: /etc/init.d/forkop stop')" \
		"$(t 'Run the installer again, then start Forkop: /etc/init.d/forkop start' 'Запустите установщик снова, затем Forkop: /etc/init.d/forkop start')"
	fail 1 no_memory "$text" "$(t 'Free some RAM and run the installer again' 'Освободите память и запустите установщик снова')"
}

download_packages() {
	enough_ram "$(need_ram_kb)" downloads
	step download "$(t 'Downloading the packages' 'Загрузка пакетов')"
	if [ "$NEED_FORKOP" = 1 ]; then
		get_package forkop "forkop_${F_VERSION}_all.$EXT"
		FILE_FORKOP=$GOT
	fi
	if [ "$NEED_APP" = 1 ]; then
		get_package forkop "luci-app-forkop_${F_VERSION}_all.$EXT"
		FILE_APP=$GOT
	fi
	if [ "$NEED_I18N" = 1 ]; then
		get_package forkop "luci-i18n-forkop-ru_${F_VERSION}_all.$EXT"
		FILE_I18N=$GOT
	fi
	if [ "$CORE_ACTION" = install ]; then
		get_package core "$(core_file "$CORE_VARIANT")"
		FILE_CORE=$GOT
	fi
}

# --- checks ---------------------------------------------------------------------------------

check_packages() {
	step check "$(t 'Checking the packages' 'Проверка пакетов')"
	plan_removals
	check_dependencies
	plan_ip_swap
	check_space
	check_config
	preflight
}

# apk keeps an ip-full an older Forkop pulled in, as it is the new one's ip: ip-tiny replaces it
plan_ip_swap() {
	local depends file
	[ "$PM" = apk ] && [ -n "$(pkg_version ip-full)" ] && ! in_world ip-full && [ -z "$(needed_by ip-full)" ] || return 0
	if [ -n "$FILE_FORKOP" ]; then depends=$(field "$(control_of "$FILE_FORKOP")" Depends); else depends=$(pkg_depends forkop); fi
	contains ip "$(dep_names "$depends" | tr '\n' ' ')" || return 0
	# apk reads the feed indexes to fetch it, as for a dependency, and fetches none on its own
	if [ "$(mem_available_kb)" -lt 19456 ] 2>/dev/null; then
		log "ip-full stays: too little RAM to fetch ip-tiny"
		return 0
	fi
	[ -n "$DEPS_MISSING" ] || run apk update
	run apk fetch -o "$WORK" ip-tiny
	for file in "$WORK"/ip-tiny-*.apk; do [ ! -f "$file" ] || FILE_IP=$file; done
	[ -n "$FILE_IP" ] || log "ip-full stays: ip-tiny was not fetched"
}

check_dependencies() { # what the feeds give of DEPS_MISSING, simulated: DEPS_KB of it installed
	local out="$WORK/deps" hint=''
	[ -n "$DEPS_MISSING" ] || return 0
	# the feed indexes, the package manager reading them and, for opkg, the packages its
	# simulation downloads, beside the downloads already in /tmp
	if [ "$PM" = apk ]; then enough_ram 19456 dependencies; else enough_ram 10240 dependencies; fi
	update_lists
	[ "$LISTS_FAILED" = 0 ] || hint=$(network_hint)
	# shellcheck disable=SC2086
	if [ "$PM" = apk ]; then
		capture "$out" apk add --simulate $DEPS_MISSING
	else
		capture "$out" opkg --noaction install $DEPS_MISSING
	fi || fail 1 check "$(t '%s cannot install %s: %s' '%s не может установить %s: %s' "$PM" "$(commas "$DEPS_MISSING")" "$(pm_errors "$out")")" "$hint"
	DEPS_KB=$(installed_kb "$out")
	log "dependencies: $DEPS_KB KB installed"
}

installed_kb() { # installed_kb SIMULATION: what the packages a simulated installation adds take installed
	local lists
	if [ "$PM" = apk ]; then
		# apk ends with the size of everything installed after it
		awk -v after="$(sed -n 's/^OK: \([0-9.]*\) \([KMG]\)iB in .*/\1 \2/p' "$1" | tail -n 1)" '
			/^I:/ { now += substr($0, 3) }
			END {
				split(after, a, " "); unit = a[2] == "G" ? 1048576 : a[2] == "M" ? 1024 : 1
				kb = a[1] * unit - now / 1024; print (kb > 0 ? int(kb) : 0)
			}' /lib/apk/db/installed
		return
	fi
	# opkg's feed lists give a package's Installed-Size, or only the download Size it takes about
	# three times over installed
	lists=$(awk '$1 == "lists_dir" { print $3 }' /etc/opkg.conf 2>/dev/null)
	for list in "${lists:-/var/opkg-lists}"/*; do
		case "$list" in *.sig) continue ;; esac
		gzip -dc "$list" 2>/dev/null || cat "$list"
	done | awk -v want=" $(sed -n 's/^Installing \([^ ]*\) (.*/\1/p' "$1" | sort -u | tr '\n' ' ') " '
		/^Package: / { name = $2 }
		/^Installed-Size: / && index(want, " " name " ") { installed[name] = $2 }
		/^Size: / && index(want, " " name " ") { size[name] = $2 }
		END { for (name in size) bytes += (name in installed) ? installed[name] : 3 * size[name]; print int(bytes / 1024) }'
}

plan_removals() {
	local name file control
	for file in $FILE_CORE $FILE_FORKOP $FILE_APP $FILE_I18N; do
		control=$(control_of "$file")
		for name in $(dep_names "$(field "$control" Depends)"); do
			contains "$name" "$OUR_PACKAGES $DEPS_MISSING" || provided "$name" || DEPS_MISSING="$DEPS_MISSING $name"
		done
	done
	DEPS_MISSING=${DEPS_MISSING# }
	[ "$CORE_ACTION" = install ] || [ -n "$FOREIGN_PKGS$FOREIGN_FILES" ] || return 0
	REMOVE_PKGS=$(dependents "$FOREIGN_PKGS")
	REMOVE_PKGS=${REMOVE_PKGS% }
	REMOVE_FILES=${FOREIGN_FILES# }
	# a core whose package stays owns these files and goes on running
	[ "$CORE_ACTION" = install ] || [ -z "$CORE_OLD" ] || REMOVE_FILES=''
}

compression() { # percent of its size a package takes on the flash
	case "$FLASH_FS" in ubifs | jffs2) echo 60 ;; *) echo 105 ;; esac
}

check_space() { # whether the packages and their dependencies fit the flash; may plan freeing the old core
	local percent need=0 free credit=0 file size core_credit=0
	percent=$(compression)
	for file in $FILE_FORKOP $FILE_APP $FILE_I18N $FILE_CORE; do
		size=$(field "$(control_of "$file")" Installed-Size)
		is_number "$size" || size=$(($(file_kb "$file") * 1024 * 3))
		need=$((need + size * percent / 100 / 1024))
	done
	need=$((need + DEPS_KB * percent / 100 + 1024))
	for file in $REMOVE_FILES $LEFTOVERS; do
		credit=$((credit + $(upper_kb "$file") * percent / 100))
	done
	if [ "$CORE_ACTION" = install ] && [ -e /usr/bin/sing-box ] && ! contains /usr/bin/sing-box "$REMOVE_FILES"; then
		core_credit=$(($(upper_kb /usr/bin/sing-box) * percent / 100))
		# apk writes the new file beside the old one; opkg deletes first, and so does apk for a
		# package it removes rather than upgrades
		if [ "$PM" = opkg ] || [ -z "$CORE_OLD" ]; then
			credit=$((credit + core_credit))
			core_credit=0
		fi
	fi
	free=$(free_kb "$FLASH_MOUNT")
	log "space: need $need KB, free $free KB, freed before $credit KB, old core $core_credit KB, $FLASH_FS $percent%"
	[ "$need" -le $((free + credit)) ] && return 0
	if [ "$core_credit" -gt 0 ] && [ "$need" -le $((free + credit + core_credit)) ]; then
		PREDELETE_CORE=1
		return 0
	fi
	fail 1 no_space "$(t 'Not enough flash: %s MB needed, %s MB free' 'Не хватает флеш-памяти: нужно %s МБ, свободно %s МБ' "$(mb "$need")" "$(mb $((free + credit + core_credit)))")" \
		"$(t 'Free some space and run the installer again' 'Освободите место и запустите установщик снова')"
}

check_config() { # what the new package does with /etc/config/forkop, from its own migration code
	local root="$WORK/new" verdict='' status=1 note
	[ "$NEED_FORKOP" = 1 ] && [ -f /etc/config/forkop ] || return 0
	# a fork's config follows its own schema under the labels of Forkop's releases
	if [ -n "$FORK_URL" ]; then
		CONFIG_PLAN=reset CONFIG_FROM=foreign CONFIG_REASON=foreign
		return 0
	fi
	if mkdir -p "$root" "$WORK/check" && cp /etc/config/forkop "$WORK/check/forkop"; then
		if [ "$EXT" = apk ]; then
			apk extract --allow-untrusted --no-chown --destination "$root" "$FILE_FORKOP" >>"$LOG" 2>&1
		else
			tar -xzOf "$FILE_FORKOP" ./data.tar.gz 2>/dev/null | tar -xzf - -C "$root" >>"$LOG" 2>&1
		fi
		verdict=$(ucode -L "$root/usr/lib/forkop" "$root/usr/lib/forkop/config/migration.uc" check "$WORK/check/forkop" 2>>"$LOG")
		status=$?
	fi
	log "migration check: $status $verdict"
	CONFIG_PLAN=$(printf '%s' "$verdict" | jsonfilter -e '@.result' 2>/dev/null)
	CONFIG_FROM=$(printf '%s' "$verdict" | jsonfilter -e '@.from' 2>/dev/null)
	CONFIG_REASON=$(printf '%s' "$verdict" | jsonfilter -e '@.reason' 2>/dev/null)
	case "$status:$CONFIG_PLAN" in
	0:migrate | 0:current | 0:reset | 1:fail) ;;
	*)
		CONFIG_PLAN=unknown CONFIG_REASON=unchecked verdict=''
		log "the new package could not check the config in advance"
		;;
	esac
	[ -n "$CONFIG_FROM" ] || CONFIG_FROM=${CONFIG_VERSION:-unknown}
	if [ "$CONFIG_PLAN" = fail ]; then
		fail 1 migration "$(t 'Forkop %s cannot migrate this config: %s' 'Forkop %s не сможет перенести этот конфиг: %s' "$F_VERSION" "$CONFIG_REASON")" \
			"$(t 'Report it in the Forkop chat. To start from a clean config, rename /etc/config/forkop' 'Сообщите об этом в чат Forkop. Чтобы начать с чистого конфига, переименуйте /etc/config/forkop')"
	fi
	# the notes are Forkop's own log lines, in English, which its log keeps: the text output leaves them out
	printf '%s' "$verdict" | jsonfilter -e '@.warnings[*]' 2>/dev/null | while IFS= read -r note; do
		[ -n "$note" ] || continue
		log "migration note: $note"
	done
}

update_lists() { # feed indexes, when a dependency has to come from them
	[ -n "$DEPS_MISSING" ] || return 0
	if ! run "$PM" update; then
		LISTS_FAILED=1
		warn lists "$(t 'Some package lists did not update' 'Часть списков пакетов не обновилась')"
	fi
}

apk_constraints() { # what the world gets for apk to drop the packages that go
	local name
	for name in $REMOVE_PKGS $FOREIGN_WORLD; do
		# sing-box-forkop provides sing-box, so a conflict with that name would be one with itself;
		# left unversioned, the name goes to it instead of the package of that name
		if [ "$name" = sing-box ]; then echo sing-box; else echo "!$name"; fi
	done
}

packages_in_transaction() {
	[ -z "$FILE_CORE" ] || [ "$CORE_REINSTALL" = 1 ] || echo sing-box-forkop
	[ -z "$FILE_FORKOP" ] || echo forkop
	[ -z "$FILE_APP" ] || echo luci-app-forkop
	[ -z "$FILE_I18N" ] || echo luci-i18n-forkop-ru
}

preflight() { # every package manager command apply runs, simulated
	local out="$WORK/preflight" name hint=''
	[ "$LISTS_FAILED" = 0 ] || hint=$(network_hint)
	set --
	for name in "$FILE_CORE" "$FILE_FORKOP" "$FILE_APP" "$FILE_I18N" "$FILE_IP"; do [ -z "$name" ] || set -- "$@" "$name"; done
	if [ "$PM" = apk ]; then
		for name in $(apk_constraints); do set -- "$@" "$name"; done
		# as the transaction runs once the dependencies are in
		# shellcheck disable=SC2086
		[ -n "$DEPS_MISSING" ] || set -- $APK_OFFLINE "$@"
		capture "$out" apk add --simulate --allow-untrusted "$@" ||
			fail 1 check "$(t 'apk refuses to install the packages: %s' 'apk отказывается устанавливать пакеты: %s' "$(pm_errors "$out")")" "$hint"
		return 0
	fi
	if [ -n "$REMOVE_PKGS" ]; then
		# shellcheck disable=SC2046
		capture "$out.remove" opkg --noaction --force-depends remove $(removal_order "$REMOVE_PKGS") ||
			fail 1 check "$(t 'opkg refuses to remove %s: %s' 'opkg отказывается удалить %s: %s' "$(commas "$REMOVE_PKGS")" "$(pm_errors "$out.remove")")"
	fi
	# opkg reports a conflict for a file of a package it would replace when it only pretends
	# to, and returns 0 when it skips a file whose dependencies fail: the output decides
	# shellcheck disable=SC2086
	capture "$out" opkg --noaction --force-depends --force-overwrite --force-space $OPKG_FLAGS install "$@"
	if grep -q -e 'cannot find dependency' -e 'Cannot satisfy' -e 'incompatible with the arch' "$out"; then
		fail 1 check "$(t 'opkg cannot satisfy the dependencies: %s' 'opkg не может удовлетворить зависимости: %s' "$(grep -m 3 -e 'cannot find dependency' -e 'Cannot satisfy' -e incompatible "$out" | tr '\n' ' ')")" "$hint"
	fi
	for name in $(packages_in_transaction); do
		grep -q -e "^Installing $name (" -e "^Upgrading $name on " -e "^Downgrading $name on " -e "^Removing package $name from" "$out" ||
			fail 1 check "$(t 'opkg would not install %s: %s' 'opkg не стал бы устанавливать %s: %s' "$name" "$(pm_errors "$out")")"
	done
}

# --- changes --------------------------------------------------------------------------------

config_copies() { # the copies of /etc/config/forkop there are now, one per line
	ls -d /etc/config/forkop.* 2>/dev/null
}

file_label() { # a config version as the package writes it into the name of a copy
	printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

backup_config() { # a copy that guards the transaction; the package keeps its own where it should
	local copy
	config_copies >"$WORK/copies"
	[ -f /etc/config/forkop ] && [ "$NEED_FORKOP" = 1 ] || return 0
	copy="/etc/config/forkop.$(file_label "${CONFIG_FROM:-unknown}")-$(date +%Y%m%d-%H%M%S)"
	if [ -n "$FORK_URL" ]; then
		# Forkop's package would read a fork's config as one of its own releases: it starts from its defaults
		mv /etc/config/forkop "$copy" 2>>"$LOG" || fail 1 backup "$(t 'Cannot set /etc/config/forkop aside' 'Не удалось отложить /etc/config/forkop')"
	else
		cp -p /etc/config/forkop "$copy" 2>>"$LOG" || fail 1 backup "$(t 'Cannot copy /etc/config/forkop' 'Не удалось скопировать /etc/config/forkop')"
	fi
	BACKUP=$copy
	log "config copy: $BACKUP"
}

install_dependencies() {
	[ -n "$DEPS_MISSING" ] || return 0
	step dependencies "$(t 'Installing dependencies: %s' 'Установка зависимостей: %s' "$(commas "$DEPS_MISSING")")"
	# shellcheck disable=SC2086
	run detached "$PM" "$([ "$PM" = apk ] && echo add || echo install)" $DEPS_MISSING ||
		fail 3 dependencies "$(t 'Cannot install the dependencies; forkop and sing-box-forkop were not touched' 'Не удалось установить зависимости, forkop и sing-box-forkop не тронуты')" "$(network_hint)"
	# shellcheck disable=SC2086
	pulled_in $DEPS_MISSING
	refresh_db
}

stop_cores() {
	local pids try
	for try in 1 2 3 4 5 6 7 8 9 10; do
		pids=$(pidof sing-box sing-box-core 2>/dev/null)
		[ -n "$pids" ] || return 0
		# shellcheck disable=SC2086
		kill $pids 2>/dev/null
		sleep 1
	done
	# shellcheck disable=SC2046
	kill -9 $(pidof sing-box sing-box-core 2>/dev/null) 2>/dev/null
}

stop_services() {
	if [ "$FORKOP_RUNNING" = 1 ]; then
		step stop "$(t 'Stopping Forkop' 'Остановка Forkop')"
	elif pidof sing-box sing-box-core >/dev/null 2>&1; then
		step stop "$(t 'Stopping sing-box' 'Остановка sing-box')"
	fi
	[ ! -x /etc/init.d/forkop ] || deadline 90 /etc/init.d/forkop stop >>"$LOG" 2>&1
	[ ! -x /etc/init.d/sing-box ] || deadline 30 /etc/init.d/sing-box stop >>"$LOG" 2>&1
	stop_cores
}

remove_files() {
	local file
	for file in $REMOVE_FILES; do
		rm -f "$file" && removed "$file"
	done
	for file in $LEFTOVERS; do
		rm -f "$file" && log "removed $file"
	done
}

predelete_core() { # apk upgrades by writing beside the old file: make room first, a compressed copy in RAM
	[ "$PREDELETE_CORE" = 1 ] || return 0
	# /tmp is RAM, and its df counts what tmpfs may grow to: MemAvailable is what is free
	if [ $(($(file_kb /usr/bin/sing-box) / 2 + 16384)) -lt "$(mem_available_kb)" ] &&
		gzip -1 -c /usr/bin/sing-box >"$WORK/sing-box.old.gz" 2>/dev/null; then
		log "a compressed copy of the old core is in RAM until the transaction ends"
	else
		rm -f "$WORK/sing-box.old.gz"
		log "no copy of the old core: RAM is short"
	fi
	rm -f /usr/bin/sing-box
	log "removed the old core to make room for the new one"
}

restore_core() {
	[ "$PREDELETE_CORE" = 1 ] && [ ! -e /usr/bin/sing-box ] && [ -f "$WORK/sing-box.old.gz" ] || return 0
	gzip -dc "$WORK/sing-box.old.gz" >/usr/bin/sing-box && chmod 0755 /usr/bin/sing-box && log "restored the old core"
}

removals() { # "name version" a line: what the transaction takes away, a fork's own packages first
	local name version
	[ -z "$FORK_URL" ] || for name in forkop luci-app-forkop luci-i18n-forkop-ru; do
		version=$(pkg_version "$name")
		[ -z "$version" ] || printf '%s %s\n' "$name" "$version"
	done
	# shellcheck disable=SC2086
	for name in $(printf '%s\n' $REMOVE_PKGS | sort); do
		printf '%s %s\n' "$name" "$(pkg_version "$name")"
	done
}

gone() { # gone LINES: each "name version" of LINES no longer installed
	local name version source
	printf '%s\n' "$1" | while read -r name version; do
		[ -n "$name" ] || continue
		if [ -n "$FORK_URL" ] && contains "$name" "forkop luci-app-forkop luci-i18n-forkop-ru"; then
			# a fork's packages are gone once Forkop's take their place, of the same version or not
			[ "$(pkg_url forkop)" != "$FORK_URL" ] || continue
		else
			[ "$(pkg_version "$name")" != "$version" ] || continue
		fi
		source=''
		[ "$name" != forkop ] || [ -z "$FORK_URL" ] || source=" (${FORK_URL#*://})"
		removed "$name $version$source"
	done
}

dropped() { # dropped LINES: "name version" of each package installed before and gone now, but those of LINES
	awk -F '\t' -v planned="$1" '
		BEGIN { n = split(planned, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, " "); skip[f[1]] = 1 } }
		FILENAME == ARGV[1] { now[$1] = 1; next }
		!($1 in now) && !($1 in skip) { print $1 " " $2 }' "$WORK/db" "$WORK/db.before" | sort
}

orphans() { # orphans NAME...: those of NAMES opkg pulled in beside the image that nothing installed needs
	local rom=/rom/usr/lib/opkg/status
	[ -f "$rom" ] || rom=/dev/null
	awk -F '\t' -v want=" $* " '
		function names(s, out,    n, i, a, w) {
			gsub(/\([^)]*\)/, "", s); gsub(/[,|]/, " ", s)
			n = split(s, a, " ")
			for (i = 1; i <= n; i++) { w = a[i]; sub(/[<>=~].*/, "", w); if (w != "") out[w] = 1 }
		}
		FILENAME == ARGV[1] { if (/^Package: /) image[substr($0, 10)] = 1; next }
		FILENAME == ARGV[2] { if (/^Package: /) p = substr($0, 10); else if ($0 == "Auto-Installed: yes") auto[p] = 1; next }
		{ installed[$1] = 1; provides[$1] = $4; names($3, needed) }
		END {
			n = split(want, w, " ")
			for (i = 1; i <= n; i++) {
				x = w[i]
				if (!(x in installed) || !(x in auto) || (x in image) || (x in needed)) continue
				split("", p); names(provides[x], p); busy = 0
				for (y in p) if (y in needed) busy = 1
				if (!busy) printf "%s ", x
			}
		}' "$rom" /usr/lib/opkg/status "$WORK/db"
}

# what the packages that went pulled in: opkg's upgrade drops only its first level, apk all of it
drop_dependencies() {
	local names
	refresh_db
	# shellcheck disable=SC2046
	names=$(orphans $(awk -F '\t' -v ours=" $OUR_PACKAGES " '
		FILENAME == ARGV[1] { now[$1] = 1; next }
		index(ours, " " $1 " ") || !($1 in now) { print $3 }' "$WORK/db" "$WORK/db.before" |
		while IFS= read -r depends; do dep_names "$depends"; done | sort -u))
	[ -n "$names" ] || return 0
	# shellcheck disable=SC2086
	perform "$WORK/autoremove" detached opkg remove --autoremove $names || log "opkg did not remove all of $names"
}

# a package opkg installs by name is the person's: the dependencies count as pulled in, like apk's
pulled_in() {
	[ "$PM" = opkg ] && [ -n "$*" ] || return 0
	if awk -v names=" $* " '
		/^Package: / { ours = index(names, " " $2 " ") > 0; auto = 0 }
		ours && $0 == "Status: install user installed" { $0 = "Status: install ok installed" }
		ours && $0 == "Auto-Installed: yes" { auto = 1 }
		ours && $0 == "" { if (!auto) print "Auto-Installed: yes"; ours = 0 }
		{ print }
		END { if (ours && !auto) print "Auto-Installed: yes" }' /usr/lib/opkg/status >/usr/lib/opkg/status.forkop; then
		mv /usr/lib/opkg/status.forkop /usr/lib/opkg/status
	else
		rm -f /usr/lib/opkg/status.forkop
	fi
}

transaction() {
	local out="$WORK/transaction" name status=0 order before
	before=$(removals)
	cp "$WORK/db" "$WORK/db.before"
	set --
	for name in "$FILE_CORE" "$FILE_FORKOP" "$FILE_APP" "$FILE_I18N" "$FILE_IP"; do [ -z "$name" ] || set -- "$@" "$name"; done
	if [ "$PM" = apk ]; then
		for name in $(apk_constraints); do set -- "$@" "$name"; done
		# the dependencies are in: the feed indexes would take RAM and the network while Forkop is down
		# shellcheck disable=SC2086
		perform "$out" detached apk add --allow-untrusted $APK_OFFLINE "$@" || status=$?
		# shellcheck disable=SC2046
		world_drop $(apk_constraints)
	else
		cp /usr/lib/opkg/status "$WORK/opkg-status" 2>/dev/null
		if [ -n "$REMOVE_PKGS" ]; then
			order=$(removal_order "$REMOVE_PKGS")
			# what still needs a foreign core's sing-box gets it from sing-box-forkop within this run
			# shellcheck disable=SC2086
			perform "$out.remove" detached opkg --force-depends remove $order || status=$?
		fi
		if [ "$status" = 0 ] && [ "$CORE_REINSTALL" = 1 ] && [ -n "$FILE_CORE" ]; then
			perform "$out.core" detached opkg install --force-reinstall --force-overwrite --force-space "$FILE_CORE" || status=$?
			shift
		fi
		# shellcheck disable=SC2086
		[ "$status" != 0 ] || [ "$#" = 0 ] || perform "$out" detached opkg install --force-overwrite --force-space $OPKG_FLAGS "$@" || status=$?
		[ "$status" != 0 ] || drop_dependencies
	fi
	refresh_db
	gone "$before"
	gone "$(dropped "$before")"
	check_installed "$status"
}

opkg_unpacked() { # opkg left package $1 unpacked: its postinst failed
	[ "$PM" = opkg ] && awk -v p="$1" '/^Package: / { n = $2 } /^Status: / && n == p && / unpacked$/ { found = 1 } END { exit !found }' /usr/lib/opkg/status
}

repair_opkg_db() { # opkg leaves its status file cut short when the flash runs out while it writes
	[ "$PM" = opkg ] && [ -s "$WORK/opkg-status" ] && ! pm_works || return 0
	if cat "$WORK/opkg-status" >/usr/lib/opkg/status 2>>"$LOG" && pm_works; then
		log "restored /usr/lib/opkg/status from before the transaction"
		refresh_db
	else
		OPKG_DB_COPY=/tmp/opkg-status.before-forkop
		cp "$WORK/opkg-status" "$OPKG_DB_COPY" 2>/dev/null
		log "opkg cannot read /usr/lib/opkg/status, and putting it back failed: its copy is $OPKG_DB_COPY"
	fi
}

check_installed() { # what the transaction left, against what it was to install
	local problems='' name reason db_hint=''
	[ -z "$FILE_CORE" ] || [ "$(pkg_version sing-box-forkop)" = "$(field "$(control_of "$FILE_CORE")" Version)" ] || problems="$problems sing-box-forkop"
	[ -z "$FILE_CORE" ] || [ "$(cat /usr/share/sing-box-forkop/variant 2>/dev/null)" = "$CORE_VARIANT" ] || contains sing-box-forkop "$problems" || problems="$problems sing-box-forkop"
	[ -z "$FILE_FORKOP" ] || [ "$(pkg_version forkop)" = "$F_VERSION" ] || problems="$problems forkop"
	[ -z "$FORK_URL" ] || [ "$(pkg_url forkop)" != "$FORK_URL" ] || contains forkop "$problems" || problems="$problems forkop"
	[ -z "$FILE_APP" ] || [ "$(pkg_version luci-app-forkop)" = "$F_VERSION" ] || problems="$problems luci-app-forkop"
	[ -z "$FILE_I18N" ] || [ "$(pkg_version luci-i18n-forkop-ru)" = "$F_VERSION" ] || problems="$problems luci-i18n-forkop-ru"
	[ -z "$FILE_IP" ] || [ -n "$(pkg_version ip-tiny)" ] || problems="$problems ip-tiny"
	for name in $REMOVE_PKGS; do
		[ -z "$(pkg_version "$name")" ] || problems="$problems $name"
	done
	[ -n "$problems" ] || [ "$1" != 0 ] || return 0
	restore_core
	repair_opkg_db
	[ -z "$OPKG_DB_COPY" ] || db_hint=$(t "opkg's database is damaged; its copy from before is %s" 'База opkg повреждена, её копия до установки — %s' "$OPKG_DB_COPY")
	if [ -n "$FILE_FORKOP" ] && { opkg_unpacked forkop || { [ "$(pkg_version forkop)" = "$F_VERSION" ] && [ "$1" != 0 ]; }; }; then
		reason=$(logread -e forkop 2>/dev/null | grep '\[error\]' | tail -n 1 | sed 's/.*\[error\] *//')
		fail 3 transaction "$(t 'Forkop %s is installed, but its setup failed: %s' 'Forkop %s установлен, но не настроился: %s' "$F_VERSION" "${reason:-$(t 'see logread -e forkop' 'см. logread -e forkop')}")" \
			"$(t 'Its config is left as it was. Report it in the Forkop chat with the output of logread -e forkop' 'Конфиг оставлен как был. Сообщите об этом в чат Forkop, приложив вывод logread -e forkop')" \
			"$(start_again)" "$db_hint"
	fi
	fail 3 transaction "$(t 'The installation did not complete: %s' 'Установка не завершилась: %s' "$(commas "$problems")")" \
		"$(t 'Fix the cause the log names and run the installer again' 'Устраните причину из журнала и запустите установщик снова')" \
		"$(start_again)" "$db_hint"
}

start_again() { # after a failed transaction a Forkop that ran before runs again on what is installed now
	[ "$FORKOP_RUNNING" = 1 ] && [ -x /etc/init.d/forkop ] || return 0
	if deadline 150 /etc/init.d/forkop start >>"$LOG" 2>&1; then
		t 'Forkop runs again' 'Forkop снова запущен'
	else
		t 'Forkop did not start again: logread -e forkop' 'Forkop не запустился снова: logread -e forkop'
	fi
}

clean_up_after() {
	local file
	for file in $CONFFILE_COPIES; do
		[ ! -e "$file" ] || rm -f "$file"
	done
	if [ -n "$BACKUP" ] && [ -z "$FORK_URL" ]; then
		rm -f "$BACKUP" && log "removed $BACKUP: the transaction went through"
	fi
	# what the package set aside: it keeps a config it replaces, and one it migrated past the label
	BACKUP=$(config_copies | awk -v before="$WORK/copies" 'BEGIN { while ((getline line < before) > 0) seen[line] = 1 } !($0 in seen)' | tail -n 1)
	# shellcheck disable=SC2086
	[ "$PM" != apk ] || [ -z "$DEPS_MISSING" ] || world_drop $DEPS_MISSING
	# a package added from its file stays in the world pinned to it
	[ -z "$FILE_IP" ] || world_drop "$(grep '^ip-tiny><' /etc/apk/world)"
	# /tmp is RAM, which the start of Forkop needs more than these files
	rm -rf "$WORK/new" "$WORK/sing-box.old.gz"
	for file in "$FILE_FORKOP" "$FILE_APP" "$FILE_I18N" "$FILE_CORE" "$FILE_IP"; do
		[ -z "$file" ] || rm -f "$file"
	done
}

forkop_up() { # start Forkop and wait for it to run: 0 once it does
	local waited=0
	deadline 150 /etc/init.d/forkop start >>"$LOG" 2>&1
	while :; do
		case "$(deadline 15 /usr/bin/forkop get_status 2>/dev/null | jsonfilter -e '@.running' 2>/dev/null)" in 1 | true) return 0 ;; esac
		[ "$waited" -lt 30 ] || return 1
		sleep 3
		waited=$((waited + 3))
	done
}

start_forkop() { # a Forkop that ran before runs again, unless its config starts clean and has nothing to run
	local pid exe hint
	[ -x /etc/init.d/forkop ] || return 0
	[ "$FORKOP_ENABLED" = 0 ] || run /etc/init.d/forkop enable
	[ "$FORKOP_RUNNING" = 1 ] || return 0
	! clean_config || return 0
	step start "$(t 'Starting Forkop' 'Запуск Forkop')"
	hint=$(t 'Details: logread -e forkop' 'Подробности: logread -e forkop')
	forkop_up || fail 4 service "$(t 'Forkop is installed but did not start: %s' 'Forkop установлен, но не запустился: %s' \
		"$(logread -e forkop 2>/dev/null | grep -i error | tail -n 1 | sed 's/.*\]: //; s/^\[error\] *//')")" "$hint"
	pid=$(pidof sing-box | awk '{ print $1 }')
	exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
	if [ -z "$pid" ] || [ "$exe" != /usr/bin/sing-box ]; then
		fail 4 service "$(t 'Forkop runs, but sing-box does not' 'Forkop работает, а sing-box — нет')" "$hint"
	fi
	STARTED=1
}

clean_config() { # Forkop's config is the package's own default, which has nothing to run
	cmp -s /etc/config/forkop /usr/share/forkop/default-config
}

package_names() { # the packages the transaction installs, by name
	local file names=''
	for file in $FILE_FORKOP $FILE_APP $FILE_I18N $FILE_CORE; do
		file=${file##*/}
		names="${names:+$names, }${file%%_*}"
	done
	[ -z "$FILE_IP" ] || names="$names, ip-tiny"
	printf '%s' "$names"
}

apply() {
	trap '' INT TERM HUP PIPE
	backup_config
	install_dependencies
	stop_services
	remove_files
	predelete_core
	step install "$(t 'Installing packages: %s' 'Установка пакетов: %s' "$(package_names)")"
	transaction
	clean_up_after
	start_forkop
	summary
}

finale() { # the closing line, set apart: what the run achieved
	log "done: $1"
	printf '\n%s%s%s\n' "$C_OK" "$(t 'Done! %s' 'Готово! %s' "$1")" "$C_OFF" 2>/dev/null
}

summary() {
	local result runs
	runs=$(t ' and running' ' и запущен')
	if [ -n "$FORK_URL" ] || [ -z "$FORKOP_OLD" ]; then
		result=$(t 'Forkop %s is installed' 'Forkop %s установлен' "$RESULT_FORKOP")
	elif [ "$NEED_FORKOP" = 1 ]; then
		result=$(t 'Forkop is updated to %s' 'Forkop обновлён до %s' "$RESULT_FORKOP")
	elif [ "$CORE_ACTION" = install ]; then
		if [ -n "$CORE_OLD" ] && [ "$CORE_REINSTALL" = 0 ]; then
			result=$(t 'sing-box-forkop is updated to %s (%s)' 'sing-box-forkop обновлён до %s (%s)' "$RESULT_CORE" "$RESULT_VARIANT")
		else
			result=$(t 'sing-box-forkop %s (%s) is installed' 'sing-box-forkop %s (%s) установлен' "$RESULT_CORE" "$RESULT_VARIANT")
		fi
		runs=$(t ', Forkop is running' ', Forkop запущен')
	else
		result=$(t 'Forkop %s is installed' 'Forkop %s установлен' "$RESULT_FORKOP")
	fi
	[ "$STARTED" = 1 ] || runs=''
	! starts_over || runs="$runs$(t '. Set it up in LuCI: Services → Forkop' '. Настройте его в LuCI: Службы → Forkop')"
	finale "$result$runs"
	finish 0
}

starts_over() { # Forkop starts from its default config: a first install, a config it could not keep, a fork's
	{ [ -z "$FORKOP_OLD" ] || [ -n "$FORK_URL" ] || [ "$CONFIG_PLAN" = reset ]; } && clean_config
}

# --- removal --------------------------------------------------------------------------------

uninstall() {
	local packages='' name file out="$WORK/remove" before='' users
	refresh_db
	# podkop and the like stay beside Forkop on its core, which provides sing-box: the core goes with them
	users=$(needed_by sing-box-forkop "$CORE_PROVIDES")
	for name in luci-i18n-forkop-ru luci-app-forkop forkop sing-box-forkop; do
		[ -n "$(pkg_version "$name")" ] || continue
		[ "$name" != sing-box-forkop ] || [ -z "$users" ] || continue
		packages="$packages $name"
		before="$before$name $(pkg_version "$name")
"
	done
	packages=${packages# }
	if [ -z "$packages" ]; then
		info "$(t 'Forkop is not installed' 'Forkop не установлен')"
		finish 0
	fi
	if [ "$PURGE" = 0 ] && may_ask; then
		ask "$(t 'Delete the settings of Forkop too?' 'Удалить и настройки Forkop?')" && PURGE=1
		printf '\n' >/dev/tty
	fi
	trap '' INT TERM HUP PIPE
	step remove "$(t 'Removing the packages' 'Удаление пакетов')"
	[ ! -x /etc/init.d/forkop ] || deadline 90 /etc/init.d/forkop stop >>"$LOG" 2>&1
	# a core that stays goes on running for what needs it
	[ -n "$users" ] || [ ! -x /etc/init.d/sing-box ] || deadline 30 /etc/init.d/sing-box stop >>"$LOG" 2>&1
	cp "$WORK/db" "$WORK/db.before"
	# shellcheck disable=SC2086
	if [ "$PM" = apk ]; then
		perform "$out" detached apk del $APK_OFFLINE $packages
	else
		perform "$out" detached opkg remove $packages && drop_dependencies
	fi
	# opkg leaves the directories it emptied
	find /usr/lib/forkop /usr/share/forkop /usr/share/sing-box-forkop /www/luci-static/resources/view/forkop -type d 2>/dev/null |
		sort -r | while read -r dir; do rmdir "$dir" 2>/dev/null; done
	refresh_db
	before=$(printf '%s' "$before" | sort)
	gone "$before"
	gone "$(dropped "$before")"
	for name in $packages; do
		[ -z "$(pkg_version "$name")" ] ||
			fail 3 transaction "$(t '%s was not removed: %s' 'Пакет %s не удалён: %s' "$name" "$(pm_errors "$out")")"
	done
	[ -z "$users" ] || [ -z "$(pkg_version sing-box-forkop)" ] ||
		warn core_kept "$(t 'sing-box-forkop stays for %s' 'sing-box-forkop остаётся для %s' "$(commas "$users")")"
	if [ "$PURGE" = 1 ]; then
		for file in /etc/config/forkop /etc/config/forkop.* /etc/config/forkop-opkg /etc/forkop; do
			[ ! -e "$file" ] || rm -rf "$file"
		done
		[ -n "$users" ] || for file in /etc/config/sing-box /etc/config/sing-box-opkg /etc/sing-box; do
			[ ! -e "$file" ] || rm -rf "$file"
		done
	fi
	finale "$(t 'Forkop is removed' 'Forkop удалён')"
	finish 0
}

# --- main -----------------------------------------------------------------------------------

parse_args() { # BAD_ARG names the first mistake, reported once the language is known
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--variant)
			case "${2:-}" in '' | --*) ASK_VARIANT=1 ;; *) VARIANT=$2 && shift ;; esac
			;;
		--lang)
			[ "$#" -ge 2 ] || { BAD_ARG="value:$1"; return; }
			LANG_OPT=$2
			shift
			;;
		--variant=*)
			VARIANT=${1#*=}
			[ -n "$VARIANT" ] || ASK_VARIANT=1
			;;
		--lang=*) LANG_OPT=${1#*=} ;;
		--uninstall) MODE=uninstall ;;
		--purge) PURGE=1 ;;
		--quiet) QUIET=1 ;;
		*) BAD_ARG="unknown:$1" && return ;;
		esac
		shift
	done
	case "$LANG_OPT" in '' | ru | en) ;; *) LANG_OPT='' BAD_ARG=lang && return ;; esac
	case "$VARIANT" in '' | base | full | tiny) ;; *) BAD_ARG=variant && return ;; esac
	[ "$PURGE" = 0 ] || [ "$MODE" = uninstall ] || { BAD_ARG=purge && return; }
	[ "$MODE" = install ] || { [ -z "$VARIANT" ] && [ "$ASK_VARIANT" = 0 ]; } || BAD_ARG=uninstall
}

main() {
	parse_args "$@"
	pick_language
	setup_output
	[ "$ASK_VARIANT" = 0 ] || [ -n "$BAD_ARG" ] || may_ask || BAD_ARG=variant_tty
	[ -z "$BAD_ARG" ] || usage_error
	( : >"$LOG" ) 2>/dev/null || LOG=/dev/null
	log "install.sh $* ($(date))"
	trap on_signal INT TERM HUP PIPE
	[ "$(id -u)" = 0 ] || fail 1 not_root "$(t 'Run the installer as root' 'Запустите установщик от имени root')"
	[ -r /etc/openwrt_release ] || fail 1 not_openwrt "$(t 'This installer runs only on OpenWrt' 'Установщик работает только на OpenWrt')"
	detect_package_manager
	WORK=$(mktemp -d /tmp/forkop-install.XXXXXX) || fail 1 no_memory "$(t 'Cannot create a directory in /tmp' 'Не удалось создать папку в /tmp')"
	identify_system
	lock
	[ "$MODE" = install ] || uninstall
	check_system
	read_state
	resolve_release
	stop_if_current
	download_packages
	check_packages
	apply
}

main "$@"
