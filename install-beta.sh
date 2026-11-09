#!/bin/sh
# Download the pinned beta kit; all package changes use its existing transaction worker.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
WORK='' DOWNLOAD_PID='' KEEP=0
DOWNLOAD_SECONDS=35
BETA_VERSION=2.0.1

fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
cleanup() {
    if [ -n "$DOWNLOAD_PID" ]; then
        kill "$DOWNLOAD_PID" 2>/dev/null
        wait "$DOWNLOAD_PID" 2>/dev/null
    fi
    if [ -n "$WORK" ] && [ "$KEEP" = 0 ]; then rm -rf -- "$WORK"; fi
}

firmware_value() {
    sed -n "s/^$1='\([^']*\)'$/\1/p" /etc/openwrt_release
}

fetch_kit() {
    local waited=0 status
    (
        # BusyBox and dash use different block units; both bounds allow this 25.5 MB kit.
        ulimit -f 57344 || exit 1
        exec wget -T 30 -O "$WORK/kit.tar.gz" "$1"
    ) &
    DOWNLOAD_PID=$!
    while kill -0 "$DOWNLOAD_PID" 2>/dev/null; do
        if [ "$waited" -ge "$DOWNLOAD_SECONDS" ]; then
            kill "$DOWNLOAD_PID" 2>/dev/null
            wait "$DOWNLOAD_PID" 2>/dev/null
            DOWNLOAD_PID=''
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$DOWNLOAD_PID"
    status=$?
    DOWNLOAD_PID=''
    return "$status"
}

main() {
    local release arch version archive archive_sha manifest_sha expected_bytes available space kit status
    local kit_bytes package_bytes payload_bytes reserve memory_reserve extraction_peak required_ram required_tmp overhead
    [ "$#" = 0 ] || fail 'Этот загрузчик устанавливает только текущую бету без дополнительных параметров.'
    [ "$(id -u)" = 0 ] || fail 'Подключитесь по SSH от root.'
    [ -r /etc/openwrt_release ] || fail 'Требуется OpenWrt 24.10 или 25.12.'
    release=$(firmware_value DISTRIB_RELEASE)
    arch=$(firmware_value DISTRIB_ARCH)
    [ "$arch" = aarch64_cortex-a53 ] || fail 'Для этой беты нужен aarch64_cortex-a53; другие архитектуры не поддерживаются загрузчиком.'
    case "$release" in
        24.10|24.10.*)
            version=24.10
            archive_sha=0dca8bf823528b1da9a26592698a71e152149c9b4fa3cf8ab022d51bbca3455e
            manifest_sha=f50eff8fdeedc58a1f3cd0031d25ca4f2e2324040d3e53ef959c6b1f356bd5c5
            expected_bytes=25501436
            kit_bytes=46938791
            package_bytes=13284688
            payload_bytes=36596111
            ;;
        25.12|25.12.*)
            version=25.12
            archive_sha=42e7266a238184d415caf029441740cdaf4a8d02ccef9688d69f164e37926a77
            manifest_sha=19f88372de8c3cf71e276026e95322041c619667fb75dec67ce47c11f37f8fd6
            expected_bytes=25487056
            kit_bytes=46956031
            package_bytes=13299620
            payload_bytes=36601458
            ;;
        *) fail 'Эта бета поддерживает OpenWrt 24.10 и 25.12.' ;;
    esac
    available=$(awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ && $3 == "kB" { print $2; exit }' /proc/meminfo)
    space=$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 { print $4 }')
    case "$available:$space" in *[!0-9:]*|:*|*:) fail 'Не удалось проверить свободную память.' ;; esac
    # Mirror candidate_need() for the checksum-pinned kit; the archive is removed before preflight.
    reserve=$((package_bytes + payload_bytes))
    if [ "$((2 * package_bytes))" -gt "$reserve" ]; then reserve=$((2 * package_bytes)); fi
    if [ "$reserve" -lt 4194304 ]; then reserve=4194304; fi
    memory_reserve=$reserve
    if [ "$memory_reserve" -lt 50331648 ]; then memory_reserve=50331648; fi
    # Cover filesystem block rounding and the small launcher/extraction processes.
    overhead=4194304
    extraction_peak=$((expected_bytes + kit_bytes))
    required_ram=$((kit_bytes + memory_reserve))
    required_tmp=$((kit_bytes + reserve))
    if [ "$extraction_peak" -gt "$required_ram" ]; then required_ram=$extraction_peak; fi
    if [ "$extraction_peak" -gt "$required_tmp" ]; then required_tmp=$extraction_peak; fi
    required_ram=$(((required_ram + overhead + 1023) / 1024))
    required_tmp=$(((required_tmp + overhead + 1023) / 1024))
    if [ "$available" -lt "$required_ram" ] || [ "$space" -lt "$required_tmp" ]; then
        fail "Недостаточно ресурсов. RAM: доступно $((available / 1024)) МиБ, требуется $(((required_ram + 1023) / 1024)) МиБ; /tmp: доступно $((space / 1024)) МиБ, требуется $(((required_tmp + 1023) / 1024)) МиБ."
    fi
    WORK=$(mktemp -d /tmp/loki-beta.XXXXXX) || fail 'Не удалось создать закрытый временный каталог.'
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    archive="loki-$BETA_VERSION-r10-openwrt-$version-aarch64_cortex-a53-candidate.tar.gz"
    printf '[1/4] Загрузка LoKi %s beta для OpenWrt %s…\n' "$BETA_VERSION" "$version"
    fetch_kit "https://github.com/Zagorsky17/LoKi/releases/download/$BETA_VERSION/$archive" ||
        fail 'Загрузка не завершена. Проверьте доступ к GitHub, HTTPS и повторите команду.'
    [ "$(wc -c < "$WORK/kit.tar.gz" | tr -d '[:space:]')" = "$expected_bytes" ] || fail 'Размер загруженного комплекта не совпал.'
    printf '%s  %s\n' "$archive_sha" "$WORK/kit.tar.gz" | sha256sum -c - >/dev/null || fail 'SHA256 комплекта не совпала; установка остановлена.'
    printf '[2/4] Проверка файлов комплекта…\n'
    tar -xzf "$WORK/kit.tar.gz" -C "$WORK" || fail 'Не удалось распаковать комплект.'
    rm -f "$WORK/kit.tar.gz"
    kit="$WORK/openwrt-$version-aarch64_cortex-a53"
    (cd "$kit" && sha256sum -c SHA256SUMS >/dev/null) || fail 'Проверка файлов не пройдена.'
    printf '[3/4] Проверка среды и конфигурации; пакеты ещё не меняются…\n'
    if ! sh "$kit/preflight.sh" --manifest-sha256 "$manifest_sha" > "$WORK/preflight.json"; then
        cat "$WORK/preflight.json" >&2
        fail 'Preflight отказал: причина указана выше. Установка не начата.'
    fi
    printf '[4/4] Установка компонентов LoKi…\n'
    # A signal or failed transaction must retain the kit needed for explicit recovery.
    KEEP=1
    sh "$kit/component-update.sh" install "$kit" "$manifest_sha" > "$WORK/install.json"
    status=$?
    if [ "$status" != 0 ]; then
        cat "$WORK/install.json" >&2
        printf '[!] Комплект сохранён: %s\n[!] Для восстановления: sh %s/component-update.sh recover\n' "$kit" "$kit" >&2
        return "$status"
    fi
    KEEP=0
    printf '[+] LoKi установлен. Откройте LoKi в LuCI, настройте подключения и DNS, затем нажмите Start.\n'
}

main "$@"
