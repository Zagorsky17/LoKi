#!/bin/sh
# shellcheck shell=dash
#
# Installs, updates and removes LoKi and its core, loki-core, on OpenWrt 24.10 and newer.
# Its options and exit codes are the interface LoKi's page runs it through, so they change only
# in ways an older page understands.
#
# Options: --variant base|full|tiny, the core's build (the installed one, or base, by default),
# with no value asked for at the terminal; --uninstall [--purge], with --purge the settings too;
# --quiet, the package manager's output in the log alone, as the page has it; --lang ru|en, by
# default LuCI's language, Russian while that is auto, since a console has no browser to follow.
# Exit codes: 0 done or nothing to do, 1 failed before anything changed, 2 bad options, 3 failed
# after changes began, 4 installed but LoKi did not start.
# Colors follow whether stdout is a terminal, questions whether /dev/tty opens: a page that runs it
# on a pseudo-terminal without making it the controlling one gets colors and no questions.
#
# The releases come through api.github.com, which takes 60 requests an hour from an address
# without an account; LOKI_DOWNLOAD_URL names a mirror with github.com's release paths instead.
# https_proxy and http_proxy are honored, NO_COLOR turns colors off.
#
# Every release carries release.json beside its packages, install.sh and SHA256SUMS:
#   {"schema":1,"name":"loki","version":"2.0.0","tag":"2.0.0","page":URL,
#    "requires":{"loki-core":"1.14.4-r1"},"min_config_version":"1.0.2"}
# The core's says "name":"loki-core" and requires the oldest LoKi it works with. An
# "install_command" field says the release installs only with that command, not from the page.

set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

LOKI_REPO=Zagorsky17/LoKi
RELEASE_TAG=2.0.2
CHECK_AVAILABLE=false
CORE_REPO=Zagorsky17/LoKi
# github.com answers a release link with a header line longer than uclient-fetch reads
API_URL=https://api.github.com
MIRROR=${LOKI_DOWNLOAD_URL:-}
LOG=${LOKI_INSTALL_LOG:-/dev/null}
LOCK_DIR=/var/lock/loki-install.lock
OUR_PACKAGES="loki luci-app-loki luci-i18n-loki-ru loki-core"
# The other packages known to install /usr/bin/loki-core; any other package that owns it counts too.
# What loki-core provides: a package that needs it stays when a foreign core goes.
CORE_PROVIDES=''
# What a core outside the package managers leaves: LoKi 1.0.x's binary builds and the installer
# of EikeiDev/OpenWRT-sing-box-extended, whose wrapper runs the core from /usr/libexec.
# LoKi 1.0.x's own state about its cores, and the backups its updater left when it failed.
# What the builds of the core speak, by the variants of its build.sh: tiny, what base adds to it,
# and what full adds to base (full_adds).
TINY_HAS='VLESS, Trojan, Shadowsocks, Hysteria, Hysteria2, TUIC, SOCKS, HTTP'
BASE_ADDS='WireGuard, AmneziaWG, WARP, OpenVPN, TrustTunnel, VMess, AnyTLS'
# apk offline still opens every feed's index and warns for each one no apk update fetched since boot.
APK_OFFLINE="--no-network --repositories-file /dev/null"
# The defaults a package manager leaves beside a config it keeps.
CONFFILE_COPIES="/etc/config/loki-opkg /etc/config/loki.apk-new /etc/config/loki-core-opkg /etc/config/loki-core.apk-new /etc/loki-core/config.json-opkg /etc/loki-core/config.json.apk-new"

MODE=install VARIANT='' ASK_VARIANT=0 PURGE=0 QUIET=0 LANG_OPT='' BAD_ARG=''
RU=0 INTERACTIVE=0 ASKED=0 PROMPTING=0 ANSWER='' C_STEP='' C_OK='' C_WARN='' C_ERR='' C_BOLD='' C_OFF=''
WORK='' LOCKED=0
PM='' PM_DB='' EXT='' ARCH='' RELEASE='' FLASH_MOUNT=/ FLASH_FS=''
LOKI_OLD='' APP_OLD='' I18N_OLD='' CORE_OLD='' CORE_OLD_VARIANT='' CONFIG_VERSION='' FORK_URL=''
LOKI_ENABLED=0 LOKI_RUNNING=0 STARTED=0
FOREIGN_WORLD='' LEFTOVERS=''
F_VERSION='' F_TAG='' F_CORE_MIN='' C_VERSION='' C_TAG='' C_LOKI_MIN=''
I18N=0 NEED_LOKI=0 NEED_APP=0 NEED_I18N=0
CORE_ACTION=none CORE_VARIANT='' CORE_REINSTALL=0
FILE_LOKI='' FILE_APP='' FILE_I18N='' FILE_CORE='' FILE_IP='' GOT=''
CONFIG_PLAN=none CONFIG_FROM='' CONFIG_REASON=''
REMOVE_PKGS='' REMOVE_FILES='' DEPS_MISSING='' DEPS_KB=0 LISTS_FAILED=0 PREDELETE_CORE=0 OPKG_FLAGS='' OPKG_DB_COPY=''
RESULT_LOKI='' RESULT_CORE='' RESULT_VARIANT='' BACKUP=''

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
	[ "$MODE" != check ] || check_result "$1" "${2:-}"
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
			printf '%s\n\n' "$(t 'LoKi runs on its own core, loki-core' 'LoKi работает на собственном ядре loki-core')"
		elif [ "$CORE_VARIANT" != custom ]; then
			printf '%s\n\n' "$(t 'Installed: loki-core %s (%s)' 'Установлен loki-core %s (%s)' "$CORE_OLD" "$CORE_VARIANT")"
		fi
		[ -z "${1:-}" ] || menu_card 0 custom "$(t 'keep the custom build %s' 'оставить кастомную сборку %s' "$1")"
		menu_card 1 tiny "$(t minimal минимальная)" '' "$TINY_HAS"
		menu_card 2 base "$(t recommended рекомендуемая)" "$C_OK" "+ $BASE_ADDS"
		menu_card 3 full "$(t maximal максимальная)" '' "+ $(full_adds)"
	} >/dev/tty
	while :; do
		prompt "$(t 'Which build of loki-core to install?' 'Какую сборку loki-core установить?')" "$default"
		case "${ANSWER:-$default}" in
		0 | custom) [ "$default" = 0 ] && break ;;
		1 | tiny) CORE_VARIANT=tiny && break ;;
		2 | base) CORE_VARIANT=base && break ;;
		3 | full) CORE_VARIANT=full && break ;;
		esac
	done
	log "build chosen: $CORE_VARIANT"
}

ask_translation() { # a first install asks whether LoKi's page gets its Russian translation
	[ -z "$LOKI_OLD" ] && may_ask || return 0
	question_block
	if ask "$(t 'Install the Russian translation of the LoKi page?' 'Установить русский перевод страницы LoKi?')" "$I18N"; then
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

core_requirement() { # the loki-core version a Depends field asks for: opkg "(>= V)", apk ">=V"
	printf '%s\n' "$1" | sed -n 's/.*loki-core *(* *>= *\([^), ]*\).*/\1/p'
}

provided() { # an installed package is or provides $1
	awk -F '\t' -v p="$1" '
		$1 == p { found = 1; exit }
		{ n = split($4, a, /[ ,]+/); for (i = 1; i <= n; i++) { w = a[i]; sub(/[<>=~(].*/, "", w); if (w == p) { found = 1; exit } } }
		END { exit !found }' "$WORK/db"
}



world_drop() { # remove the exact lines given from /etc/apk/world
	[ "$PM" = apk ] && [ -n "$*" ] || return 0
	awk -v drop=" $* " 'index(drop, " " $0 " ") == 0' /etc/apk/world >"$WORK/world" &&
		cat "$WORK/world" >/etc/apk/world
}


needed_by() { # needed_by NAME...: the installed packages other than LoKi's that depend on one of NAMES
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
	local status metadata=0
	case "$2" in *.json|*.sums|*.release) metadata=1 ;; esac
	if [ "$metadata" = 1 ]; then
		if [ "$(mem_available_kb)" -lt 6144 ] || [ "$(free_kb /tmp)" -lt 4096 ]; then fail 1 no_memory 'Not enough memory for release metadata'; fi
	fi
	( if [ "$metadata" = 1 ]; then ulimit -f 4096 || exit 1; fi
	wget -T 30 ${3:+"--header=Accept: $3"} -O "$2" "$1" ) 2>"$WORK/fetch.log"
	status=$?
	if [ "$metadata" = 1 ] && [ -f "$2" ] && [ "$(wc -c <"$2")" -gt 2097152 ]; then return 1; fi
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
		printf '%s/%s/releases/download/%s/%s' "$MIRROR" "$1" "$RELEASE_TAG" "$3"
	fi
}

asset_url() { # asset_url loki|core FILE: where FILE of the release is, empty when the release has none
	if [ -n "$MIRROR" ]; then
		if [ "$1" = core ]; then release_url "$CORE_REPO" "$C_TAG" "$2"; else release_url "$LOKI_REPO" "$F_TAG" "$2"; fi
	else
		jsonfilter -i "$WORK/$1.release" -e "@.assets[@.name=\"$2\"].url" 2>/dev/null
	fi
}

rate_limited() {
	fail 1 rate_limit "$(t 'GitHub refuses more requests from this address for now: it takes 60 an hour without an account' 'GitHub пока не принимает запросы с этого адреса: без входа он даёт 60 запросов в час')" \
		"$(t 'Run the installer again later: the limit is reset within the hour' 'Запустите установщик снова позже: лимит сбрасывается в течение часа')"
}

checksum_of() { # exactly one canonical SHA256 entry for this asset
	awk -v n="$1" '$2 == n || $2 == "*" n { count++; digest=$1; fields=NF } END { if (count == 1 && fields == 2 && length(digest) == 64 && digest !~ /[^a-fA-F0-9]/) print tolower(digest) }' "$2"
}

verify() { # verify FILE SUMS: 0 matches, 1 differs, 2 SUMS has no line for it
	local expected
	expected=$(checksum_of "${3:-${1##*/}}" "$2")
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
	if [ "${LOKI_ENABLED:-}" = 0 ] && pidof loki-core >/dev/null 2>&1; then
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

unbuilt_reason() { # why no loki-core exists for architecture $1
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
	printf '%s%s%s · OpenWrt %s · %s\n\n' "$C_STEP" "$(t 'LoKi installer' 'Установщик LoKi')" "$C_OFF" "${RELEASE:-?}" "${ARCH:-?}"
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
			fail 1 unsupported_openwrt "$(t 'LoKi needs OpenWrt 24.10 or newer' 'Для LoKi нужна OpenWrt 24.10 или новее')"
		fi
		;;
	esac
	reason=$(unbuilt_reason "$ARCH")
	[ -z "$reason" ] || fail 1 unsupported_arch "$(t 'LoKi does not run on this processor: %s' 'LoKi не работает на этом процессоре: %s' "$reason")"
	grep -q ' /overlay ' /proc/mounts && FLASH_MOUNT=/overlay
	FLASH_FS=$(awk -v m="$FLASH_MOUNT" '$2 == m { t = $3 } END { print t }' /proc/mounts)
	ram=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
	log "OpenWrt $RELEASE, $ARCH, $PM; flash $(free_kb "$FLASH_MOUNT") KB free ($FLASH_FS); RAM $ram MB, $(mem_available_kb) KB available"
	if [ "$ram" -lt 100 ] 2>/dev/null; then
		warn low_memory "$(t 'LoKi needs about 128 MB of RAM, and this router has %s MB' 'Для LoKi нужно около 128 МБ оперативной памяти, а у роутера %s МБ' "$ram")"
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

loki_status() { # running or enabled, from the installed LoKi
	local status
	[ -x /etc/init.d/loki ] && /etc/init.d/loki enabled 2>/dev/null && LOKI_ENABLED=1
	[ -x /usr/bin/loki ] || return 0
	status=$(deadline 15 /usr/bin/loki get_status 2>/dev/null)
	log "loki get_status: $status"
	case "$(printf '%s' "$status" | jsonfilter -e '@.running' 2>/dev/null)" in 1 | true) LOKI_RUNNING=1 ;; esac
	# get_status counts a core that started less than two seconds ago, or a capture being set up
	# again, as stopped; procd runs LoKi's core as its sing-box service all the same
	if [ "$LOKI_RUNNING" = 0 ] && [ "$LOKI_ENABLED" = 1 ] &&
		ubus call service list '{"name":"loki-core"}' 2>/dev/null | jsonfilter -e '@["loki-core"].instances[*].running' 2>/dev/null | grep -q true; then
		LOKI_RUNNING=1
	fi
	log "loki: enabled $LOKI_ENABLED, running $LOKI_RUNNING"
}

read_state() {
	local name
	refresh_db
	LOKI_OLD=$(pkg_version loki)
	# every release of LoKi names this project; a fork built under its package names names its own
	FORK_URL=$(pkg_url loki)
	[ -n "$LOKI_OLD" ] && [ "$FORK_URL" != "https://github.com/$LOKI_REPO" ] || FORK_URL=''
	APP_OLD=$(pkg_version luci-app-loki)
	I18N_OLD=$(pkg_version luci-i18n-loki-ru)
	CORE_OLD=$(pkg_version loki-core)
	[ -z "$CORE_OLD" ] || CORE_OLD_VARIANT=$(cat /usr/share/loki-core/variant 2>/dev/null)
	[ ! -f /etc/config/loki ] || CONFIG_VERSION=$(uci -q get loki.settings.config_version)
	[ "$MODE" = check ] || loki_status

	for name in $OUR_PACKAGES; do
		[ -z "$(pkg_version "$name")" ] || [ "$(pkg_url "$name")" = "https://github.com/$LOKI_REPO" ] ||
			fail 1 ownership "$(t 'A package named %s belongs to another project' 'Пакет с именем %s принадлежит другому проекту' "$name")"
	done
	[ "$MODE" = check ] || ! pidof sing-box >/dev/null 2>&1 ||
		fail 1 conflict "$(t 'Stop the other sing-box application before installing LoKi' 'Перед установкой LoKi остановите другое приложение sing-box')"
}

# --- the releases ---------------------------------------------------------------------------

read_manifest() { # validate fields before using them as versions or URL path segments
	local name schema version tag requirement
	grep -qi '\\u0000' "$1" && return 1
	name=$(jsonfilter -i "$1" -e '@.name' 2>/dev/null)
	schema=$(jsonfilter -i "$1" -e '@.schema' 2>/dev/null)
	[ "$name" = "$2" ] && [ "$schema" = 1 ] || return 1
	version=$(jsonfilter -i "$1" -e '@.version' 2>/dev/null) || return 1
	valid_release_version "$version" "$2" || return 1
	tag=$(jsonfilter -i "$1" -e '@.tag' 2>/dev/null) || tag=''
	if [ -n "$tag" ]; then
		case "$tag" in *[!v0-9.r-]*) return 1 ;; esac
		valid_release_version "${tag#v}" loki || return 1
	fi
	if [ "$2" = loki ]; then
		requirement=$(jsonfilter -i "$1" -e '@.requires["loki-core"]' 2>/dev/null) || return 1
		valid_release_version "$requirement" loki-core || return 1
	else
		requirement=$(jsonfilter -i "$1" -e '@.requires.loki' 2>/dev/null) || return 1
		valid_release_version "$requirement" loki || return 1
	fi
	printf '%s\n%s\n%s\n' "$version" "$tag" "$requirement"
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

fetch_release() { # fetch_release loki|core: the latest release's manifest, and from the API its files
	local repo=$LOKI_REPO name=LoKi package=loki manifest_file=release.json manifest="$WORK/$1.json" url status=0
	[ "$1" = loki ] || repo=$CORE_REPO name=loki-core package=loki-core manifest_file=core-release.json
	if [ -z "$MIRROR" ]; then
		download "$API_URL/repos/$repo/releases/tags/$RELEASE_TAG" "$WORK/$1.release"
		status=$?
	fi
	if [ "$status" = 0 ]; then
		url=$(asset_url "$1" "$manifest_file")
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
	url=$(asset_url "$1" SHA256SUMS)
	if [ -z "$url" ] || ! download "$url" "$WORK/$1.sums" application/octet-stream; then fail 1 release 'Missing SHA256SUMS'; fi
	verify "$manifest" "$WORK/$1.sums" "$manifest_file" || fail 1 checksum 'Release manifest checksum mismatch'
	read_manifest "$manifest" "$package" >"$WORK/$1.fields" ||
		fail 1 release "$(t 'Cannot read the information on the %s release' 'Не удалось прочитать сведения о релизе %s' "$name")" \
			"$(t 'Download the latest install.sh' 'Скачайте свежий install.sh')"
	if [ "$1" = loki ]; then
		{
			read -r F_VERSION
			read -r F_TAG
			read -r F_CORE_MIN
		} <"$WORK/loki.fields"
		F_TAG=${F_TAG:-$F_VERSION}
	else
		{
			read -r C_VERSION
			read -r C_TAG
			read -r C_LOKI_MIN
		} <"$WORK/core.fields"
		C_TAG=${C_TAG:-v$C_VERSION}
	fi
}

resolve_release() {
	step release "$(t 'Looking for the latest version' 'Поиск последней версии')"
	fetch_release loki
	fetch_release core
	decide_loki
	decide_core
	ask_translation
	[ "$ASKED" = 0 ] || printf '\n' >/dev/tty
	# opkg keeps an installed package of the version it is given and refuses an older one: a fork's
	# go and LoKi's come in, whatever versions the fork took
	[ -z "$FORK_URL" ] || OPKG_FLAGS='--force-downgrade --force-reinstall'
}

decide_loki() { # the LoKi packages to install, NEED_*, and the LoKi that will run
	if [ -n "$LOKI_OLD" ]; then
		[ -z "$I18N_OLD" ] || I18N=1
	else
		# a first install brings the page's Russian translation unless LuCI is set to another language
		case "$(uci -q get luci.main.lang)" in '' | auto | ru*) I18N=1 ;; esac
	fi
	RESULT_LOKI=$F_VERSION
	if [ -n "$FORK_URL" ]; then
		# a fork goes whatever its version says: LoKi's packages take its place
		NEED_LOKI=1 NEED_APP=1 NEED_I18N=$I18N
		return 0
	fi
	if [ -n "$LOKI_OLD" ] && [ "$(vercmp "$LOKI_OLD" "$F_VERSION")" = 1 ]; then
		info "$(t 'loki %s is newer than the latest release %s and stays' 'loki %s новее последнего релиза %s и остаётся' "$LOKI_OLD" "$F_VERSION")"
		RESULT_LOKI=$LOKI_OLD
		F_CORE_MIN=$(core_requirement "$(pkg_depends loki)")
		return 0
	fi
	# the page and its translation go with the backend they talk to
	[ "$LOKI_OLD" = "$F_VERSION" ] || NEED_LOKI=1
	[ "$NEED_LOKI" = 0 ] && [ "$APP_OLD" = "$F_VERSION" ] || NEED_APP=1
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
	fi
	if [ "$CORE_VARIANT" = custom ]; then
		if [ -n "$F_CORE_MIN" ] && older "$CORE_OLD" "$F_CORE_MIN"; then
			text=$(t 'The custom build of loki-core %s is too old: loki %s needs %s or newer' 'Кастомная сборка loki-core %s слишком старая: loki %s требует %s или новее' "$CORE_OLD" "$RESULT_LOKI" "$F_CORE_MIN")
			may_ask || fail 1 incompatible "$text" "$(t 'Install an official build: --variant base, full or tiny' 'Поставьте официальную сборку: --variant base, full или tiny')"
			warn custom_outdated "$text"
			choose_variant
		elif older "$CORE_OLD" "$C_VERSION"; then
			warn custom_outdated "$(t 'The custom build of loki-core %s is outdated: %s is available' 'Кастомная сборка loki-core %s устарела: доступна %s' "$CORE_OLD" "$C_VERSION")"
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
			info "$(t 'loki-core %s is newer than the latest release %s and stays' 'loki-core %s новее последнего релиза %s и остаётся' "$CORE_OLD" "$C_VERSION")"
			RESULT_CORE=$CORE_OLD RESULT_VARIANT=$CORE_OLD_VARIANT
		elif [ "$order" != 0 ] || [ "$CORE_VARIANT" != "$CORE_OLD_VARIANT" ]; then
			CORE_ACTION=install
			[ "$order" != 0 ] || CORE_REINSTALL=1
		fi
	fi
	check_compatible
}

check_compatible() { # the LoKi and the core that will run work together
	# what a core needs of LoKi only its release says
	if [ "$RESULT_CORE" = "$C_VERSION" ] && [ -n "$C_LOKI_MIN" ] && older "$RESULT_LOKI" "$C_LOKI_MIN"; then
		fail 1 incompatible "$(t 'loki-core %s needs loki %s or newer, and loki %s would run' 'loki-core %s требует loki %s или новее, а будет loki %s' "$C_VERSION" "$C_LOKI_MIN" "$RESULT_LOKI")"
	fi
	if [ -n "$F_CORE_MIN" ] && older "$RESULT_CORE" "$F_CORE_MIN"; then
		fail 1 incompatible "$(t 'loki %s needs loki-core %s or newer, and the latest is %s' 'loki %s требует loki-core %s или новее, а последний релиз — %s' "$RESULT_LOKI" "$F_CORE_MIN" "$C_VERSION")" \
			"$(t 'That release is not out yet: run the installer later' 'Этот релиз ещё не вышел, запустите установщик позже')"
	fi
}

stop_if_current() { # nothing to install: the installed versions, and the run ends
	[ "$NEED_LOKI$NEED_APP$NEED_I18N" = 000 ] && [ "$CORE_ACTION" = none ] || return 0
	info "$(t 'Up to date: loki %s, loki-core %s (%s)' 'Обновлений нет: loki %s, loki-core %s (%s)' "$RESULT_LOKI" "$RESULT_CORE" "$RESULT_VARIANT")"
	finish 0
}

# --- getting the packages -------------------------------------------------------------------

core_file() { # core_file VARIANT
	printf 'loki-core_%s_%s_%s.%s' "$C_VERSION" "$1" "$ARCH" "$EXT"
}

get_package() { # get_package loki|core FILE: GOT is FILE of that release, checked against its SHA256SUMS
	local sums="$WORK/$1.sums" file="$WORK/$2" url name="LoKi $F_VERSION"
	[ "$1" = loki ] || name="loki-core $C_VERSION"
	[ -s "$sums" ] || fetch_or_fail "$(asset_url "$1" SHA256SUMS)" "$sums" SHA256SUMS "$name"
	if [ -z "$(checksum_of "$2" "$sums")" ]; then
		[ "$1" = loki ] || fail 1 release "$(t 'Release loki-core %s has no %s build for %s' 'В релизе loki-core %s нет сборки %s для %s' "$C_VERSION" "$CORE_VARIANT" "$ARCH")"
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

need_ram_kb() { # what the run puts in RAM while LoKi still runs: the downloads, the core's as the largest
	# package of its build, and the largest of the checks run beside them
	local kb=6144
	[ "$NEED_LOKI$NEED_APP$NEED_I18N" = 000 ] || kb=$((kb + 1024))
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
	[ "$LOKI_RUNNING" = 0 ] || fail 1 no_memory "$text" \
		"$(t 'Stop LoKi: /etc/init.d/loki stop' 'Остановите LoKi: /etc/init.d/loki stop')" \
		"$(t 'Run the installer again, then start LoKi: /etc/init.d/loki start' 'Запустите установщик снова, затем LoKi: /etc/init.d/loki start')"
	fail 1 no_memory "$text" "$(t 'Free some RAM and run the installer again' 'Освободите память и запустите установщик снова')"
}

download_packages() {
	enough_ram "$(need_ram_kb)" downloads
	step download "$(t 'Downloading the packages' 'Загрузка пакетов')"
	if [ "$NEED_LOKI" = 1 ]; then
		get_package loki "loki_${F_VERSION}_all.$EXT"
		FILE_LOKI=$GOT
	fi
	if [ "$NEED_APP" = 1 ]; then
		get_package loki "luci-app-loki_${F_VERSION}_all.$EXT"
		FILE_APP=$GOT
	fi
	if [ "$NEED_I18N" = 1 ]; then
		get_package loki "luci-i18n-loki-ru_${F_VERSION}_all.$EXT"
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
	check_space
	check_config
	preflight
}

# apk keeps an ip-full an older LoKi pulled in, as it is the new one's ip: ip-tiny replaces it

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
	for file in $FILE_CORE $FILE_LOKI $FILE_APP $FILE_I18N; do
		control=$(control_of "$file")
		for name in $(dep_names "$(field "$control" Depends)"); do
			contains "$name" "$OUR_PACKAGES $DEPS_MISSING" || provided "$name" || DEPS_MISSING="$DEPS_MISSING $name"
		done
	done
	DEPS_MISSING=${DEPS_MISSING# }
}

compression() { # percent of its size a package takes on the flash
	case "$FLASH_FS" in ubifs | jffs2) echo 60 ;; *) echo 105 ;; esac
}

check_space() { # whether the packages and their dependencies fit the flash; may plan freeing the old core
	local percent need=0 free credit=0 file size core_credit=0
	percent=$(compression)
	for file in $FILE_LOKI $FILE_APP $FILE_I18N $FILE_CORE; do
		size=$(field "$(control_of "$file")" Installed-Size)
		is_number "$size" || size=$(($(file_kb "$file") * 1024 * 3))
		need=$((need + size * percent / 100 / 1024))
	done
	need=$((need + DEPS_KB * percent / 100 + 1024))
	for file in $REMOVE_FILES $LEFTOVERS; do
		credit=$((credit + $(upper_kb "$file") * percent / 100))
	done
	if [ "$CORE_ACTION" = install ] && [ -e /usr/bin/loki-core ] && ! contains /usr/bin/loki-core "$REMOVE_FILES"; then
		core_credit=$(($(upper_kb /usr/bin/loki-core) * percent / 100))
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

check_config() { # what the new package does with /etc/config/loki, from its own migration code
	local root="$WORK/new" verdict='' status=1 note
	[ "$NEED_LOKI" = 1 ] && [ -f /etc/config/loki ] || return 0
	# a fork's config follows its own schema under the labels of LoKi's releases
	if [ -n "$FORK_URL" ]; then
		CONFIG_PLAN=reset CONFIG_FROM=foreign CONFIG_REASON=foreign
		return 0
	fi
	if mkdir -p "$root" "$WORK/check" && cp /etc/config/loki "$WORK/check/loki"; then
		if [ "$EXT" = apk ]; then
			apk extract --allow-untrusted --no-chown --destination "$root" "$FILE_LOKI" >>"$LOG" 2>&1
		else
			tar -xzOf "$FILE_LOKI" ./data.tar.gz 2>/dev/null | tar -xzf - -C "$root" >>"$LOG" 2>&1
		fi
		verdict=$(ucode -L "$root/usr/lib/loki" "$root/usr/lib/loki/config/migration.uc" check "$WORK/check/loki" 2>>"$LOG")
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
		fail 1 migration "$(t 'LoKi %s cannot migrate this config: %s' 'LoKi %s не сможет перенести этот конфиг: %s' "$F_VERSION" "$CONFIG_REASON")" \
			"$(t 'Report it in the LoKi chat. To start from a clean config, rename /etc/config/loki' 'Сообщите об этом в чат LoKi. Чтобы начать с чистого конфига, переименуйте /etc/config/loki')"
	fi
	# the notes are LoKi's own log lines, in English, which its log keeps: the text output leaves them out
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
		# loki-core provides sing-box, so a conflict with that name would be one with itself;
		# left unversioned, the name goes to it instead of the package of that name
		if [ "$name" = sing-box ]; then echo sing-box; else echo "!$name"; fi
	done
}

packages_in_transaction() {
	[ -z "$FILE_CORE" ] || [ "$CORE_REINSTALL" = 1 ] || echo loki-core
	[ -z "$FILE_LOKI" ] || echo loki
	[ -z "$FILE_APP" ] || echo luci-app-loki
	[ -z "$FILE_I18N" ] || echo luci-i18n-loki-ru
}

preflight() { # every package manager command apply runs, simulated
	local out="$WORK/preflight" name hint=''
	[ "$LISTS_FAILED" = 0 ] || hint=$(network_hint)
	set --
	for name in "$FILE_CORE" "$FILE_LOKI" "$FILE_APP" "$FILE_I18N" "$FILE_IP"; do [ -z "$name" ] || set -- "$@" "$name"; done
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
	capture "$out" opkg --noaction --force-depends $OPKG_FLAGS install "$@"
	if grep -q -e 'cannot find dependency' -e 'Cannot satisfy' -e 'incompatible with the arch' "$out"; then
		fail 1 check "$(t 'opkg cannot satisfy the dependencies: %s' 'opkg не может удовлетворить зависимости: %s' "$(grep -m 3 -e 'cannot find dependency' -e 'Cannot satisfy' -e incompatible "$out" | tr '\n' ' ')")" "$hint"
	fi
	for name in $(packages_in_transaction); do
		grep -q -e "^Installing $name (" -e "^Upgrading $name on " -e "^Downgrading $name on " -e "^Removing package $name from" "$out" ||
			fail 1 check "$(t 'opkg would not install %s: %s' 'opkg не стал бы устанавливать %s: %s' "$name" "$(pm_errors "$out")")"
	done
}

# --- changes --------------------------------------------------------------------------------

config_copies() { # the copies of /etc/config/loki there are now, one per line
	ls -d /etc/config/loki.* 2>/dev/null
}

file_label() { # a config version as the package writes it into the name of a copy
	printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

backup_config() { # a copy that guards the transaction; the package keeps its own where it should
	local copy
	config_copies >"$WORK/copies"
	[ -f /etc/config/loki ] && [ "$NEED_LOKI" = 1 ] || return 0
	copy="/etc/config/loki.$(file_label "${CONFIG_FROM:-unknown}")-$(date +%Y%m%d-%H%M%S)"
	if [ -n "$FORK_URL" ]; then
		# LoKi's package would read a fork's config as one of its own releases: it starts from its defaults
		mv /etc/config/loki "$copy" 2>>"$LOG" || fail 1 backup "$(t 'Cannot set /etc/config/loki aside' 'Не удалось отложить /etc/config/loki')"
	else
		cp -p /etc/config/loki "$copy" 2>>"$LOG" || fail 1 backup "$(t 'Cannot copy /etc/config/loki' 'Не удалось скопировать /etc/config/loki')"
	fi
	BACKUP=$copy
	log "config copy: $BACKUP"
}

install_dependencies() {
	[ -n "$DEPS_MISSING" ] || return 0
	step dependencies "$(t 'Installing dependencies: %s' 'Установка зависимостей: %s' "$(commas "$DEPS_MISSING")")"
	# shellcheck disable=SC2086
	run detached "$PM" "$([ "$PM" = apk ] && echo add || echo install)" $DEPS_MISSING ||
		fail 3 dependencies "$(t 'Cannot install the dependencies; loki and loki-core were not touched' 'Не удалось установить зависимости, loki и loki-core не тронуты')" "$(network_hint)"
	# shellcheck disable=SC2086
	pulled_in $DEPS_MISSING
	refresh_db
}

stop_cores() {
	local pids try
	for try in 1 2 3 4 5 6 7 8 9 10; do
		pids=$(pidof loki-core 2>/dev/null)
		[ -n "$pids" ] || return 0
		# shellcheck disable=SC2086
		kill $pids 2>/dev/null
		sleep 1
	done
	# shellcheck disable=SC2046
	kill -9 $(pidof loki-core 2>/dev/null) 2>/dev/null
}

stop_services() {
	if [ "$LOKI_RUNNING" = 1 ]; then
		step stop "$(t 'Stopping LoKi' 'Остановка LoKi')"
	elif pidof loki-core >/dev/null 2>&1; then
		step stop "$(t 'Stopping sing-box' 'Остановка sing-box')"
	fi
	[ ! -x /etc/init.d/loki ] || deadline 90 /etc/init.d/loki stop >>"$LOG" 2>&1
	[ ! -x /etc/init.d/loki-core ] || deadline 30 /etc/init.d/loki-core stop >>"$LOG" 2>&1
	stop_cores
}


restore_core() {
	[ "$PREDELETE_CORE" = 1 ] && [ ! -e /usr/bin/loki-core ] && [ -f "$WORK/loki-core.old.gz" ] || return 0
	gzip -dc "$WORK/loki-core.old.gz" >/usr/bin/loki-core && chmod 0755 /usr/bin/loki-core && log "restored the old core"
}

removals() { # "name version" a line: what the transaction takes away, a fork's own packages first
	local name version
	[ -z "$FORK_URL" ] || for name in loki luci-app-loki luci-i18n-loki-ru; do
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
		if [ -n "$FORK_URL" ] && contains "$name" "loki luci-app-loki luci-i18n-loki-ru"; then
			# a fork's packages are gone once LoKi's take their place, of the same version or not
			[ "$(pkg_url loki)" != "$FORK_URL" ] || continue
		else
			[ "$(pkg_version "$name")" != "$version" ] || continue
		fi
		source=''
		[ "$name" != loki ] || [ -z "$FORK_URL" ] || source=" (${FORK_URL#*://})"
		removed "$name $version$source"
	done
}

dropped() { # dropped LINES: "name version" of each package installed before and gone now, but those of LINES
	awk -F '\t' -v planned="$1" '
		BEGIN { n = split(planned, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, " "); skip[f[1]] = 1 } }
		FILENAME == ARGV[1] { now[$1] = 1; next }
		!($1 in now) && !($1 in skip) { print $1 " " $2 }' "$WORK/db" "$WORK/db.before" | sort
}


# what the packages that went pulled in: opkg's upgrade drops only its first level, apk all of it

transaction() {
	local out="$WORK/transaction" name status=0 order before
	before=$(removals)
	cp "$WORK/db" "$WORK/db.before"
	set --
	for name in "$FILE_CORE" "$FILE_LOKI" "$FILE_APP" "$FILE_I18N" "$FILE_IP"; do [ -z "$name" ] || set -- "$@" "$name"; done
	if [ "$PM" = apk ]; then
		for name in $(apk_constraints); do set -- "$@" "$name"; done
		# the dependencies are in: the feed indexes would take RAM and the network while LoKi is down
		# shellcheck disable=SC2086
		perform "$out" detached apk add --allow-untrusted $APK_OFFLINE "$@" || status=$?
		# shellcheck disable=SC2046
		world_drop $(apk_constraints)
	else
		cp /usr/lib/opkg/status "$WORK/opkg-status" 2>/dev/null
		if [ -n "$REMOVE_PKGS" ]; then
			order=$(removal_order "$REMOVE_PKGS")
			# what still needs a foreign core's sing-box gets it from loki-core within this run
			# shellcheck disable=SC2086
			perform "$out.remove" detached opkg --force-depends remove $order || status=$?
		fi
		if [ "$status" = 0 ] && [ "$CORE_REINSTALL" = 1 ] && [ -n "$FILE_CORE" ]; then
			perform "$out.core" detached opkg install --force-reinstall "$FILE_CORE" || status=$?
			shift
		fi
		# shellcheck disable=SC2086
		[ "$status" != 0 ] || [ "$#" = 0 ] || perform "$out" detached opkg install $OPKG_FLAGS "$@" || status=$?
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
		OPKG_DB_COPY=/tmp/opkg-status.before-loki
		cp "$WORK/opkg-status" "$OPKG_DB_COPY" 2>/dev/null
		log "opkg cannot read /usr/lib/opkg/status, and putting it back failed: its copy is $OPKG_DB_COPY"
	fi
}

check_installed() { # what the transaction left, against what it was to install
	local problems='' name reason db_hint=''
	[ -z "$FILE_CORE" ] || [ "$(pkg_version loki-core)" = "$(field "$(control_of "$FILE_CORE")" Version)" ] || problems="$problems loki-core"
	[ -z "$FILE_CORE" ] || [ "$(cat /usr/share/loki-core/variant 2>/dev/null)" = "$CORE_VARIANT" ] || contains loki-core "$problems" || problems="$problems loki-core"
	[ -z "$FILE_LOKI" ] || [ "$(pkg_version loki)" = "$F_VERSION" ] || problems="$problems loki"
	[ -z "$FORK_URL" ] || [ "$(pkg_url loki)" != "$FORK_URL" ] || contains loki "$problems" || problems="$problems loki"
	[ -z "$FILE_APP" ] || [ "$(pkg_version luci-app-loki)" = "$F_VERSION" ] || problems="$problems luci-app-loki"
	[ -z "$FILE_I18N" ] || [ "$(pkg_version luci-i18n-loki-ru)" = "$F_VERSION" ] || problems="$problems luci-i18n-loki-ru"
	[ -z "$FILE_IP" ] || [ -n "$(pkg_version ip-tiny)" ] || problems="$problems ip-tiny"
	for name in $REMOVE_PKGS; do
		[ -z "$(pkg_version "$name")" ] || problems="$problems $name"
	done
	[ -n "$problems" ] || [ "$1" != 0 ] || return 0
	restore_core
	repair_opkg_db
	[ -z "$OPKG_DB_COPY" ] || db_hint=$(t "opkg's database is damaged; its copy from before is %s" 'База opkg повреждена, её копия до установки — %s' "$OPKG_DB_COPY")
	if [ -n "$FILE_LOKI" ] && { opkg_unpacked loki || { [ "$(pkg_version loki)" = "$F_VERSION" ] && [ "$1" != 0 ]; }; }; then
		reason=$(logread -e loki 2>/dev/null | grep '\[error\]' | tail -n 1 | sed 's/.*\[error\] *//')
		fail 3 transaction "$(t 'LoKi %s is installed, but its setup failed: %s' 'LoKi %s установлен, но не настроился: %s' "$F_VERSION" "${reason:-$(t 'see logread -e loki' 'см. logread -e loki')}")" \
			"$(t 'Its config is left as it was. Report it in the LoKi chat with the output of logread -e loki' 'Конфиг оставлен как был. Сообщите об этом в чат LoKi, приложив вывод logread -e loki')" \
			"$(start_again)" "$db_hint"
	fi
	fail 3 transaction "$(t 'The installation did not complete: %s' 'Установка не завершилась: %s' "$(commas "$problems")")" \
		"$(t 'Fix the cause the log names and run the installer again' 'Устраните причину из журнала и запустите установщик снова')" \
		"$(start_again)" "$db_hint"
}

start_again() { # after a failed transaction a LoKi that ran before runs again on what is installed now
	[ "$LOKI_RUNNING" = 1 ] && [ -x /etc/init.d/loki ] || return 0
	if deadline 150 /etc/init.d/loki start >>"$LOG" 2>&1; then
		t 'LoKi runs again' 'LoKi снова запущен'
	else
		t 'LoKi did not start again: logread -e loki' 'LoKi не запустился снова: logread -e loki'
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
	# /tmp is RAM, which the start of LoKi needs more than these files
	rm -rf "$WORK/new" "$WORK/loki-core.old.gz"
	for file in "$FILE_LOKI" "$FILE_APP" "$FILE_I18N" "$FILE_CORE" "$FILE_IP"; do
		[ -z "$file" ] || rm -f "$file"
	done
}

loki_up() { # start LoKi and wait for it to run: 0 once it does
	local waited=0
	deadline 150 /etc/init.d/loki start >>"$LOG" 2>&1
	while :; do
		case "$(deadline 15 /usr/bin/loki get_status 2>/dev/null | jsonfilter -e '@.running' 2>/dev/null)" in 1 | true) return 0 ;; esac
		[ "$waited" -lt 30 ] || return 1
		sleep 3
		waited=$((waited + 3))
	done
}

start_loki() { # a LoKi that ran before runs again, unless its config starts clean and has nothing to run
	local pid exe hint
	[ -x /etc/init.d/loki ] || return 0
	[ "$LOKI_ENABLED" = 0 ] || run /etc/init.d/loki enable
	[ "$LOKI_RUNNING" = 1 ] || return 0
	! clean_config || return 0
	step start "$(t 'Starting LoKi' 'Запуск LoKi')"
	hint=$(t 'Details: logread -e loki' 'Подробности: logread -e loki')
	loki_up || fail 4 service "$(t 'LoKi is installed but did not start: %s' 'LoKi установлен, но не запустился: %s' \
		"$(logread -e loki 2>/dev/null | grep -i error | tail -n 1 | sed 's/.*\]: //; s/^\[error\] *//')")" "$hint"
	pid=$(pidof loki-core | awk '{ print $1 }')
	exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
	if [ -z "$pid" ] || [ "$exe" != /usr/bin/loki-core ]; then
		fail 4 service "$(t 'LoKi runs, but sing-box does not' 'LoKi работает, а sing-box — нет')" "$hint"
	fi
	STARTED=1
}

clean_config() { # LoKi's config is the package's own default, which has nothing to run
	cmp -s /etc/config/loki /usr/share/loki/default-config
}

package_names() { # the packages the transaction installs, by name
	local file names=''
	for file in $FILE_LOKI $FILE_APP $FILE_I18N $FILE_CORE; do
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
	predelete_core
	step install "$(t 'Installing packages: %s' 'Установка пакетов: %s' "$(package_names)")"
	transaction
	clean_up_after
	start_loki
	summary
}

finale() { # the closing line, set apart: what the run achieved
	log "done: $1"
	printf '\n%s%s%s\n' "$C_OK" "$(t 'Done! %s' 'Готово! %s' "$1")" "$C_OFF" 2>/dev/null
}

summary() {
	local result runs
	runs=$(t ' and running' ' и запущен')
	if [ -n "$FORK_URL" ] || [ -z "$LOKI_OLD" ]; then
		result=$(t 'LoKi %s is installed' 'LoKi %s установлен' "$RESULT_LOKI")
	elif [ "$NEED_LOKI" = 1 ]; then
		result=$(t 'LoKi is updated to %s' 'LoKi обновлён до %s' "$RESULT_LOKI")
	elif [ "$CORE_ACTION" = install ]; then
		if [ -n "$CORE_OLD" ] && [ "$CORE_REINSTALL" = 0 ]; then
			result=$(t 'loki-core is updated to %s (%s)' 'loki-core обновлён до %s (%s)' "$RESULT_CORE" "$RESULT_VARIANT")
		else
			result=$(t 'loki-core %s (%s) is installed' 'loki-core %s (%s) установлен' "$RESULT_CORE" "$RESULT_VARIANT")
		fi
		runs=$(t ', LoKi is running' ', LoKi запущен')
	else
		result=$(t 'LoKi %s is installed' 'LoKi %s установлен' "$RESULT_LOKI")
	fi
	[ "$STARTED" = 1 ] || runs=''
	! starts_over || runs="$runs$(t '. Set it up in LuCI: Services → LoKi' '. Настройте его в LuCI: Службы → LoKi')"
	finale "$result$runs"
	finish 0
}

starts_over() { # LoKi starts from its default config: a first install, a config it could not keep, a fork's
	{ [ -z "$LOKI_OLD" ] || [ -n "$FORK_URL" ] || [ "$CONFIG_PLAN" = reset ]; } && clean_config
}

# --- removal --------------------------------------------------------------------------------

uninstall() {
	local packages='' name file out="$WORK/remove" before='' users
	refresh_db
	# podkop and the like stay beside LoKi on its core, which provides sing-box: the core goes with them
	users=$(needed_by loki-core "$CORE_PROVIDES")
	for name in luci-i18n-loki-ru luci-app-loki loki loki-core; do
		[ -n "$(pkg_version "$name")" ] || continue
		[ "$name" != loki-core ] || [ -z "$users" ] || continue
		packages="$packages $name"
		before="$before$name $(pkg_version "$name")
"
	done
	packages=${packages# }
	if [ -z "$packages" ]; then
		info "$(t 'LoKi is not installed' 'LoKi не установлен')"
		finish 0
	fi
	if [ "$PURGE" = 0 ] && may_ask; then
		ask "$(t 'Delete the settings of LoKi too?' 'Удалить и настройки LoKi?')" && PURGE=1
		printf '\n' >/dev/tty
	fi
	trap '' INT TERM HUP PIPE
	step remove "$(t 'Removing the packages' 'Удаление пакетов')"
	[ ! -x /etc/init.d/loki ] || deadline 90 /etc/init.d/loki stop >>"$LOG" 2>&1
	# a core that stays goes on running for what needs it
	[ -n "$users" ] || [ ! -x /etc/init.d/loki-core ] || deadline 30 /etc/init.d/loki-core stop >>"$LOG" 2>&1
	cp "$WORK/db" "$WORK/db.before"
	# shellcheck disable=SC2086
	if [ "$PM" = apk ]; then
		perform "$out" detached apk del $APK_OFFLINE $packages
	else
		perform "$out" detached opkg remove $packages
	fi
	# opkg leaves the directories it emptied
	find /usr/lib/loki /usr/share/loki /usr/share/loki-core /www/luci-static/resources/view/loki -type d 2>/dev/null |
		sort -r | while read -r dir; do rmdir "$dir" 2>/dev/null; done
	refresh_db
	before=$(printf '%s' "$before" | sort)
	gone "$before"
	gone "$(dropped "$before")"
	for name in $packages; do
		[ -z "$(pkg_version "$name")" ] ||
			fail 3 transaction "$(t '%s was not removed: %s' 'Пакет %s не удалён: %s' "$name" "$(pm_errors "$out")")"
	done
	[ -z "$users" ] || [ -z "$(pkg_version loki-core)" ] ||
		warn core_kept "$(t 'loki-core stays for %s' 'loki-core остаётся для %s' "$(commas "$users")")"
	if [ "$PURGE" = 1 ]; then
		for file in /etc/config/loki /etc/config/loki.* /etc/config/loki-opkg /etc/loki; do
			[ ! -e "$file" ] || rm -rf "$file"
		done
		[ -n "$users" ] || for file in /etc/config/loki-core /etc/config/loki-core-opkg /etc/loki-core; do
			[ ! -e "$file" ] || rm -rf "$file"
		done
	fi
	finale "$(t 'LoKi is removed' 'LoKi удалён')"
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
		--check) [ "$MODE" = install ] || BAD_ARG=check; MODE=check ;;
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

valid_release_version() {
	case "$1" in '' | *[!0-9.r-]*) return 1 ;; esac
	if [ "$2" = loki ]; then
		printf '%s' "$1" | grep -Eq '^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'
	else
		printf '%s' "$1" | grep -Eq '^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}-r[0-9]{1,9}$'
	fi
}

valid_mirror() {
	case "$1" in *[!a-zA-Z0-9:./_~\[\]-]* | */../* | */./*) return 1 ;; esac
	printf '%s' "$1" | grep -Eq '^https://([a-zA-Z0-9.-]+|\[[a-fA-F0-9:]+\])(:[0-9]{1,5})?(/[a-zA-Z0-9._~/-]*)?$'
}

check_result() {
	local success=false reason="$2" installed_app="$LOKI_OLD" installed_core="$CORE_OLD" variant="$CORE_OLD_VARIANT" app="$F_VERSION" core="$C_VERSION"
	[ "$1" != 0 ] || success=true
	case "$reason" in *[!a-z_]* ) reason=failed ;; esac
	case "$installed_app" in *[!a-zA-Z0-9.+~_-]* ) installed_app='' ;; esac
	case "$installed_core" in *[!a-zA-Z0-9.+~_-]* ) installed_core='' ;; esac
	case "$variant" in base | full | tiny | custom | '') ;; *) variant='' ;; esac
	valid_release_version "$app" loki || app=''
	valid_release_version "$core" loki-core || core=''
	printf '{"schema":1,"success":%s,"reason":"%s","available":%s,"installed":{"app":"%s","core":"%s","variant":"%s"},"latest":{"app":"%s","core":"%s"}}\n' \
		"$success" "$reason" "$CHECK_AVAILABLE" "$installed_app" "$installed_core" "$variant" "$app" "$core" >&3
}

check_updates() {
	local name
	for name in "loki_${F_VERSION}_all.$EXT" "luci-app-loki_${F_VERSION}_all.$EXT"; do
		if [ -z "$(checksum_of "$name" "$WORK/loki.sums")" ] || [ -z "$(asset_url loki "$name")" ]; then
			fail 1 release "$(t 'The release has no package for this system' 'В релизе нет пакета для этой системы')"
		fi
	done
	if [ "$I18N" = 1 ]; then
		name="luci-i18n-loki-ru_${F_VERSION}_all.$EXT"
		if [ -z "$(checksum_of "$name" "$WORK/loki.sums")" ] || [ -z "$(asset_url loki "$name")" ]; then
			fail 1 release "$(t 'The release has no translation package' 'В релизе нет пакета перевода')"
		fi
	fi
	if [ "$CORE_VARIANT" != custom ]; then
		name=$(core_file "$CORE_VARIANT")
		if [ -z "$(checksum_of "$name" "$WORK/core.sums")" ] || [ -z "$(asset_url core "$name")" ]; then
			fail 1 unsupported_arch "$(t 'The release has no core for this architecture and build' 'В релизе нет ядра для этой архитектуры и варианта сборки')"
		fi
	fi
	[ "$NEED_LOKI$NEED_APP$NEED_I18N" = 000 ] && [ "$CORE_ACTION" = none ] || CHECK_AVAILABLE=true
	finish 0
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

pulled_in() {
	[ "$PM" = opkg ] && [ -n "$*" ] || return 0
	if awk -v names=" $* " '
		/^Package: / { ours = index(names, " " $2 " ") > 0; auto = 0 }
		ours && $0 == "Status: install user installed" { $0 = "Status: install ok installed" }
		ours && $0 == "Auto-Installed: yes" { auto = 1 }
		ours && $0 == "" { if (!auto) print "Auto-Installed: yes"; ours = 0 }
		{ print }
		END { if (ours && !auto) print "Auto-Installed: yes" }' /usr/lib/opkg/status >/usr/lib/opkg/status.loki; then
		mv /usr/lib/opkg/status.loki /usr/lib/opkg/status
	else
		rm -f /usr/lib/opkg/status.loki
	fi
}

predelete_core() { # apk upgrades by writing beside the old file: make room first, a compressed copy in RAM
	[ "$PREDELETE_CORE" = 1 ] || return 0
	# /tmp is RAM, and its df counts what tmpfs may grow to: MemAvailable is what is free
	if [ $(($(file_kb /usr/bin/loki-core) / 2 + 16384)) -lt "$(mem_available_kb)" ] &&
		gzip -1 -c /usr/bin/loki-core >"$WORK/loki-core.old.gz" 2>/dev/null; then
		log "a compressed copy of the old core is in RAM until the transaction ends"
	else
		rm -f "$WORK/loki-core.old.gz"
		log "no copy of the old core: RAM is short"
	fi
	rm -f /usr/bin/loki-core
	log "removed the old core to make room for the new one"
}

main() {
	parse_args "$@"
	if [ "$MODE" = check ]; then exec 3>&1; exec 1>&2; LOG=/dev/null; fi
	pick_language
	setup_output
	[ -z "$MIRROR" ] || valid_mirror "$MIRROR" || fail 1 source 'The release source must use a valid HTTPS URL'
	[ "$ASK_VARIANT" = 0 ] || [ -n "$BAD_ARG" ] || may_ask || BAD_ARG=variant_tty
	[ -z "$BAD_ARG" ] || usage_error
	log "install.sh $* ($(date))"
	trap on_signal INT TERM HUP PIPE
	[ "$(id -u)" = 0 ] || fail 1 not_root "$(t 'Run the installer as root' 'Запустите установщик от имени root')"
	[ -r /etc/openwrt_release ] || fail 1 not_openwrt "$(t 'This installer runs only on OpenWrt' 'Установщик работает только на OpenWrt')"
	detect_package_manager
	WORK=$(mktemp -d /tmp/loki-install.XXXXXX) || fail 1 no_memory "$(t 'Cannot create a directory in /tmp' 'Не удалось создать папку в /tmp')"
	if [ "$MODE" = check ]; then
		INTERACTIVE=0
		identify_system
		read_state
		fetch_release loki
		fetch_release core
		decide_loki
		decide_core
		check_updates
		finish 0
	fi
	[ "$LOG" != /dev/null ] || LOG=$(mktemp /tmp/loki-install-log.XXXXXX) || fail 1 log 'Cannot create the installer log'
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
