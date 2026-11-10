# Installing LoKi on OpenWrt

[Русский](INSTALL.ru.md) · English · [简体中文](INSTALL.zh.md)

LoKi installs as an application on OpenWrt 24.10 with `opkg` and OpenWrt 25.12 with `apk`. The installer selects packages by the firmware's package manager and architecture, rather than the device manufacturer or model. The release must contain a `loki-core` build for that architecture.

## Installation

Connect to OpenWrt over SSH as `root` and run:

```sh
(set -o pipefail; wget -O - https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install-loki.sh | sh)
```

This is the permanent installation URL. The loader downloads the complete `install.sh` into a private temporary file and runs it only after the download succeeds. The Components page in LuCI uses the same installer.

The installer reads the latest published release, selects application packages and a compatible core, verifies SHA256, and simulates the transaction with the native package manager. Required dependencies are installed from the configured OpenWrt feeds. It does not flash firmware or import another application's configuration.

Free space is assessed on the filesystem where packages are installed. RAM and `/tmp` requirements are calculated from the downloaded packages and installation operations; there is no fixed 160 MiB requirement or mandatory offline kit.

If another `sing-box` application is running, stop it before trying again. The script does not remove its packages or settings. If the package manager cannot obtain dependencies, reports an incompatible Linux kernel or finds conflicting files, keep the specific error; do not bypass it with force-install options.

After a successful installation, reopen LuCI and the LoKi page. Add connections, configure sections and DNS, save the settings and select Start. A fresh installation does not apply an empty routing configuration. Configure DNS encryption separately by selecting DoH or DoT and entering a matching server address.

## Updating and uninstalling

To update, repeat the main installation command or use the Components page in LuCI. The installer preserves LoKi configuration and the previous service state: a stopped service stays stopped, and a previously running service starts after the update.

To uninstall, download the same installer and run it with `--uninstall`:

```sh
script=$(mktemp /tmp/loki-uninstall.XXXXXX) &&
wget -T 30 -O "$script" https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install.sh &&
sh "$script" --uninstall
rm -f "$script"
```

Normal removal preserves LoKi settings. Add `--purge` after `--uninstall` to delete them as well; use it only when you intend to remove those settings.

## If an operation stops

The installer identifies the failed stage and its log path. Keep the terminal output and that log. Include the OpenWrt version, architecture and package manager:

```sh
cat /etc/openwrt_release
grep MemAvailable /proc/meminfo
df -Pk / /tmp
```

The log may contain temporary signed download URLs. Remove personal tokens, passwords and connection details before publishing it.

SHA256 checks that files match the published checksums. Trust rests on the project repository and HTTPS; there is no separate digital signature. Linux bench checks do not replace testing real package hooks, rpcd/procd and the workload on a particular OpenWrt device.
