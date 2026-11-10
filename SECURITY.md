# Security

unbraid handles VPN credentials and decides where every connection on your Mac goes, so security reports matter a lot
here.

## Reporting a problem

Please don't open a public issue for a security problem. Email info@unbraid.app instead, with "Security" in the subject
line. Describe what you found, which version you tested (Settings › About) and, if you can, the steps to reproduce it.
You'll get a reply within a few days.

Please give a reasonable amount of time for a fix before you publish details. Fixed issues are mentioned in the release
notes.

## What counts

Anything that could expose a user's traffic, DNS lookups, credentials or keys. Some examples: an app reaching the
internet outside its chosen route, a leak while the VPN connects, reconnects or pauses, secrets written to disk or logs
unencrypted, or a way for another app or another user on the Mac to read or change unbraid's settings or drive its
network extension.

Problems in sing-box itself are best reported to the [sing-box project](https://github.com/SagerNet/sing-box). If you're
not sure where a problem belongs, send it here.

## How unbraid is built

- **Secrets stay sealed.** Provider logins, keys, your setup and the Tailscale node state are stored on the Mac, sealed
  with keys kept in the Keychain. Copy Diagnostics masks keys, addresses, host names and your setup's own values.
- **One trusted channel.** The network extension takes commands only from unbraid's own signed app, over an XPC
  channel that checks the caller's code signature, and the app talks only to its own signed extension.
- **The extension runs only what unbraid writes.** Every configuration is checked before the engine runs it: no
  listener beyond one password-protected proxy on 127.0.0.1, no remote-control API, no files beyond its own cache and
  Tailscale state. The engine keeps no log lines and clears its DNS cache on every stop.
- **No way around the routes.** The tunnel captures IPv6 as well as IPv4: an app's IPv6 traffic follows that app's
  route or is refused, and only apps you send Direct (and your local network) use your own connection. An app's DNS
  lookups are answered on the exit that app uses.
- **A pinned engine.** sing-box is built from a fixed release with the patches in `tools/`, and every build checks the
  engine against its recorded hash. Each release scans the engine's Go modules for known vulnerabilities and runs the
  whole test suite against the engine before anything is signed.
- **Signed, notarized and traceable releases.** Each DMG is signed with a Developer ID, notarized by Apple, and
  published with its `SHA256SUMS` and the complete source of that release.

## Supported versions

Only the latest release gets security fixes.
