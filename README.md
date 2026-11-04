# LoKi

[Русский](README.ru.md) · English

> **This application is under active development.** Development stages are checked on Linux before review and merge. Router testing follows completion of the software stages. Stability on OpenWrt and behavior during DNS/TLS failures have not yet been confirmed in laboratory tests.

Rule-based traffic routing for OpenWrt, powered by sing-box. LoKi is an independently developed fork of [Forkop](https://github.com/ushan0v/forkop), starting from version 2.0.0 (`9544f3de09c62c935e1147147136234594d04f02`).

Project: [Zagorsky17/LoKi](https://github.com/Zagorsky17/LoKi). Report bugs and propose changes in [LoKi Issues](https://github.com/Zagorsky17/LoKi/issues).

## Development status

As of November 3, 2026, this repository has no LoKi release. The installer obtains the application and patched core from **`Zagorsky17/LoKi`**, without falling back to Forkop releases. Installation needs package assets, `release.json`, `core-release.json` and `SHA256SUMS`; publishing source to `main` is not enough. The application requires the LoKi core build `1.14.4-r5` or newer; its technical package name remains `sing-box-forkop`. Router installation and upgrades have not been tested.

The Components tab in LuCI can check LoKi and core updates separately and show installed and available versions. A check downloads release metadata only: it does not install packages, set the clock, change services or settings, or truncate the installation log. Network, TLS, manifest, SHA256, architecture and compatibility failures are reported as failures. Package changes are disabled in this development build: installation, updates, build changes and removal refuse before package operations. The gate also applies over SSH and to recorded legacy jobs; there is no force override. A safe engine for the compatible set of own components, standalone preflight and recovery is still required. Over SSH, run the same resolver with `sh install.sh --check --lang en` using an independently obtained and verified script. It writes one JSON result to stdout and progress to stderr.

LuCI checks use only the installed, root-owned copy of the current installer; they do not download bootstrap code. LuCI verifies its bootstrap script and manifest against mandatory `SHA256SUMS` before execution. Initial URLs require HTTPS; API assets stay within the LoKi repository, and mirrors require an HTTPS URL. SHA256 establishes consistency with the chosen source; releases do not yet have a separate signature. The legacy apply downloader is blocked; its redirect policy still needs hardening before reuse. Update checking does not replace the separate installation preflight planned in development stage 7. Real LuCI/rpcd, opkg/apk and OpenWrt upgrades remain untested.

LuCI commands use fixed server RPC methods instead of browser-controlled `file.exec`. Read access excludes raw LoKi UCI and settings forms; masked diagnostics use short job polling, including checks longer than one minute. The direct Clash controller/YACD authorization gap remains open until the planned gateway is implemented; this RPC change does not establish a global read-only role.

Monitoring and Logs remain available. Monitoring keeps active/closed connections, device and route filters, search, refresh, sorting and counters; closing one or all connections requires write access through RPC. Read sessions poll fixed snapshots without receiving the controller secret. Logs retain viewing, refresh and cursor recovery when the resident service restarts. A busy or oversized RPC snapshot returns an explicit error.

The local HTTP transport accepts at most 64 KiB of response headers and 4 MiB of buffered body data; larger replies fail without returning a partial snapshot. Streaming rule-provider snapshots retain their existing decoder. These input limits do not bound total process memory.

The source still uses the technical names `forkop`, `luci-app-forkop` and `/etc/config/forkop`. Their coordinated replacement is planned. LoKi targets clean installation with its own configuration; migration from Forkop, Podkop or other applications is not supported. Migrations from Forkop 1.0.x and automatic takeover of another project’s packages/configuration have been removed. The required standalone pre-install conflict check is not implemented yet; installation is not ready for production use.

## Planned scope

LoKi will retain connection links, subscriptions, routing sections, DNS, monitoring and diagnostics. Hosting VPN/proxy servers on the router has been removed: there is no server tab, server listener generation, client profile issuance, server key generation or server diagnostics. Built-in DNS/TProxy listeners and outbound connections remain. Built-in client VPN tunnels (WireGuard, AmneziaWG, WARP, Tailscale, OpenVPN and OpenConnect) and JSON endpoints have also been removed. Connection links, subscriptions, JSON outbounds and existing network interfaces remain; custom JSON outbounds cannot restore the removed VPN types. Only the framework for future LoKi migrations remains.

The target platforms are OpenWrt 24.10 and 25.12. Only LoKi core builds are supported. Stock sing-box and other derivatives are outside the support scope; earlier limited schema comparisons remain diagnostic and regression checks.

For historical Linux schema comparisons, run with `python3 core/tests/compatibility.py REFERENCE_CORE STOCK_BINARY_DIR OUTPUT_DIR`. Replace `REFERENCE_CORE` with the trusted current LoKi core binary path, `STOCK_BINARY_DIR` with a directory containing the official archives listed in `core/tests/compatibility_releases.json` and their binaries renamed to `sing-box-VERSION`, and `OUTPUT_DIR` with a results directory. Archive digests and extracted bytes are verified before execution. The expected result is 36 checks: the reference core accepts all nine profiles, each official version accepts the limited manual and three plain-link profiles, and 1.14.4 also accepts a custom timeout. The remaining cases reject the known schema extensions. Empty providers and inactive subscription-cache/unified-delay fields are omitted. This does not certify end-to-end stock-core support; package dependencies and startup requirements require r5.

Synthetic tests on r5 cover selected sing-box/Xray JSON, SIP008, Clash YAML and raw link lists, including base64 wrappers. Real loopback HTTP(S), VLESS WebSocket/TLS/Reality and Shadowsocks AES-128-GCM/ChaCha20 handshakes verify the tested connection parameters. Global client fields in structured fixtures do not replace LoKi DNS, routing, listeners/TUN, log or cache settings; the tested HTTP/parser failures and truncated responses leave the working set and selection intact, and duplicate names keep their subscription namespaces. Run `python3 core/tests/subscription_profiles.py CORE NEW_OUTPUT_DIR` as an unprivileged Linux user with a trusted core. The runner also checks 30+20 and 60+40 uniquely authenticated HTTP/HTTPS nodes with sequential traffic through every node. These fixtures do not confirm concurrent router capacity, every protocol/option combination, an owner-provided subscription or OpenWrt; input size and node limits remain under review.

The built-in lists from [forkop-lists](https://github.com/ushan0v/forkop-lists) and the diagnostic domains `ip.podkop.fyi` and `fakeip.podkop.fyi` are retained external dependencies.

## The LoKi core

The core is based on sing-box-forkop pinned in `core/upstream.env`; that base supplies subscription providers, connection-format parsing and DNS extensions. LoKi patches are in `core/patches/`. The current build is `1.14.4-r5`, with the technical package name `sing-box-forkop`. The approved name `loki-core` and path `/usr/bin/loki-core` will arrive with the coordinated technical rename, which has not been implemented yet.

When connecting to a domain through an explicitly selected DNS resolver, a ready answer from the preferred address family can be used without waiting for the silent second family. This covers TCP/UDP and network-interface selection while retaining IPv6. IPv4-only/IPv6-only modes and DNS rule walks without an explicit resolver retain their existing path. This fix does not disable DNS encryption or allow direct proxy bypass on failure.

Provider selections introduced in r4 use the connection parameters within the selected subscription, so reordering duplicate names or renaming a node does not switch connections. Changing authentication, transport or TLS creates a different identity; an unavailable selected identity uses the existing default/first-member policy until it returns or a new choice is made. A pre-r4 cache stores only names and cannot safely identify an old provider choice: select the desired node again after upgrading. Display names remain unchanged, and a failed cache write rejects a manual selection without changing the running choice.

In r5, cache storage requires a private directory owned by the core process (mode `0700`) and owned regular files with one hard link (mode `0600`). The RAM preset is `/tmp/loki/cache.db`; the flash preset is `/etc/loki/cache/cache.db`. Unsafe paths, symlinks and unmarked databases are refused without importing, deleting or changing foreign data. Existing r4 databases are unmarked and are not accepted; select a new private cache location for a development upgrade and choose the subscription node again. Explicit UCI paths are preserved, so changing the default alone does not change an existing configuration. RAM cache is lost on reboot.

Subscription bodies are stored as immutable versions; metadata and their verified body reference commit together before the provider runtime changes. Failed publication retains the working set. An uncertain database commit blocks further subscription writes until restart; a crash can leave private orphan files. Rejected received bodies clear the HTTP validator only after the previous body and updated metadata persist, preventing a subsequent `304` from hiding the rejected update. Rule-set/SRS body and metadata updates are not yet atomic. Full installation preflight, resource limits and physical power-loss durability remain unverified.

The LoKi core folds exact ERROR repeats from the same component within a 10-second window. The first error is visible immediately; subsequent repeats produce a numeric summary. The cache holds at most 64 pairs of component and message hashes without retaining their text. New uncached errors, other levels and FATAL/PANIC remain visible. A summary appears with the next entry after the window or on normal shutdown; there is no background timer. Abrupt termination can lose a pending summary. Different messages are not combined, so this does not cap all logging traffic.

A shared SSH/LuCI update mechanism is under development. Its scope is a compatible set of LoKi backend, LuCI, core, translations, YACD and bundled helpers. It must not change OS/firmware versions, shared system packages or settings, including through package-manager dependencies. System requirements are checked before changes; incompatibility must stop the update with a specific reason. Full preflight, recovery and actual OpenWrt upgrades are not verified yet.

## Startup recovery

With autostart enabled, a failed boot or manual start is retried after 30 seconds without waiting for a new WAN event. Retries stop after success, Stop or Disable; Disable leaves an already healthy runtime running. The core must become ready before traffic interception is applied. Recovery uses a temporary procd instance and does not require the LuCI state service. Physical power-loss recovery and flash persistence still require OpenWrt laboratory tests.

## Configuration backups

LoKi configurations carry `option config_format 'loki'` alongside their schema version. A matching version number alone does not make a Forkop or Podkop configuration compatible. Installation, startup and backup restoration refuse foreign, unsupported or malformed schemas without moving or resetting the file. Intermediate development configurations without the LoKi marker are not converted automatically.

The configuration upload restores LoKi’s own backup as unsaved changes in the current LuCI session; it takes effect after you apply them. Uploads must be regular files of at most 1 MiB. Current configurations require no migration; future LoKi schema updates retain the migration framework and private backups. This does not replace the planned environment conflict check. Connection links and subscriptions remain separate supported inputs; global client settings are not imported.

## DNS settings in development

The development UI requires an explicit encryption mode for the entire main DNS list: disabled (UDP), or enabled with an explicit choice of DoH or DoT. Addresses must match: `https://dns.example/dns-query` for DoH, `tls://dns.example` for DoT, or an IP address for UDP. Replace the example name `dns.example` with your resolver. Changing the mode does not rewrite addresses or switch protocols when a server fails.

Bootstrap uses UDP by IP address. Outbound connections without their own resolver use bootstrap; explicit JSON and interface resolver settings are preserved. Fresh configurations retain the existing UDP default. Legacy configurations without the encryption field keep their URI protocols until an explicit mode is selected in the UI. These changes still require testing on laboratory OpenWrt.

The generated JSON omits only the exact DNS timeout `10s`, matching the verified default of all four pinned cores. Other values, including `10000ms`, are preserved; stored settings are unchanged. On Linux, `python3 -B core/tests/dns_timeout.py CORE NEW_OUTPUT_DIR` checks real deadlines with synthetic loopback DNS peers. Replace `CORE` with a trusted pinned binary and use a new results directory. Keepalive queries and a 12-second timeout with an 11-second response distinguish the client deadline from the inbound's separate 10-second idle limit. Older stock cores must reject explicit timeouts rather than silently ignore them.

For outbound connections with an explicit resolver, the patched core starts connecting with an available address family while the other DNS lookup is pending. The second family remains available for a fallback connection; `ipv4_only` and `ipv6_only` retain their meaning. This also covers resolving DoH/DoT server names. Ordinary DNS rule walks still obtain their full result; no downgrade to UDP or direct routing on failure is added.

Captured PTR lookups use the local resolver for locally served reverse zones and the current IPv4/IPv6 prefixes of the configured LAN capture interfaces, including public LAN prefixes. Other PTR lookups follow the selected DNS rules. If a LAN address snapshot is unavailable, malformed or exceeds its limits, a warning is logged and all PTR lookups retain their previous local route. Prefixes are refreshed when the service starts or reloads; apply settings again after LAN renumbering. The `router` mode continues to send unmatched queries to the local resolver. This behavior still requires OpenWrt testing.

## Building the core

`core/` contains the patches, tests and build scripts. The sing-box-forkop source is pinned to commit `60d96c99815a672712915a5c00114bf0f690ad80`; its archive is verified by SHA-256 before extraction and the patch is checked before application. Source updates are explicit. The complete core source is not copied into the LoKi repository; each package build also produces `core-source-VERSION.tar.gz` (`VERSION` is the core version in `core/upstream.env`) with the patched core tree for distribution alongside the binaries.

Build on Linux with the Go version in `core/GO_VERSION`, Bash, Git, curl, Python 3 and the existing package build tools. This example builds the application packages and the base core for `aarch64_cortex-a53`; `0.1.0` is an example version, not a published release. The apk tool comes from the default SDK cache after building the application; adjust its path if using another SDK directory.

The application builder pins the OpenWrt 24.10.8 and 25.12.6 SDK archives by SHA-256 and exact byte size. Downloads and redirects require HTTPS; cached archives are checked again before extraction. `IPK_SDK_URL` and `APK_SDK_URL` can select HTTPS mirrors of these archives. A different SDK also requires its independently verified `IPK_SDK_SHA256`/`IPK_SDK_BYTES` or `APK_SDK_SHA256`/`APK_SDK_BYTES`; changing the URL alone does not trust new contents. Use build/cache directories controlled by your build user. An old URL-only extraction marker causes re-extraction. A decompression or SDK-root validation failure preserves the previous extracted SDK. Run the local HTTPS regressions on Linux with `python3 -m unittest discover -s tests/packaging -p 'test_*.py'` (curl, OpenSSL and zstd are required).

```sh
./build.sh 0.1.0 "$PWD/release"
export PATH="$HOME/.cache/forkop/openwrt-sdk/extracted/apk/staging_dir/host/bin:$PATH"
core/build.sh 0.1.0 "$PWD/release" --arch aarch64_cortex-a53 --variant base
(cd release && sha256sum -c SHA256SUMS)
```

`core/build.sh` accepts the inherited builder's variants and targets; without an architecture restriction it builds all of its targets. The full variant may additionally download several gigabytes of Chromium sources and tools. The release workflow adds tiny/base/full core packages and a separate core manifest to the application assets. Building does not publish a release or install packages.

Core packages include `usr/share/licenses/sing-box/THIRD_PARTY_NOTICES` and `build-info.json`. The builder copies the reviewed files in `core/notice-files.json` without changing their bytes and records their origins, offsets and hashes alongside the binary hash, linked Go modules and patched source-tree digest. It reads the existing module cache offline; a missing or changed reviewed notice stops packaging. An unreviewed module, replacement or native component remains explicitly unresolved in a development package. Run `python3 core/tests/verify_packages.py "$PWD/release"` on the combined application/core output: this release gate rejects unresolved inventories and checks the actual binary metadata, source archive and IPK/APK notice contents. This bounded notice map does not establish complete license or corresponding-source coverage for every variant.

Run `core/test.sh -race -count=1` and `python3 core/tests/test_release.py`. The command `python3 core/tests/dns_bootstrap.py /path/to/sing-box /results/directory` requires ucode and starts synthetic DNS, TLS and proxy peers only on loopback. The command `python3 core/tests/log_repeats.py /path/to/sing-box /results/directory` checks repeated TCP failures, the 10-second window and a shutdown summary. Results are saved in the specified directory; these checks do not replace OpenWrt testing.

## Diagnostic reports

Applying settings and the service check warn when a built-in list and a recognized external reference in the same enabled section use the same source or may overlap. Recognition is limited to exact canonical forkop-lists URLs, short built-in names and two historical itdog URLs (`russia_inside.srs`, `meta.srs`). The warning does not prove that different files have identical contents: compare domains and subnets before removing a list. Saving is not blocked, and lists and routing are not changed automatically; unknown URLs and local files are not fetched for comparison. Full external URLs and tokens are not included in the new warnings or response fields. This is diagnostics, not a reduction in memory usage.

FakeIP maps a synthetic IP address to a domain name for routing. In the traffic check, a negative browser FakeIP result is an informational note and does not by itself mark the group as problematic. It does not identify the device’s DNS settings. An unanswered check remains a warning, and router/exit failures retain their severity. Text reports mark informational notes with ℹ.

The service check shows the number of sing-box ERROR/FATAL messages found in the available log during the last 60 seconds. It counts log records, not network failures: a DNS repeat summary counts as one record. On-demand reading is capped at 64 KiB and 1000 lines; limits or malformed data are reported as incomplete, and read failures as unavailable. No history or separate log files are created, and the new response field contains no log text. Logd eviction and clock changes limit accuracy; this counter does not reduce the original log traffic.

DNS validation errors identify the affected setting and cause without printing the original DNS URI. Reports open with values masked. An unmasked report requires confirmation and starts with a warning that it contains keys and passwords. Copy and download are disabled while switching modes; afterwards they export the displayed mode. For a report to share, use the masked mode or `forkop report masked`, and review its contents before sending it: masking cannot identify every possible secret. Update the backend and LuCI packages together so their report formats agree.

On Linux, `python3 core/tests/plain_links.py CORE OUTPUT_DIR [REFERENCE_CORE]` compares generated HTTP(S)/SOCKS outbounds with the existing parser using local authenticated peers, including wrong-password and untrusted-certificate refusals. Use trusted, verified binary paths and a new output directory; pass the LoKi core reference when `CORE` is an official 1.14.4 binary. The test changes its own listeners and files only.

For generated proxy cascades, run `python3 core/tests/cascade_links.py CORE NEW_OUTPUT_DIR [REFERENCE_CORE]` with the same trusted binaries. It tests HTTP/HTTPS first hops, HTTP/HTTPS/SOCKS5 exits, both peers becoming unavailable, authentication/TLS refusals, stream interruption and recovery. A deliberately removed detour must be detected even when the response succeeds. All peers are local; this does not certify router routing or every cascade protocol.

## Documentation and testing

The public project documentation is maintained in this README and [README.ru.md](README.ru.md). The inherited documentation site and its GitHub Pages workflow have been removed.

Run tests and package builds on a dedicated Linux development server. DNS failures, traffic interception and installation must also be tested on a laboratory OpenWrt router before a release. Use synthetic credentials and local test endpoints for security tests.

## Origin and license

Forkop was developed by [ushan0v and its contributors](https://github.com/ushan0v/forkop/graphs/contributors). LoKi is maintained independently in [Zagorsky17/LoKi](https://github.com/Zagorsky17/LoKi); it is not an upstream Forkop release.

LoKi retains the project's [GPL-2.0-or-later license](LICENSE). The core patch and resulting sing-box-forkop core are distributed separately under [GPL-3.0-or-later](core/COPYING); the build produces `core-source-VERSION.tar.gz` with the patched core checkout, including its local `third_party` replacements. That archive does not include the external Go module cache or separately fetched Cronet sources. Distributing a binary also requires the matching build materials and the applicable dependency sources and notices; the archive alone is not a completed corresponding-source audit. Preserve existing copyright, license and attribution notices. Third-party components retain their own notices, including the [bundled font assets](luci-app-forkop/htdocs/luci-static/resources/view/forkop/fonts/LICENSE.md).

When distributing modified versions or binary packages, retain the applicable notices and license, identify modified files and their change dates, and provide the corresponding source as required by the [GNU GPL version 2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html). The software is provided without warranty under the license terms.

This README was rewritten for LoKi on October 31, 2026, and updated on November 4, 2026.

The binary-release license audit remains open. The frontend's inherited `package.json` declares MIT while backend/LuCI package metadata declares GPL-2.0-or-later; this discrepancy has not been resolved by changing either declaration. Linked core dependencies, the Go runtime, font provenance and the exact YACD build need their own notice/source checks for each released variant. The current YACD download follows an upstream branch, so it does not yet identify a fixed component for redistribution.
