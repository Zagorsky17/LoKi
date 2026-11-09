#!/bin/sh
# Read-only LoKi release metadata check for SSH and the Components page.
# Prepared private kits use the common transaction worker; legacy mutations stay closed.
# Exit codes: 0 check/help completed, 1 refused/failed, 2 invalid options.
# shellcheck shell=dash
# Releases use the public GitHub API or the configured HTTPS metadata mirror.
# Standard proxy variables and NO_COLOR retain their existing meaning.

set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

LOKI_REPO=Zagorsky17/LoKi
CORE_REPO=Zagorsky17/LoKi
API_URL=https://api.github.com
MIRROR=${LOKI_DOWNLOAD_URL:-}
LOG=/dev/null
OUR_PACKAGES="loki luci-app-loki luci-i18n-loki-ru loki-core"
FOREIGN_CORES="sing-box sing-box-tiny sing-box-extended podkop-engine podkop-engine-full sing-box-lx sing-box-x rust-x steer-box-connector"
FOREIGN_CORE_FILES="/usr/bin/sing-box /etc/init.d/sing-box /usr/libexec/sing-box-core /etc/sing-box-version.cache /usr/lib/libcronet.so"

MODE=install VARIANT='' ASK_VARIANT=0 PURGE=0 LANG_OPT='' BAD_ARG='' HELP=0
RU=0 C_STEP='' C_OK='' C_WARN='' C_ERR='' C_OFF=''
WORK='' PM='' PM_DB='' EXT='' ARCH='' RELEASE='' FLASH_MOUNT=/ FLASH_FS=''
LOKI_OLD='' APP_OLD='' I18N_OLD='' CORE_OLD='' CORE_OLD_VARIANT='' CONFIG_VERSION=''
FOREIGN_PKGS='' FOREIGN_WORLD='' FOREIGN_FILES=''
F_VERSION='' F_TAG='' F_CORE_MIN='' C_VERSION='' C_TAG='' C_LOKI_MIN=''
I18N=0 NEED_LOKI=0 NEED_APP=0 NEED_I18N=0
CORE_ACTION=none CORE_VARIANT=''
RESULT_LOKI='' RESULT_CORE=''
CHECK_AVAILABLE=false

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
	cleanup
	exit "$1"
}

cleanup() {
	[ -z "$WORK" ] || rm -rf "$WORK"
}

# shellcheck disable=SC2317
on_signal() {
	trap '' INT TERM HUP PIPE
	fail 1 interrupted "$(t 'Interrupted: nothing was changed' 'Прервано, ничего не изменено')"
}

usage_error() {
	local message
	case "$BAD_ARG" in
	check) message=$(t 'The option --check cannot install, remove or change a build' 'Параметр --check нельзя совмещать с установкой, удалением или сменой сборки') ;;
	variant) message=$(t 'The option --variant takes base, full or tiny' 'Параметр --variant принимает base, full или tiny') ;;
	lang) message=$(t 'The option --lang takes ru or en' 'Параметр --lang принимает ru или en') ;;
	purge) message=$(t 'The option --purge goes with --uninstall' 'Параметр --purge работает только с --uninstall') ;;
	uninstall) message=$(t 'The option --uninstall takes no --variant' 'Параметр --uninstall не сочетается с --variant') ;;
	variant_tty) message=$(t 'The option --variant with no value asks for the build and needs a terminal' 'Параметр --variant без значения спрашивает сборку и работает только в терминале') ;;
	value:*) message=$(t '%s needs a value' 'Параметру %s нужно значение' "${BAD_ARG#value:}") ;;
	*) message=$(t 'Unknown option: %s' 'Неизвестный параметр: %s' "${BAD_ARG#unknown:}") ;;
	esac
	say '[x]' "$C_ERR" "$message" >&2
	usage >&2
	exit 2
}

usage() {
	printf '%s\n' "$(t 'Options: --check, --help, --lang ru|en' 'Параметры: --check, --help, --lang ru|en')"
	printf '%s\n' '--candidate DIRECTORY MANIFEST_SHA256 install|update|uninstall' '--recover'
	printf '%s\n' "$(t 'Legacy mutating options are disabled; use a prepared candidate kit.' 'Прежние параметры изменения пакетов отключены; используйте подготовленный комплект.')"
}

is_number() {
	case "$1" in '' | *[!0-9]*) return 1 ;; esac
}

contains() { # contains WORD LIST
	case " $2 " in *" $1 "*) return 0 ;; esac
	return 1
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

metadata_resources_available() {
	local available space
	available=$(mem_available_kb)
	space=$(free_kb /tmp)
	case "$available:$space" in *[!0-9:]* | :* | *:) return 1 ;; esac
	[ "$available" -ge 49152 ] 2>/dev/null && [ "$space" -ge 4096 ] 2>/dev/null
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

fetch() { # fetch URL FILE [ACCEPT]: 0; 2 when the server answered with an HTTP error, 3 when that was GitHub's rate limit; 1 when it was not reached
	local status
	case "$2" in *.json | *.release | *.sums)
		# Metadata is small; a peer cannot fill tmpfs or keep the check alive indefinitely.
		( ulimit -f 2048; deadline 35 wget -T 30 ${3:+"--header=Accept: $3"} -O "$2" "$1" ) 2>"$WORK/fetch.log" ;;
	*) wget -T 30 ${3:+"--header=Accept: $3"} -O "$2" "$1" 2>"$WORK/fetch.log" ;;
	esac
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
		if ! metadata_resources_available; then
			rm -f "$2"
			fail 1 no_memory "$(t 'Not enough RAM for the downloads' 'Не хватает оперативной памяти для загрузки')" \
				"$(t 'Free some RAM and run the installer again' 'Освободите память и запустите установщик снова')"
		fi
		rm -f "$2"
		log "download $1"
		fetch "$1" "$2" "${3:-}"
		status=$?
		[ "$status" != 0 ] || [ ! -s "$2" ] || return 0
		case $status in 2 | 3) rm -f "$2"; return "$status" ;; esac
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

valid_mirror() {
	case "$1" in *[!a-zA-Z0-9:./_~\[\]-]* | */../* | */./*) return 1 ;; esac
	printf '%s' "$1" | grep -Eq '^https://([a-zA-Z0-9.-]+|\[[a-fA-F0-9:]+\])(:[0-9]{1,5})?(/[a-zA-Z0-9._~/-]*)?$'
}

valid_asset_url() {
	local asset=${1#https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/}
	[ "$asset" != "$1" ] || return 1
	case "$asset" in '' | *[!0-9]*) return 1 ;; esac
}

asset_url() { # only the chosen HTTPS release namespace may supply assets
	local url
	if [ -n "$MIRROR" ]; then
		valid_mirror "$MIRROR" || return 1
		if [ "$1" = core ]; then release_url "$CORE_REPO" "$C_TAG" "$2"; else release_url "$LOKI_REPO" "$F_TAG" "$2"; fi
	else
		url=$(jsonfilter -i "$WORK/$1.release" -e "@.assets[@.name=\"$2\"].url" 2>/dev/null) || return 1
		valid_asset_url "$url" || return 1
		printf '%s' "$url"
	fi
}

rate_limited() {
	fail 1 rate_limit "$(t 'GitHub refuses more requests from this address for now: it takes 60 an hour without an account' 'GitHub пока не принимает запросы с этого адреса: без входа он даёт 60 запросов в час')" \
		"$(t 'Run the installer again later: the limit is reset within the hour' 'Запустите установщик снова позже: лимит сбрасывается в течение часа')"
}

checksum_of() { # exactly one canonical SHA256 entry for this asset
	awk -v n="$1" '$2 == n || $2 == "*" n { count++; digest=$1; fields=NF } END { if (count == 1 && fields == 2 && length(digest) == 64 && digest !~ /[^a-fA-F0-9]/) print tolower(digest) }' "$2"
}

verify_named() {
	local expected
	expected=$(checksum_of "$2" "$3")
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
	if [ "${LOKI_ENABLED:-}" = 0 ] && pidof sing-box sing-box-core >/dev/null 2>&1; then
		t 'Another application runs sing-box, and the internet of the router may go through it: stop it and run the installer again' \
			'Работает sing-box другого приложения, и интернет роутера может идти через него: остановите его и запустите установщик снова'
	elif ! resolves "$host"; then
		t 'The router cannot resolve %s: check its DNS and internet connection' 'Роутер не может определить адрес %s: проверьте DNS и подключение к интернету' "$host"
	else
		t 'Check that %s opens from the router' 'Проверьте, открывается ли %s с роутера' "$host"
	fi
}

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
		C_ERR=$(printf '\033[1;31m') C_OFF=$(printf '\033[0m')
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
	local major minor reason ram
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
		warn low_memory "$(t 'This router has %s MB of RAM; LoKi has not been validated for this memory size' 'У роутера %s МБ оперативной памяти; требования LoKi для этого объёма не проверены' "$ram")"
	fi

	if pidof opkg apk >/dev/null 2>&1; then
		fail 1 locked "$(t 'The package manager is busy' 'Менеджер пакетов занят')"
	fi
	pm_works || fail 1 package_manager "$(t '%s does not work' '%s не работает' "$PM")" \
		"$(t 'Its database may be damaged: %s' 'Возможно, повреждена его база %s' "$PM_DB")"
}

read_state() {
	local name file owner
	refresh_db
	LOKI_OLD=$(pkg_version loki)
	if [ -n "$LOKI_OLD" ] && [ "$(pkg_url loki)" != "https://github.com/$LOKI_REPO" ]; then
		fail 1 check "$(t 'A package from another project occupies loki; LoKi requires a clean installation' 'Имя loki занято пакетом другого проекта; LoKi требует чистой установки')"
	fi
	APP_OLD=$(pkg_version luci-app-loki)
	I18N_OLD=$(pkg_version luci-i18n-loki-ru)
	CORE_OLD=$(pkg_version loki-core)
	[ -z "$CORE_OLD" ] || CORE_OLD_VARIANT=$(cat /usr/share/loki-core/variant 2>/dev/null)
	[ ! -f /etc/config/loki ] || CONFIG_VERSION=$(uci -q get loki.settings.config_version)
	printf '%s\n' "$CONFIG_VERSION" | grep -Eq '^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$' || CONFIG_VERSION=unknown

	for name in $FOREIGN_CORES; do
		if [ -n "$(pkg_version "$name")" ]; then
			FOREIGN_PKGS="$FOREIGN_PKGS $name"
		elif in_world "$name"; then
			FOREIGN_WORLD="$FOREIGN_WORLD $name"
		fi
	done
	for file in $FOREIGN_CORE_FILES; do
		[ -e "$file" ] || continue
		# loki-core installs these itself, and an opkg run that ran out of space cuts its file list
		[ -z "$CORE_OLD" ] || case "$file" in /usr/bin/loki-core | /etc/init.d/loki-core) continue ;; esac
		owner=$(file_owner "$file")
		[ -n "$owner" ] || FOREIGN_FILES="$FOREIGN_FILES $file"
	done
	owner=$(file_owner /usr/bin/loki-core)
	if [ -n "$owner" ] && ! contains "$owner" "$OUR_PACKAGES $FOREIGN_PKGS"; then
		FOREIGN_PKGS="$FOREIGN_PKGS $owner"
	fi
    [ -z "$FOREIGN_PKGS$FOREIGN_WORLD$FOREIGN_FILES" ] ||
        fail 1 conflict "$(t 'Conflicting packages or files must be resolved before installing LoKi' 'Перед установкой LoKi нужно устранить конфликтующие пакеты или файлы')"
	log "installed: loki ${LOKI_OLD:-none}, loki-core ${CORE_OLD:-none} ${CORE_OLD_VARIANT}," \
		"other cores:${FOREIGN_PKGS:- none}, files of no package:${FOREIGN_FILES:- none}, config ${CONFIG_VERSION:-none}"
}

valid_release_version() {
	case "$1" in '' | *[!0-9.r-]*) return 1 ;; esac
	if [ "$2" = loki ]; then
		printf '%s' "$1" | grep -Eq '^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'
	else
		printf '%s' "$1" | grep -Eq '^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}-r[0-9]{1,9}$'
	fi
}

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
	local repo=$LOKI_REPO name=LoKi package=loki manifest="$WORK/$1.json" asset=release.json url status=0
	[ "$1" = loki ] || repo=$CORE_REPO name=loki-core package=loki-core asset=core-release.json
	if [ -z "$MIRROR" ]; then
		download "$API_URL/repos/$repo/releases/latest" "$WORK/$1.release"
		status=$?
	fi
	if [ "$status" = 0 ]; then
		url=$(asset_url "$1" "$asset")
		status=2
		[ -z "$url" ] || { download "$url" "$manifest" application/octet-stream; status=$?; }
	fi
	case $status in
	0) ;;
	2)
		fail 1 release "$(t 'The latest %s release has no %s' 'В последнем релизе %s нет %s' "$name" "$asset")" \
			"$(t 'Download the latest install.sh' 'Скачайте свежий install.sh')"
		;;
	3) rate_limited ;;
	*) fail 1 network "$(t 'Cannot download the information on the %s release' 'Не удалось скачать сведения о релизе %s' "$name")" "$(network_hint)" ;;
	esac
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
	fetch_or_fail "$(asset_url "$1" SHA256SUMS)" "$WORK/$1.sums" SHA256SUMS "$package"
	verify_named "$manifest" "$asset" "$WORK/$1.sums" ||
		fail 1 checksum "$(t 'The release manifest failed SHA256 verification' 'Manifest релиза не прошёл проверку SHA256')"
}

resolve_release() {
	step release "$(t 'Looking for the latest version' 'Поиск последней версии')"
	fetch_release loki
	fetch_release core
	decide_loki
	decide_core
}

decide_loki() { # the LoKi packages to install, NEED_*, and the LoKi that will run
	if [ -n "$LOKI_OLD" ]; then
		[ -z "$I18N_OLD" ] || I18N=1
	else
		# a first install brings the page's Russian translation unless LuCI is set to another language
		case "$(uci -q get luci.main.lang)" in '' | auto | ru*) I18N=1 ;; esac
	fi
	RESULT_LOKI=$F_VERSION
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

decide_core() { # Select the installed build for the metadata comparison only.
	local order text
	if [ -n "$CORE_OLD" ]; then
		case "$CORE_OLD_VARIANT" in base | full | tiny) CORE_VARIANT=$CORE_OLD_VARIANT ;; *) CORE_VARIANT=custom ;; esac
	else
		CORE_VARIANT=base
	fi
	if [ "$CORE_VARIANT" = custom ]; then
		if [ -n "$F_CORE_MIN" ] && older "$CORE_OLD" "$F_CORE_MIN"; then
			text=$(t 'The custom build of loki-core %s is too old: loki %s needs %s or newer' 'Кастомная сборка loki-core %s слишком старая: loki %s требует %s или новее' "$CORE_OLD" "$RESULT_LOKI" "$F_CORE_MIN")
			fail 1 incompatible "$text" "$(t 'Install an official build: --variant base, full or tiny' 'Поставьте официальную сборку: --variant base, full или tiny')"
		elif older "$CORE_OLD" "$C_VERSION"; then
			warn custom_outdated "$(t 'The custom build of loki-core %s is outdated: %s is available' 'Кастомная сборка loki-core %s устарела: доступна %s' "$CORE_OLD" "$C_VERSION")"
		fi
		RESULT_CORE=$CORE_OLD
		return 0
	fi
	RESULT_CORE=$C_VERSION
	if [ -z "$CORE_OLD" ]; then
		CORE_ACTION=install
	else
		order=$(vercmp "$CORE_OLD" "$C_VERSION")
		if [ "$order" = 1 ]; then
			info "$(t 'loki-core %s is newer than the latest release %s and stays' 'loki-core %s новее последнего релиза %s и остаётся' "$CORE_OLD" "$C_VERSION")"
			RESULT_CORE=$CORE_OLD
		elif [ "$order" != 0 ] || [ "$CORE_VARIANT" != "$CORE_OLD_VARIANT" ]; then
			CORE_ACTION=install
		fi
	fi
	check_compatible
}

check_compatible() { # the LoKi and the core that will run work together
	# what a core needs of Loki only its release says
	if [ "$RESULT_CORE" = "$C_VERSION" ] && [ -n "$C_LOKI_MIN" ] && older "$RESULT_LOKI" "$C_LOKI_MIN"; then
		fail 1 incompatible "$(t 'loki-core %s needs loki %s or newer, and loki %s would run' 'loki-core %s требует loki %s или новее, а будет loki %s' "$C_VERSION" "$C_LOKI_MIN" "$RESULT_LOKI")"
	fi
	if [ -n "$F_CORE_MIN" ] && older "$RESULT_CORE" "$F_CORE_MIN"; then
		fail 1 incompatible "$(t 'loki %s needs loki-core %s or newer, and the latest is %s' 'loki %s требует loki-core %s или новее, а последний релиз — %s' "$RESULT_LOKI" "$F_CORE_MIN" "$C_VERSION")" \
			"$(t 'That release is not out yet: run the installer later' 'Этот релиз ещё не вышел, запустите установщик позже')"
	fi
}

core_file() { # core_file VARIANT
	printf 'loki-core_%s_%s_%s.%s' "$C_VERSION" "$1" "$ARCH" "$EXT"
}

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
		--uninstall) [ "$MODE" = install ] || BAD_ARG=check; MODE=uninstall ;;
		--purge) PURGE=1 ;;
		--quiet) : ;;
		--help | -h) HELP=1 ;;
		*) BAD_ARG="unknown:$1" && return ;;
		esac
		shift
	done
	case "$LANG_OPT" in '' | ru | en) ;; *) LANG_OPT='' BAD_ARG=lang && return ;; esac
	case "$VARIANT" in '' | base | full | tiny) ;; *) BAD_ARG=variant && return ;; esac
	[ "$MODE" != check ] || { [ "$PURGE$ASK_VARIANT" = 00 ] && [ -z "$VARIANT" ]; } || { BAD_ARG=check; return; }
	[ "$PURGE" = 0 ] || [ "$MODE" = uninstall ] || { BAD_ARG=purge && return; }
	[ "$MODE" != uninstall ] || { [ -z "$VARIANT" ] && [ "$ASK_VARIANT" = 0 ]; } || BAD_ARG=uninstall
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

main() {
	# A prepared kit is explicit; legacy options cannot bypass its admission checks.
	if [ "${1:-}" = --candidate ]; then
		[ "$#" = 4 ] || exit 2
		case "$4" in install|update|uninstall) ;; *) exit 2 ;; esac
		exec /bin/sh "$(dirname -- "$0")/component-update.sh" "$4" "$2" "$3"
	fi
	if [ "${1:-}" = --recover ]; then
		[ "$#" = 1 ] || exit 2
		exec /bin/sh "$(dirname -- "$0")/component-update.sh" recover
	fi
	parse_args "$@"
	pick_language
	setup_output
	[ -z "$BAD_ARG" ] || usage_error
	if [ "$HELP" = 1 ]; then
		usage
		exit 0
	fi
	if [ "$MODE" != check ]; then
		usage >&2
		exit 1
	fi
	exec 3>&1
	exec 1>&2
	LOG=/dev/null
	[ -z "$MIRROR" ] || valid_mirror "$MIRROR" ||
		fail 1 source "$(t 'The release source must use a valid HTTPS URL' 'Источник релиза должен использовать допустимый HTTPS URL')"
	log "install.sh $* ($(date))"
	trap on_signal INT TERM HUP PIPE
	[ "$(id -u)" = 0 ] || fail 1 not_root "$(t 'Run the installer as root' 'Запустите установщик от имени root')"
	[ -r /etc/openwrt_release ] || fail 1 not_openwrt "$(t 'This installer runs only on OpenWrt' 'Установщик работает только на OpenWrt')"
	detect_package_manager
	umask 077
	WORK=$(mktemp -d /tmp/loki-install.XXXXXX) || fail 1 no_memory "$(t 'Cannot create a directory in /tmp' 'Не удалось создать папку в /tmp')"
	identify_system
	case "$ARCH" in '' | *[!a-zA-Z0-9_-]*) fail 1 unsupported_arch "$(t 'Invalid package architecture' 'Недопустимая архитектура пакетов')" ;; esac
	if ! metadata_resources_available; then
		fail 1 no_memory "$(t 'Not enough RAM for the update check' 'Не хватает оперативной памяти для проверки обновлений')"
	fi
	check_system
	read_state
	resolve_release
	check_updates
}

main "$@"
