# LoKi

[Русский](README.ru.md) · English

> **This application is under active development.** Development stages are checked on Linux before review and merge. Router testing follows completion of the software stages. Stability on OpenWrt and behavior during DNS/TLS failures have not yet been confirmed in laboratory tests.

Rule-based traffic routing for OpenWrt, powered by sing-box. LoKi is an independently developed fork of [Forkop](https://github.com/ushan0v/forkop), starting from version 2.0.0 (`9544f3de09c62c935e1147147136234594d04f02`).

Project: [Zagorsky17/LoKi](https://github.com/Zagorsky17/LoKi). Report bugs and propose changes in [LoKi Issues](https://github.com/Zagorsky17/LoKi/issues).

## Development status

As of October 31, 2026, this repository has no LoKi release. The installer and application update checks use **`Zagorsky17/LoKi`**; application packages are fetched from this repository, with no fallback to Forkop releases. Installation requires a LoKi release with its package assets; publishing source to `main` alone is insufficient. The core still comes from `ushan0v/sing-box-forkop` until core compatibility work is complete. Installation and upgrade on a router remain untested.

The source still uses the technical names `forkop`, `luci-app-forkop` and `/etc/config/forkop`. Their coordinated replacement is planned together with configuration migration.

## Planned scope

LoKi will retain connection links, subscriptions, routing sections, DNS, monitoring and diagnostics. VPN servers, tunnels and migrations from Forkop 1.0.x are scheduled for removal; they are still present in the inherited source.

The target platforms are OpenWrt 24.10 and 25.12. Compatibility with the stock sing-box packages and newer versions remains to be implemented and tested. The inherited code currently requires `sing-box-forkop`.

The built-in lists from [forkop-lists](https://github.com/ushan0v/forkop-lists) and the diagnostic domains `ip.podkop.fyi` and `fakeip.podkop.fyi` are retained external dependencies.

## DNS settings in development

The development UI requires an explicit encryption mode for the entire main DNS list: disabled (UDP), or enabled with an explicit choice of DoH or DoT. Addresses must match: `https://dns.example/dns-query` for DoH, `tls://dns.example` for DoT, or an IP address for UDP. Replace the example name `dns.example` with your resolver. Changing the mode does not rewrite addresses or switch protocols when a server fails.

Bootstrap uses UDP by IP address. Outbound connections without their own resolver use bootstrap; explicit JSON and interface resolver settings are preserved. Fresh configurations retain the existing UDP default. Legacy configurations without the encryption field keep their URI protocols until an explicit mode is selected in the UI. These changes still require testing on laboratory OpenWrt.

## Diagnostic reports

Reports open with values masked. An unmasked report requires confirmation and starts with a warning that it contains keys and passwords. Copy and download are disabled while switching modes; afterwards they export the displayed mode. For a report to share, use the masked mode or `forkop report masked`, and review its contents before sending it: masking cannot identify every possible secret. Update the backend and LuCI packages together so their report formats agree.

## Documentation and testing

The public project documentation is maintained in this README and [README.ru.md](README.ru.md). The inherited `docs/` site describes Forkop and is scheduled for removal.

Run tests and package builds on a dedicated Linux development server. DNS failures, traffic interception and installation must also be tested on a laboratory OpenWrt router before a release. Use synthetic credentials and local test endpoints for security tests.

## Origin and license

Forkop was developed by [ushan0v and its contributors](https://github.com/ushan0v/forkop/graphs/contributors). LoKi is maintained independently in [Zagorsky17/LoKi](https://github.com/Zagorsky17/LoKi); it is not an upstream Forkop release.

LoKi retains the project's [GPL-2.0-or-later license](LICENSE). Existing copyright, license and attribution notices are preserved. Third-party components retain their own notices, including the [bundled font assets](luci-app-forkop/htdocs/luci-static/resources/view/forkop/fonts/LICENSE.md).

When distributing modified versions or binary packages, retain the applicable notices and license, identify modified files and their change dates, and provide the corresponding source as required by the [GNU GPL version 2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html). The software is provided without warranty under the license terms.

This README was rewritten for LoKi on October 31, 2026, and updated on November 1, 2026.
