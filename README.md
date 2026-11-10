<p align="center"><img src=".github/icon.png" width="128" alt=""></p>

# unbraid for Mac

Every app, its own exit. unbraid sends each app on your Mac through a different VPN location at the same time: a
streaming app leaves from the US, another from Italy, your banking app skips the VPN, an app you don't trust gets no
network at all, and everything else leaves from the Netherlands. Your home network stays reachable over Tailscale.

This is the native macOS version of [unbraid for Android](https://github.com/Quiet-Crafts/unbraid). Free and open
source.

[Website](https://unbraid.app) · [Download](https://unbraid.app/download/) · [Guides](https://unbraid.app/guides/) ·
[Privacy policy](https://unbraid.app/privacy/)

## What it does

- **Routes**: a default exit for all other apps, plus any number of exceptions. An app can also go **Direct** or be
  **Blocked**.
- **Providers**: NordVPN (NordLynx, OpenVPN, Double VPN, Onion), Mullvad, Private Internet Access, IVPN, Proton VPN
  (including Free), Surfshark, ExpressVPN, Windscribe and AirVPN, plus your own WireGuard, OpenVPN and Shadowsocks
  servers and Tailscale exit nodes. Routes can mix providers.
- **Home access** through Tailscale (or a self-hosted Headscale) or a WireGuard tunnel, from every app.
- **Profiles**: save a setup and switch it from the window, the menu bar, Control Center or the Shortcuts app.
- **Menu bar** control with the front app's route one click away, and **desktop widgets**.
- **Insights**: data per exit and app, live speed, protected time, and speed tests through each exit (M-Lab).
- **Protection**: kill switch, connect on demand, a DNS filter of your choice, provider ad blocking, and health
  checks that move a route whose server stopped answering.

You bring the VPN: unbraid has no servers of its own and works with the accounts and servers you already have.

## Install

Download the DMG from [unbraid.app/download](https://unbraid.app/download/) or from this repository's
[releases](https://github.com/Quiet-Crafts/unbraid-mac/releases), open it and drag unbraid to Applications. It needs
macOS 26 or later, on a Mac with Apple silicon or an Intel processor.

When you first open unbraid, macOS asks you to allow its network extension (System Settings › General › Login Items &
Extensions), and the first time you connect, to add a VPN configuration. unbraid needs both to route each app.

Each release lists a `SHA256SUMS` file. To check a download, put it in the same folder and run
`shasum -a 256 -c SHA256SUMS`. Releases are signed with a Developer ID and notarized by Apple:
`spctl --assess --type open --context context:primary-signature -v unbraid-<version>-<build>.dmg` prints
`source=Notarized Developer ID`.

## How it works

A packet tunnel system extension runs the [sing-box](https://github.com/SagerNet/sing-box) engine. Each connection is
matched to the app that owns it (its process path, including helpers inside the app bundle and sockets opened for it
by macOS services) and sent to that app's exit. DNS answers are fake addresses resolved again on the exit the app uses,
so services see the right country. The app compiles the configuration, picks servers and watches their health; the
extension only runs the engine.

```
apps ─► utun ─► sing-box ─► rules: DNS → blocked → home → LAN → the app's route → default
                             ├─ WireGuard / OpenVPN / Shadowsocks exits, one per location
                             ├─ Tailscale (home, exit nodes)
                             └─ direct
```

### Repository layout

| Path | What it holds |
|---|---|
| `App/` | The app: `Core/` (configuration compiler, models, parsers and the HTTP client; most of it unit tested), `Engine/` (the connection, tunnel control, app catalogue, statistics), `Providers/` (one file per VPN provider), `UI/` (SwiftUI window, Settings, menu bar panel) |
| `Tunnel/` | The packet tunnel system extension that runs the engine |
| `Widgets/` | Desktop and Notification Centre widgets |
| `Shared/` | Code used by more than one target: the sealed store, the XPC protocol, the configuration check the extension runs |
| `Tests/` | Unit tests, with synthetic fixtures and golden engine configurations |
| `Resources/` | Assets, server catalogues, fonts and the licence notices shown in the app |
| `Config/` | Signing settings (`Signing.xcconfig`; your own go in `Local.xcconfig`) |
| `Frameworks/` | The engine's recorded hash (`Libbox.sha256`); the engine itself is built by `tools/build-libbox.sh` |
| `tools/` | Build, release and engine scripts, the sing-box patches with their notices, and the repository's git hooks |
| `project.yml` | The Xcode project's source ([XcodeGen](https://github.com/yonaskolb/XcodeGen)); `unbraid.xcodeproj` is generated from it |

## Build

You need macOS 26, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Go 1.21 or later installed: the
scripts pin Go 1.26.10, which Go then fetches by itself (upstream sing-box 1.14.4 builds with 1.26.10).

```bash
tools/build-libbox.sh     # Frameworks/Libbox.xcframework from sing-box 1.14.4 plus unbraid's patches (including its OpenVPN module)
xcodegen                  # unbraid.xcodeproj from project.yml
tools/dev-install.sh      # Debug build into /Applications (system extensions run only from there)
```

`tools/build-libbox.sh` keeps its sing-box checkout in `WORK` (default `~/Development/unbraid-mac-deps`) and resets it on
every run, so give it a folder of its own. The engine's hash in `Frameworks/Libbox.sha256` comes out the same with the
same Xcode; another Xcode version builds a working engine with a different hash, which you then record yourself.

**Running it** takes an Apple Developer Program membership: the tunnel is a Network Extension system extension, which
needs a signing team with that capability. To sign with your own team, create `Config/Local.xcconfig` (git ignores it)
with your team ID and a bundle-ID prefix of your own, as described in `Config/Signing.xcconfig`. Your build then has its
own bundle IDs, app group and extension, but it shares unbraid's data folder and `unbraid:` links, so don't run both on
one Mac. `tools/xc.sh` lets Xcode create the signing profiles: with your Xcode account, or with an App Store Connect API
key (`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH`, from the environment or `.secrets/asc.env`).

The tunnel is a system extension: macOS asks you to allow it once in System Settings › General › Login Items &
Extensions.

### Tests

The unit tests build and run without signing (no app, extension or engine needed):

```bash
xcodebuild -project unbraid.xcodeproj -scheme UnbraidTests -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

They cover the providers' parsers and sign-in checks, the configuration compiler, server picking, the OpenVPN,
WireGuard and Shadowsocks imports, statistics, the speed test's parsing, Tailscale link checks and log redaction.
The tests that check every generated configuration against the engine itself need its command-line build: run
`tools/build-cli.sh` first, or they are skipped. With your own `WORK`, add
`TEST_RUNNER_UNBRAID_SING_BOX="$WORK/sing-box-cli-mac"` to the test command so they find it.

### Releases

`tools/release.sh` builds a release from a clean commit: it checks the engine against its recorded hash, scans the
engine's Go modules for known vulnerabilities (govulncheck), runs the whole test suite with the engine (every test must
pass, none skipped), writes the complete source archive, then archives, signs with Developer ID, checks every
signature and entitlement, notarizes and staples the DMG, and tags the commit. `tools/release.sh --check-only` runs the
checks and tests and stops before anything is archived or signed. It refuses a `Config/Local.xcconfig` unless
`ALLOW_LOCAL_XCCONFIG=1`; it then takes only the signing settings from it and puts it in the source archive.

## Updates

unbraid doesn't check for updates by itself, and has no updater. Help › Check for Updates… opens the download page on
unbraid.app. To update, quit unbraid, replace the app in Applications with the one from the newer DMG and open it: it
then asks macOS to update its network extension, which may need your approval again. A release never replaces its
extension with an older build.

## Privacy

No analytics, no accounts of its own, no servers of its own. Provider sign-ins, keys and the Tailscale node state are
stored on this Mac, sealed with keys kept in the Keychain; a provider gets its own login, token or account number only
when you sign in, connect or sign out, open its page in Settings (your plan, this Mac's device and the account's
limits), or browse NordVPN's dedicated IP servers. Statistics are off until you turn them
on, stay on this Mac, and can be deleted at any time. The list of installed apps is read only on this Mac (after you
agree, on a new install).

What unbraid itself contacts, and why. These requests leave from your Mac's own connection unless they say "through"
a tunnel:

- **Your VPN providers**, only the ones you use, at sign-in, connect and sign-out, when you open their page in Settings,
  and for their server lists (when unbraid
  starts, then about once a day, and when you browse servers, connected or not): NordVPN (api.nordvpn.com,
  downloads.nordcdn.com), Mullvad (api.mullvad.net), Private Internet Access (www.privateinternetaccess.com,
  serverlist.piaservers.net, and the WireGuard API of the server you connect to), IVPN (api.ivpn.net). Surfshark
  (api.surfshark.com), Windscribe (assets.windscribe.com) and AirVPN (airvpn.org) get only requests for public lists.
- **GitHub** (raw.githubusercontent.com): the community server lists of
  [gluetun-servers](https://github.com/qdm12/gluetun-servers) for Proton VPN (including Free) and ExpressVPN, and as a
  fallback for Surfshark and AirVPN. GitHub sees which provider's list is fetched, never a login.
- **Connection checks**, about once a minute while connected, through each provider tunnel that unbraid can move to
  another server (not imported servers, pinned servers, dedicated IPs or Tailscale), each on its own schedule: a STUN
  request to stun.l.google.com:19302 and one to stun.cloudflare.com:3478, both at the same time, and a TLS handshake with
  www.google.com:443 if neither has answered after 3 seconds; the check gives up after 8 seconds. Always through the
  tunnel being checked, never from your own address.
- **DNS**: an app on a VPN looks names up through its tunnel, with your custom DNS server if you set one, else the
  provider's or the one its configuration or OpenVPN server gives, else Quad9 (9.9.9.9) for WireGuard, Shadowsocks and
  Tailscale exits that name none. Direct apps use your network's resolver, and so do local names (with local network
  access on) and reverse lookups of private addresses. Some lookups macOS makes for apps itself (mail, service and text
  records) follow the default route.
- **Tailscale**, only if you set it up: its control server (login.tailscale.com, controlplane.tailscale.com) or your
  Headscale, Tailscale's relays and your tailnet's devices. They receive what a Tailscale client sends: the device's
  public keys, its addresses and ports, its OS and version, network checks, and your auth key if you give one; the
  device is named "unbraid". Tailscale's log upload is left out of unbraid. Apps on a Tailscale exit reach Tailscale's
  own sites and your Headscale server directly, so the exit can't block its own sign-in.
- **M-Lab** (locate.measurementlab.net and a test server), only for a speed test you start, after you accept its data
  policy, through the exit you test. M-Lab publishes the results, including the IP address it sees.

The VPN servers, your own servers and your home network carry the traffic of the apps you send there. Links you open
from the app (unbraid.app, provider account pages, Tailscale sign-in) open in your browser and follow its route. The
[privacy policy](https://unbraid.app/privacy/) has the details.

## Contributing and security

Bug reports are welcome in this repository's issues; [CONTRIBUTING.md](CONTRIBUTING.md) says what helps most. Please
report security problems privately, as [SECURITY.md](SECURITY.md) describes.

## Support

unbraid is free and made by one person. If it is useful to you, you can
[support unbraid with a donation](https://unbraid.app/donate/).

## Licence

GPL-3.0-or-later, as required by sing-box. Not affiliated with any VPN provider, Tailscale or SagerNet.
[THIRD-PARTY.md](THIRD-PARTY.md) lists the components unbraid is built from and their licences.

The complete source of each release is published next to its DMG, as `unbraid-<version>-<build>-source.tar.gz`: this
repository at the release commit, sing-box with unbraid's patches applied, every Go module the engine is built from,
and `BUILDING.txt` with the toolchain versions and commands (`tools/source-archive.sh` makes it). The full licence
texts ship inside the app (Settings › About › All Licence Texts).
