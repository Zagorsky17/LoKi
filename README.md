# LoKi

Rule-based traffic routing for OpenWrt with the dedicated loki-core engine.

[![LoKi stable release](https://img.shields.io/github/v/release/Zagorsky17/LoKi?label=release&color=178f83&style=flat)](https://github.com/Zagorsky17/LoKi/releases/latest)

[Русский](README.ru.md) · English · [简体中文](README.zh.md)

[Requirements](#compatible-routers) · [Features](#features) · [Stability](#what-supports-stable-operation) · [Installation](#installation) · [Report an issue](https://github.com/Zagorsky17/LoKi/issues)

## Compatible routers

LoKi runs on OpenWrt devices. Compatibility depends on the firmware, CPU architecture and available resources.

| Parameter | Requirement |
| --- | --- |
| Firmware | OpenWrt **24.10** with `opkg` or **25.12** with `apk`. |
| CPU | ARM/ARM64, MIPS/MIPS64, x86/x86-64, RISC-V64 and LoongArch64, provided the [release](https://github.com/Zagorsky17/LoKi/releases/latest) includes a package for the exact firmware architecture. |
| RAM | The installer uses **128 MB** as a guideline; **256 MB or more** is recommended for headroom. Usage depends on subscriptions, rule lists and connection counts; operation on 128 MB has not been separately verified. |
| Flash storage | Free space for the application, core and dependencies. The amount depends on the architecture and installed packages; the installer calculates it before installation. |
| Access | SSH as `root`, LuCI for browser management, and HTTPS access to GitHub and OpenWrt feeds. |

> **LoKi 2.0.5 — stable release.** Operation, uninstalling and recovery after a failure are confirmed on Cudy WR3000S v1 with OpenWrt 25.12.6. Other devices and OpenWrt 24.10 require separate testing.

## Features

- **Routing sections:** separate rules for domains, subnets and devices, with built-in and external lists.
- **Connection links:** VLESS, VMess, Trojan, Shadowsocks, Hysteria2, TUIC and other protocols supported by the core.
- **Subscriptions:** link lists, sing-box/Xray JSON, SIP008 and Clash YAML; client profiles supply connection parameters.
- **Server selection:** manual switching, URLTest for latency-based selection and Fallback for backup connections.
- **DNS:** UDP, DNS over HTTPS (DoH), DNS over TLS (DoT) and fallback resolvers. Encryption mode is selected explicitly.
- **Monitoring and logs:** traffic, connections, devices and routes in LuCI, an additional YACD panel, and diagnostic reports with secret masking.
- **Installation and updates:** one SSH command, component updates through LuCI, and preservation of LoKi settings and the previous service state.

## What supports stable operation

- **Local control through a Unix socket.** The backend communicates with the core through a private filesystem socket, checking its owner, permissions and peer UID; the controller key is not sent to the browser.
- **Live data over WebSocket.** Traffic and connections stream through a secure WSS gateway authorized by LuCI. The interface reconnects with increasing delays after a disconnect; the dashboard can use RPC snapshots when the gateway is unavailable.
- **Checks before traffic interception.** LoKi checks the configuration and core readiness before enabling routing. A core crash watcher pauses interception while the core recovers.
- **Failed-start retries.** With autostart enabled, LoKi retries a failed start after 30 seconds; Stop or Disable cancels retries.
- **Preserved working subscriptions.** Invalid or truncated responses do not replace the working set. Manual selection follows connection parameters, so renaming or reordering nodes does not change it.
- **Serialized operations.** Start, Apply and Stop share a lock; rule-list worker recovery uses the last confirmed applied configuration generation.
- **Update and log checks.** The installer verifies SHA256 and runs a simulated package-manager transaction. The core summarizes identical repeated errors while keeping the first occurrence and distinct errors visible.

## Installation

Connect to OpenWrt over SSH as `root` and run:

```sh
(set -o pipefail; wget -O - https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install-loki.sh | sh)
```

The installer detects the firmware architecture, downloads matching packages from the latest published release, checks SHA256, and delegates dependency resolution and the simulated transaction to the native package manager.

[Installation, updates and removal](INSTALL.md). SSH and LuCI use the same `install.sh`. Updates preserve LoKi configuration and the previous service state. LoKi requires its own `loki-core`; configuration migration from other applications is unsupported. Installation and load on real devices still require owner testing.

## Updating and uninstalling

To update, repeat the installation command or use the Components page in LuCI. LoKi settings and the previous service state are preserved.

To uninstall LoKi while keeping its settings, run over SSH as `root`:

```sh
(set -o pipefail; wget -O - https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install-loki.sh | sh -s -- --uninstall)
```

To remove LoKi settings as well, add `--purge` after `--uninstall`. This option deletes the saved configuration; normal removal keeps it.

## LuCI interface and YACD panel

LuCI is LoKi's main interface. A user with LoKi write permission can open the YACD link in the traffic settings in a new tab: `https://<router-address>:9091/cgi-bin/luci/loki-gateway/`. Replace `<router-address>` with the address or name used for HTTPS LuCI. The panel uses the same session cookie; no controller key is stored in the browser. Revoking or expiring the session ends access. LuCI remains the main interface if the gateway is unavailable.

The **Settings → LoKi interface language** control selects English or Russian for LoKi's LuCI page. It stores `ui_language` in `/etc/config/loki`; use LuCI's Save & Apply, then reopen the page to load the selection. The choice does not write `luci.main.lang`, register a global LuCI language or change other LuCI pages. Russian uses the installed `luci-i18n-loki-ru` catalog; if it is missing or invalid, LoKi's own labels fall back to English. Existing development configurations without `ui_language` continue to follow LuCI's language until a choice is saved. Choose the interface language in LuCI after installation.

YACD shows traffic, connections, proxies, rules and streaming logs. Its files reside in `/usr/share/loki/yacd` and the gateway serves them only after checking write permission. Read-only users cannot open the panel or its API, while LuCI Monitoring and Logs remain available to them. The panel cannot change shared system settings and does not offer an arbitrary backend, core updates or Clash API configuration changes. The gateway uses uhttpd's HTTPS certificate; the browser must trust that certificate. Real OpenWrt behavior remains untested.

Monitoring and Logs remain available. Monitoring keeps active/closed connections, device and route filters, search, refresh, sorting and counters; closing one or all connections requires write access through RPC. Read sessions poll fixed snapshots without receiving the controller secret. Logs retain viewing, refresh and cursor recovery when the resident service restarts. A busy or oversized RPC snapshot returns an explicit error.

The local HTTP transport accepts at most 64 KiB of response headers and 4 MiB of buffered body data; larger replies fail without returning a partial snapshot. Streaming rule-provider snapshots retain their existing decoder. These input limits do not bound total process memory.

The application uses `loki`, `luci-app-loki`, `/etc/config/loki` and the dedicated `/usr/bin/loki-core` binary. It requires a clean installation with its own configuration; importing or migrating another application's configuration is not supported.

## Environment diagnostics

`preflight.sh` remains available as a separate diagnostic tool. Its extended inventory is not a mandatory admission gate for normal installation or startup. The supported path uses installer and package-manager checks plus LoKi’s regular configuration and core checks.

## Subscriptions and compatibility

JSON outbounds and existing network interfaces are supported. Built-in client VPN tunnels (WireGuard, AmneziaWG, WARP, Tailscale, OpenVPN and OpenConnect), JSON endpoints and hosting VPN/proxy servers on the router are unsupported. Custom JSON outbounds cannot enable the removed VPN types. The migration framework is reserved for future LoKi versions.

The target platforms are OpenWrt 24.10 and 25.12. Only LoKi core builds are supported. Stock sing-box and other derivatives are outside the support scope; earlier limited schema comparisons remain diagnostic and regression checks.

For historical Linux schema comparisons, run with `python3 core/tests/compatibility.py REFERENCE_CORE STOCK_BINARY_DIR OUTPUT_DIR`. Replace `REFERENCE_CORE` with the trusted current LoKi core binary path, `STOCK_BINARY_DIR` with a directory containing the official archives listed in `core/tests/compatibility_releases.json` and their binaries renamed to `sing-box-VERSION`, and `OUTPUT_DIR` with a results directory. Archive digests and extracted bytes are verified before execution. The expected result is 40 checks. The earlier 36 DNS/provider comparisons use a historical loopback TCP controller in a separate copy; each official version accepts the limited manual and three plain-link profiles, and 1.14.4 also accepts a custom timeout. Four additional checks use the actual generated Unix controller: the reference core accepts it and all three stock versions reject `external_controller_unix`. The remaining cases reject the known schema extensions. Empty providers and inactive subscription-cache/unified-delay fields are omitted. This does not certify end-to-end stock-core support; package dependencies and startup requirements require r7.

Synthetic tests on r5 cover selected sing-box/Xray JSON, SIP008, Clash YAML and raw link lists, including base64 wrappers. Real loopback HTTP(S), VLESS WebSocket/TLS/Reality and Shadowsocks AES-128-GCM/ChaCha20 handshakes verify the tested connection parameters. Global client fields in structured fixtures do not replace LoKi DNS, routing, listeners/TUN, log or cache settings; the tested HTTP/parser failures and truncated responses leave the working set and selection intact, and duplicate names keep their subscription namespaces. Run `python3 core/tests/subscription_profiles.py CORE NEW_OUTPUT_DIR` as an unprivileged Linux user with a trusted core. The runner also checks 30+20 and 60+40 uniquely authenticated HTTP/HTTPS nodes with sequential traffic through every node. These fixtures do not confirm concurrent router capacity, every protocol/option combination, an owner-provided subscription or OpenWrt; input size and node limits remain under review.

The built-in lists from [forkop-lists](https://github.com/ushan0v/forkop-lists) and the diagnostic domains `ip.podkop.fyi` and `fakeip.podkop.fyi` are retained external dependencies.

## The LoKi core

The loki-core base is `ushan0v/sing-box-forkop`, pinned in `core/upstream.env`; that base supplies subscription providers, connection-format parsing and DNS extensions. LoKi patches are in `core/patches/`. The current build is `1.14.4-r11`, with the technical package name `loki-core`. The package, service, CLI, UCI and path rename is implemented; configurations from other applications are not supported.

The r10 core adds a bounded HTTPS downloader for public LoKi release inputs. It checks redirect destinations and response limits without reading proxy configuration. Use the common package installer described above.

In r11, subscription responses that report a missing X-HWID or a device limit produce a specific log error and preserve the previous working connections. Servers with unspecified addresses `0.0.0.0` or `::` are excluded from import. If an earlier release created a subscription entry without HTTP headers, create a new entry using the same link and check for `X-HWID` under Headers before applying. The identifier belongs to the router; the provider may count it as another device. Saved custom headers are not replaced automatically.

On Linux, `loki-core check` disables process memory dumps before reading configuration. If the kernel refuses that protection, the check fails before reading the file. This guard does not replace filesystem and network isolation; non-Linux configuration checks are refused.

The existing configuration check before startup or apply is limited to 10 seconds and 64 KiB of combined output. On refusal, interruption or output overflow, its temporary input is removed and the previous generated configuration file is preserved. It reuses the RPC worker’s BusyBox `ash`, `setsid` and `sleep` watchdog to terminate a separate process group at the deadline. The optional `timeout` applet and additional packages are not required.

In r8, fallback health checks probe an underlying node once per sweep even when several group members refer to it. A fast reply in r7 could cause a second probe in the same sweep. The configuration format is unchanged. The application requires r9, which retains this fix; router behavior remains untested.

In r7, LoKi uses the fixed Unix controller socket `/tmp/loki/controller.sock` in a private directory. The gateway and backend RPC check endpoint ownership and permissions, then verify the peer UID before sending the controller credential. The browser never receives that credential. Credential reads and entropy generation refuse failed file closure and preserve any existing credential file. Browser access uses a separate HTTPS/WSS gateway with LuCI authorization; local YACD assets have passed Linux checks, while real OpenWrt validation remains pending.

When connecting to a domain through an explicitly selected DNS resolver, a ready answer from the preferred address family can be used without waiting for the silent second family. This covers TCP/UDP and network-interface selection while retaining IPv6. IPv4-only/IPv6-only modes and DNS rule walks without an explicit resolver retain their existing path. This fix does not disable DNS encryption or allow direct proxy bypass on failure.

Provider selections introduced in r4 use the connection parameters within the selected subscription, so reordering duplicate names or renaming a node does not switch connections. Changing authentication, transport or TLS creates a different identity; an unavailable selected identity uses the existing default/first-member policy until it returns or a new choice is made. A pre-r4 cache stores only names and cannot safely identify an old provider choice: select the desired node again after upgrading. Display names remain unchanged, and a failed cache write rejects a manual selection without changing the running choice.

In r5, cache storage requires a private directory owned by the core process (mode `0700`) and owned regular files with one hard link (mode `0600`). The RAM preset is `/tmp/loki/cache.db`; the flash preset is `/etc/loki/cache/cache.db`. Unsafe paths, symlinks and unmarked databases are refused without importing, deleting or changing foreign data. Existing r4 databases are unmarked and are not accepted; select a new private cache location for a development upgrade and choose the subscription node again. Explicit UCI paths are preserved, so changing the default alone does not change an existing configuration. RAM cache is lost on reboot.

Subscription bodies are stored as immutable versions; metadata and their verified body reference commit together before the provider runtime changes. Failed publication retains the working set. Rejected received bodies clear the HTTP validator only after the previous body and updated metadata persist, preventing a subsequent `304` from hiding the rejected update.

In r6, newly saved rule-set/SRS bodies also use immutable files with a size and SHA-256 reference committed together with their metadata. An uncertain database commit blocks further subscription/SRS writes and cleanup, retaining both possible versions until restart. Startup requires a successful database sync before migration, compaction or orphan cleanup; failure refuses startup. Cleanup scans both body directories in batches through the end, preserving referenced, pending and unrelated files. This bounds directory-entry memory, not total reference-map memory or scan time.

Only marked LoKi r5 stores can be reused: legacy SRS entries retain their historical size-only check until successfully updated. The first new-format SRS commit upgrades the store marker atomically; new stores use format 2 immediately. r5 refuses format 2, so a development downgrade requires a separate private cache location. Legacy deterministic SRS files remain private leftovers and are not automatically removed. Invalid new-format references never fall back to older entries. Runtime SRS updates retain their existing behavior: parsed rules may already be active when a cache save fails; persistent pair integrity does not add a runtime rollback. Full installation preflight, resource limits and physical power-loss durability remain unverified.

The LoKi core folds exact ERROR repeats from the same component within a 10-second window. The first error is visible immediately; subsequent repeats produce a numeric summary. The cache holds at most 64 pairs of component and message hashes without retaining their text. New uncached errors, other levels and FATAL/PANIC remain visible. A summary appears with the next entry after the window or on normal shutdown; there is no background timer. Abrupt termination can lose a pending summary. Different messages are not combined, so this does not cap all logging traffic.

SSH and LuCI use the same installer adapted from Forkop. It installs LoKi packages and required dependencies through the native package manager. It does not flash firmware or migrate configurations from other applications. Bench checks do not establish the result on every OpenWrt device.

## Startup recovery

With autostart enabled, a failed boot or manual start is retried after 30 seconds without waiting for a new WAN event. Retries stop after success, Stop or Disable; Disable leaves an already healthy runtime running. The core must become ready before traffic interception is applied. Recovery uses a temporary procd instance and does not require the LuCI state service. Physical power-loss recovery and flash persistence still require OpenWrt laboratory tests.

The rule-set worker uses the last confirmed applied generation. Saving different settings does not change its providers, addresses, ports or controller credential during repair or respawn. A Start on a healthy runtime can restore its missing workers without applying the newly saved settings. The private context lives in tmpfs, is limited to 4 MiB and is not a configuration backup; its size limit does not bound total process memory.

An interrupted Apply can leave an unconfirmed combination of core and nft state. Automatic Start, queued reload and interface-triggered reload refuse to finish that operation. Apply explicitly, or complete Stop and then Start; these actions use the saved configuration. Stop must record its intent before teardown. A normal reboot loses the tmpfs context and starts from the saved configuration. Recovery after a core respawn checks procd command, PID/start time and the protected configuration digest within LoKi's own lifecycle protocol; changes made by other root processes outside it are not supported for automatic recovery.

Lifecycle actions use a Linux kernel lock released when the owning process exits. Temporary lock directories remain after completion; their presence alone does not indicate a busy operation. Live or uncertain legacy ownership refuses a competing action.

## Configuration backups

LoKi configurations carry `option config_format 'loki'` alongside their schema version. A matching version number alone does not make a Forkop or Podkop configuration compatible. Installation, startup and backup restoration refuse foreign, unsupported or malformed schemas without moving or resetting the file. Intermediate development configurations without the LoKi marker are not converted automatically.

The configuration upload restores LoKi’s own backup as unsaved changes in the current LuCI session; it takes effect after you apply them. Uploads must be regular files of at most 1 MiB. Current configurations require no migration; future LoKi schema updates retain the migration framework and private backups. LoKi configuration checks still apply before activation. Connection links and subscriptions remain separate supported inputs; global client settings are not imported.

## DNS settings

The UI requires an explicit encryption mode for the entire main DNS list: disabled (UDP), or enabled with an explicit choice of DoH or DoT. Addresses must match: `https://dns.example/dns-query` for DoH, `tls://dns.example` for DoT, or an IP address for UDP. Replace the example name `dns.example` with your resolver. Changing the mode does not rewrite addresses or switch protocols when a server fails.

Bootstrap uses UDP by IP address. Outbound connections without their own resolver use bootstrap; explicit JSON and interface resolver settings are preserved. Fresh configurations retain the existing UDP default. Legacy configurations without the encryption field keep their URI protocols until an explicit mode is selected in the UI. These changes still require testing on laboratory OpenWrt.

The generated JSON omits only the exact DNS timeout `10s`, matching the verified default of all four pinned cores. Other values, including `10000ms`, are preserved; stored settings are unchanged. On Linux, `python3 -B core/tests/dns_timeout.py CORE NEW_OUTPUT_DIR` checks real deadlines with synthetic loopback DNS peers. Replace `CORE` with a trusted pinned binary and use a new results directory. Keepalive queries and a 12-second timeout with an 11-second response distinguish the client deadline from the inbound's separate 10-second idle limit. Older stock cores must reject explicit timeouts rather than silently ignore them.

For outbound connections with an explicit resolver, the patched core starts connecting with an available address family while the other DNS lookup is pending. The second family remains available for a fallback connection; `ipv4_only` and `ipv6_only` retain their meaning. This also covers resolving DoH/DoT server names. Ordinary DNS rule walks still obtain their full result; no downgrade to UDP or direct routing on failure is added.

Captured PTR lookups use the local resolver for locally served reverse zones and the current IPv4/IPv6 prefixes of the configured LAN capture interfaces, including public LAN prefixes. Other PTR lookups follow the selected DNS rules. If a LAN address snapshot is unavailable, malformed or exceeds its limits, a warning is logged and all PTR lookups retain their previous local route. Prefixes are refreshed when the service starts or reloads; apply settings again after LAN renumbering. The `router` mode continues to send unmatched queries to the local resolver. This behavior still requires OpenWrt testing.

## Building the core

`core/` contains the patches, tests and build scripts. The loki-core source is pinned to commit `60d96c99815a672712915a5c00114bf0f690ad80`; its archive is verified by SHA-256 before extraction and the patch is checked before application. Source updates are explicit. The complete core source is not copied into the LoKi repository; each package build also produces `core-source-VERSION.tar.gz` (`VERSION` is the core version in `core/upstream.env`) with the patched core tree for distribution alongside the binaries.

Build on Linux with the Go version in `core/GO_VERSION`, Bash, Git, curl, Python 3 and the existing package build tools. This example builds the application packages and the base core for `aarch64_cortex-a53`; `0.1.0` is an example version, not a published release. The apk tool comes from the default SDK cache after building the application; adjust its path if using another SDK directory.

The application builder pins the OpenWrt 24.10.8 and 25.12.6 SDK archives by SHA-256 and exact byte size. Downloads and redirects require HTTPS; cached archives are checked again before extraction. `IPK_SDK_URL` and `APK_SDK_URL` can select HTTPS mirrors of these archives. A different SDK also requires its independently verified `IPK_SDK_SHA256`/`IPK_SDK_BYTES` or `APK_SDK_SHA256`/`APK_SDK_BYTES`; changing the URL alone does not trust new contents. Use build/cache directories controlled by your build user. An old URL-only extraction marker causes re-extraction. A decompression or SDK-root validation failure preserves the previous extracted SDK. Run the local HTTPS regressions on Linux with `python3 -m unittest discover -s tests/packaging -p 'test_*.py'` (curl, OpenSSL and zstd are required).

```sh
./build.sh 0.1.0 "$PWD/release"
export PATH="$HOME/.cache/loki/openwrt-sdk/extracted/apk/staging_dir/host/bin:$PATH"
core/build.sh 0.1.0 "$PWD/release" --arch aarch64_cortex-a53 --variant base
(cd release && sha256sum -c SHA256SUMS)
```

`core/build.sh` accepts the inherited builder's variants and targets; without an architecture restriction it builds all of its targets. The full variant may additionally download several gigabytes of Chromium sources and tools. The release workflow builds the base core for the supported architecture matrix and adds its core manifest to the application assets. Building does not publish a release or install packages.

The builder also exports `loki-core_VERSION_VARIANT_ARCH.bin`, a standalone binary for bootstrap. Before copying it to the release directory, it verifies its size and SHA-256 against `/usr/bin/loki-core` in each IPK/APK; both formats of the same profile must contain identical bytes. The file has mode `0644` and is included in `SHA256SUMS`. Distribute it with the matching packages, sources and license notices. This file is not an installer; use the complete verified kit.

Each successful package build also creates `core-module-sources-VERSION-SHA256.tar.gz`. It contains the verified source ZIPs of the external Go modules linked into those binaries, available `go.sum`-verified graph metadata, and the pinned Public Suffix List source with its MPL 2.0 text. `SOURCES.json` binds the files to the binary hashes, build settings, Go version and patched core tree. Different profiles retain separate archives in a combined output directory. Source inventory schema 2 requires the Go archive; older inventories remain historical evidence and do not pass this gate.

It also contains the unmodified official `go1.26.10.src.tar.gz`, including Go runtime, standard-library and toolchain sources and their original notices. Its exact size and SHA-256 are pinned in the collector and checked again by the package verifier. The source archive is copied as data; it is never extracted to disk or executed during collection. The installed Go source files must match its contents; changed or missing files stop collection.

Before building, the wrapper explicitly prepares this file over HTTPS in the `loki/core` subdirectory of `XDG_CACHE_HOME` (or `~/.cache`). Collection then uses the existing cache offline; missing required sources, changed checksums or unresolved components stop the wrapper before it copies new packages. The package verifier requires matching module assets for every included binary profile.

Core CI uses [`core/isolate_toolchain.py`](core/isolate_toolchain.py) to prepare a private copy of the installed Go toolchain. Content and file-metadata checks apply to this owned copy; the shared tool cache keeps its original bytes and permissions.

For an offline base rebuild, use the pinned Go version, unpack `core-source-*` into a new directory and its matching module archive into another. Set `GOMODCACHE` to the second directory's `modules` subdirectory, `GOTOOLCHAIN=local`, `GOPROXY=off` and `GOSUMDB=off`. Initialize a local Git index in the core directory (`git init` followed by `git add .`) for the inherited line-ending check. With `SOURCE_DATE_EPOCH` from `core/upstream.env`, run its `./build.sh --binary-only --version VERSION --output /path/to/output amd64`; replace `VERSION` and the output path. The nested `toolchain/go1.26.10.src.tar.gz` provides the pinned Go sources; building a compiler from them has its own bootstrap requirements described by [Go](https://go.dev/doc/install/source). Separately fetched Cronet materials remain outside this asset. A successful base rebuild does not establish complete corresponding-source coverage for other variants.

Core packages include `usr/share/licenses/loki-core/THIRD_PARTY_NOTICES` and `build-info.json`. The builder copies the reviewed files in `core/notice-files.json` without changing their bytes and records their origins, offsets and hashes alongside the binary hash, linked Go modules and patched source-tree digest. It reads the existing module cache offline; a missing or changed reviewed notice stops packaging. An unreviewed module, replacement or native component remains explicitly unresolved in a development package. Run `python3 core/tests/verify_packages.py "$PWD/release"` on the combined application/core output: this release gate rejects unresolved inventories and checks the actual binary metadata, source archive and IPK/APK notice contents. This bounded notice map does not establish complete license or corresponding-source coverage for every variant.

Run `core/test.sh -race -count=1` and `python3 core/tests/test_release.py`. The command `python3 core/tests/dns_bootstrap.py /path/to/sing-box /results/directory` requires ucode and starts synthetic DNS, TLS and proxy peers only on loopback. The command `python3 core/tests/log_repeats.py /path/to/sing-box /results/directory` checks repeated TCP failures, the 10-second window and a shutdown summary. Results are saved in the specified directory; these checks do not replace OpenWrt testing.

## Diagnostic reports

Applying settings and the service check warn when a built-in list and a recognized external reference in the same enabled section use the same source or may overlap. Recognition is limited to exact canonical forkop-lists URLs, short built-in names and two historical itdog URLs (`russia_inside.srs`, `meta.srs`). The warning does not prove that different files have identical contents: compare domains and subnets before removing a list. Saving is not blocked, and lists and routing are not changed automatically; unknown URLs and local files are not fetched for comparison. Full external URLs and tokens are not included in the new warnings or response fields. This is diagnostics, not a reduction in memory usage.

FakeIP maps a synthetic IP address to a domain name for routing. In the traffic check, a negative browser FakeIP result is an informational note and does not by itself mark the group as problematic. It does not identify the device’s DNS settings. An unanswered check remains a warning, and router/exit failures retain their severity. Text reports mark informational notes with ℹ.

The service check shows the number of sing-box ERROR/FATAL messages found in the available log during the last 60 seconds. It counts log records, not network failures: a DNS repeat summary counts as one record. On-demand reading is capped at 64 KiB and 1000 lines; limits or malformed data are reported as incomplete, and read failures as unavailable. No history or separate log files are created, and the new response field contains no log text. Logd eviction and clock changes limit accuracy; this counter does not reduce the original log traffic.

DNS validation errors identify the affected setting and cause without printing the original DNS URI. Reports open with values masked. An unmasked report requires confirmation and starts with a warning that it contains keys and passwords. Copy and download are disabled while switching modes; afterwards they export the displayed mode. For a report to share, use the masked mode or `loki report masked`, and review its contents before sending it: masking cannot identify every possible secret. Update the backend and LuCI packages together so their report formats agree.

On Linux, `python3 core/tests/plain_links.py CORE OUTPUT_DIR [REFERENCE_CORE]` compares generated HTTP(S)/SOCKS outbounds with the existing parser using local authenticated peers, including wrong-password and untrusted-certificate refusals. Use trusted, verified binary paths and a new output directory; pass the LoKi core reference when `CORE` is an official 1.14.4 binary. The test changes its own listeners and files only.

For generated proxy cascades, run `python3 core/tests/cascade_links.py CORE NEW_OUTPUT_DIR [REFERENCE_CORE]` with the same trusted binaries. It tests HTTP/HTTPS first hops, HTTP/HTTPS/SOCKS5 exits, both peers becoming unavailable, authentication/TLS refusals, stream interruption and recovery. A deliberately removed detour must be detected even when the response succeeds. All peers are local; this does not certify router routing or every cascade protocol.

Own mutable configuration files under `/etc` are installed with mode `0600`. New writes of the generated core configuration and own atomic state use mode `0600`; the transient core-check input is also private and removed after success, refusal or an execution exception. An occupied temporary name causes refusal without overwriting or deleting the existing file. Existing directories and unchanged files are not automatically repaired; this protection assumes trusted parent directories. It does not guarantee power-loss durability.

## Documentation and testing

The public project documentation is maintained in this README, [README.ru.md](README.ru.md) and [README.zh.md](README.zh.md). The inherited documentation site and its GitHub Pages workflow have been removed.

Run tests and package builds on a dedicated Linux development server. DNS failures, traffic interception and installation must also be tested on a laboratory OpenWrt router before a release. Use synthetic credentials and local test endpoints for security tests.

## Origin and license

The core notice bundle includes the complete MPL 2.0 text and attribution for the pinned Public Suffix List source. The bundled flag font retains its [artwork attribution](luci-app-loki/htdocs/luci-static/resources/view/loki/fonts/LICENSE.md), [unmodified npm license](luci-app-loki/htdocs/luci-static/resources/view/loki/fonts/UPSTREAM_LICENSE.md) and [artifact provenance](luci-app-loki/htdocs/luci-static/resources/view/loki/fonts/PROVENANCE.md). The WOFF2 matches npm version 0.1.8; reproduction from its upstream TTF has not been verified.

The notice for embedded Lucide SVGs and Feather derivatives is installed at `/usr/share/licenses/luci-app-loki/LUCIDE-LICENSE`, with supplement provenance in `LUCIDE-PROVENANCE`. The [pinned license text](fe-app-loki/licenses/lucide-LICENSE.txt) leaves drawings and interface code unchanged; the original icon-copy revisions were not recorded.

Forkop was developed by [ushan0v and its contributors](https://github.com/ushan0v/forkop/graphs/contributors). LoKi is maintained independently in [Zagorsky17/LoKi](https://github.com/Zagorsky17/LoKi); it is not an upstream Forkop release.

LoKi retains the project's [GPL-2.0-or-later license](LICENSE). The core patch and resulting loki-core binary are distributed separately under [GPL-3.0-or-later](core/COPYING); the build produces `core-source-VERSION.tar.gz` with the patched core checkout, including its local `third_party` replacements, and separate `core-module-sources-*` archives described above. Distributing a binary also requires the matching build materials and the applicable dependency sources and notices; these archives alone are not a completed corresponding-source audit. Preserve existing copyright, license and attribution notices. Third-party components retain their own notices, including the [bundled font assets](luci-app-loki/htdocs/luci-static/resources/view/loki/fonts/LICENSE.md).

When distributing modified versions or binary packages, retain the applicable notices and license, identify modified files and their change dates, and provide the corresponding source as required by the [GNU GPL version 2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html). The software is provided without warranty under the license terms.

This README was rewritten for LoKi on October 31, 2026, and updated on November 6, 2026.

The binary-release license audit remains open. YACD is vendored from [MetaCubeX/Yacd-meta commit `24151c3`](https://github.com/MetaCubeX/Yacd-meta/tree/24151c331027ff176b45ed417180c6f1220474a3); its source, lockfile and MIT license text are kept in `yacd-loki/`. The LuCI package includes the MIT text, Inter/Roboto Mono OFL notices and a build-derived dependency notice bundle with hashes. The two npm archives without a license file retain their original declarations and explicitly identified supplements; see [YACD provenance and rebuild checks](yacd-loki/README.md). A release still needs the complete rights/source review, font provenance, linked Go code and corresponding sources for every variant. The inherited main frontend license remains a separate review item.
