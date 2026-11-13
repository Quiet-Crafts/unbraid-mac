# Third-party software

unbraid is built on other people's work. This file lists what the app includes or downloads and under which
licence. The complete licence texts, including every Go module linked into the sing-box library, ship inside the
app in `Resources/notices.txt` (Settings, About, All Licence Texts). `tools/notices.sh` regenerates that file after
a libbox build.

## Included in the app

| Component | Used for | Licence |
|---|---|---|
| [sing-box](https://github.com/SagerNet/sing-box) 1.14.4, with the patches in `tools/` | The VPN engine (Libbox), in the tunnel extension | GPL-3.0-or-later |
| [sing-openvpn](https://github.com/SagerNet/sing-openvpn), with the patch in `tools/` | OpenVPN inside the engine | GPL-3.0-or-later |
| [wireguard-go](https://github.com/sagernet/wireguard-go) (SagerNet fork) | WireGuard inside the engine | MIT, Copyright WireGuard LLC |
| [Tailscale](https://github.com/sagernet/tailscale) (SagerNet fork) | Tailscale and Headscale inside the engine | BSD-3-Clause |
| [gVisor](https://github.com/sagernet/gvisor) (SagerNet fork) | The engine's network stack | Apache-2.0 |
| Go standard library and runtime (Go 1.26.11) | Part of the engine | BSD-3-Clause |
| [sagernet/gomobile](https://github.com/sagernet/gomobile) | The engine's Objective-C bindings (generated code and its runtime) | BSD-3-Clause |
| Go modules linked into the engine | Protocols, crypto and networking in sing-box | Each module's own licence (GPL-3.0, LGPL-3.0, MPL-2.0, Apache-2.0, BSD, MIT, ISC, Unlicense, CC0), listed with its full text in `notices.txt` |
| [uTLS](https://github.com/metacubex/utls) | TLS fingerprints | BSD-3-Clause, with parts under LGPL-3.0 (with a static-linking exception) and MIT |
| [lzokay](https://github.com/jackoalan/lzokay) | The LZO code in go-lzo derives from it | MIT |
| [Big Shoulders Display](https://github.com/xotypeco/big_shoulders) | Font of the wordmark and headline numbers | SIL Open Font License 1.1 |
| [flag-icons](https://github.com/lipis/flag-icons) 7.2.3 | Country flags | MIT |
| Material Symbols (`alt_route`) | The route mark in the menu bar and the app icon, adapted | Apache-2.0, Google |
| [gluetun](https://github.com/qdm12/gluetun) | ExpressVPN OpenVPN profile and provider notes | MIT |
| [gluetun-servers](https://github.com/qdm12/gluetun-servers), at a pinned commit | Server lists for Proton VPN and ExpressVPN (`Resources/Catalog`) | MIT |
| [PIA manual-connections](https://github.com/pia-foss/manual-connections) | Sign-in and region steps for Private Internet Access | MIT |
| PIA certificate authority | Pinning TLS to PIA's WireGuard servers | MIT, from PIA manual-connections |

## Downloaded while the app runs

| Source | Used for | Licence |
|---|---|---|
| [gluetun-servers](https://github.com/qdm12/gluetun-servers) | Newer Proton VPN and ExpressVPN lists than the bundled ones; AirVPN's list when its own can't be reached; Surfshark server addresses when its host names don't resolve | MIT |
| Each provider's own API | Server lists, sign-in and keys | The provider's terms |

## Build tools

The app is built with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT), Go and gomobile; none of them is
part of the app. Each release's complete source, with every Go module the engine is built from, is published next to
its DMG (see the README's Licence section).

If you think something is missing or credited wrongly, please open an issue.
