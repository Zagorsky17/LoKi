#!/bin/sh
# Download the pinned beta kit; all package changes use its existing transaction worker.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
WORK='' DOWNLOAD_PID='' KEEP=0
DOWNLOAD_SECONDS=35

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
    [ "$#" = 0 ] || fail 'Этот загрузчик устанавливает только текущую бету без дополнительных параметров.'
    [ "$(id -u)" = 0 ] || fail 'Подключитесь по SSH от root.'
    [ -r /etc/openwrt_release ] || fail 'Требуется OpenWrt 24.10 или 25.12.'
    release=$(firmware_value DISTRIB_RELEASE)
    arch=$(firmware_value DISTRIB_ARCH)
    [ "$arch" = aarch64_cortex-a53 ] || fail 'Для этой беты нужен aarch64_cortex-a53; другие архитектуры не поддерживаются загрузчиком.'
    case "$release" in
        24.10|24.10.*)
            version=24.10
            archive_sha=87327a8f430e1796624c37e852815603c0e7457078f83f907acc84374f137c52
            manifest_sha=2bbf0b8d48cdaf9111520b20b54b8e00007cecc35f5a267fa03c5dbefecca8ba
            expected_bytes=25501443
            ;;
        25.12|25.12.*)
            version=25.12
            archive_sha=c9f1163d5bb9cb7c286802b63ff3660e7c8422852227a5687dea5122980741c9
            manifest_sha=60330a1e5a35778af13f4d50fa6944852bcbbd781fffaf0f157ecfeb929de48f
            expected_bytes=25487033
            ;;
        *) fail 'Эта бета поддерживает OpenWrt 24.10 и 25.12.' ;;
    esac
    available=$(awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ && $3 == "kB" { print $2; exit }' /proc/meminfo)
    space=$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 { print $4 }')
    case "$available:$space" in *[!0-9:]*|:*|*:) fail 'Не удалось проверить свободную память.' ;; esac
    if [ "$available" -lt 163840 ] || [ "$space" -lt 163840 ]; then
        fail 'Перед загрузкой требуется 160 МиБ MemAvailable и свободного /tmp. Общие пакеты и службы автоматически не изменяются.'
    fi
    WORK=$(mktemp -d /tmp/loki-beta.XXXXXX) || fail 'Не удалось создать закрытый временный каталог.'
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    archive="loki-2.0.0-r10-openwrt-$version-aarch64_cortex-a53-candidate.tar.gz"
    printf '[1/4] Загрузка LoKi 2.0.0 beta для OpenWrt %s…\n' "$version"
    fetch_kit "https://github.com/Zagorsky17/LoKi/releases/download/2.0.0/$archive" ||
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
