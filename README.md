# Sill, hardened for one Mac on a Tailscale network

## What this does

This repository is a private fork of Sill. Sill shows a Mac window, or the whole desktop, on an iPad. The iPad sends taps, clicks, scrolls and keys back to the Mac.

In this fork, you build and run only the Mac host. You use the Sill iPad app from the App Store without a change. The host listens only on the Mac's Tailscale address.

## Why it exists

The upstream host opens two doors. One door uses Bonjour, peer-to-peer Wi-Fi and the USB cable. The other door can accept connections from the internet. This fork keeps one door, on one Tailscale address, for paired devices only.

The fork also removes the parts that call out to the developer's servers, such as the update check. `HARDENING-REPORT.md` gives each finding and each change.

## How it works

1. You write your Mac's Tailscale address in `~/Library/Application Support/Sill/tailscale.conf`.
2. The host binds its TLS listener to that address and port. It never binds to a wildcard address.
3. The host admits a connection only when it arrives on a tunnel interface from a Tailscale address.
4. A device pairs once with the QR code or the 12-digit code that the Mac shows.
5. After that, the device and the Mac pin each other's key. The device connects through Tailscale.

To build, sign and verify the host, follow `docs/BUILD-AND-VERIFY.md`.

The repository has these main parts:

- `Sources/SillHost/`: the host's core: capture, encoder, the door, pairing and input.
- `Sources/SillMenuBar/`: Sill.app, the menu bar app.
- `Sources/SillHostCLI/`: `SillHost`, the same host as a command-line tool.
- `Sources/StreamProtocol/`: the wire format that the host shares with the iPad app.
- `iOSClient/`: the iPad and iPhone client source. It is a reference only. Do not build it.
- `Tests/SillHostTests/`: unit tests of the hardening's rules.
- `Tests/checks/`: upstream's checks of single source files.

## Concepts

**Host.** The host is the Mac side of Sill. It captures windows, encodes them as HEVC video and sends them to the iPad. Sill.app and `SillHost` run the same host.

**Tailscale address.** Tailscale gives each device in your tailnet an address in 100.64.0.0/10, and an IPv6 address in fd7a:115c:a1e0::/48. Only devices that your Tailscale account admits can send packets to it. In this fork, the host listens on that one address.

**Door.** The door is the host's only TLS listener. It admits a paired device for a session, and an unpaired device only while you have a pairing window open. Everything else gets no Sill byte.

**TLS pinning.** Each side keeps the key of the other side from the pairing. A connection with another key fails before any Sill message. In this fork, the Mac and the iPad pin each other's P-256 key.

**Wire contract.** The wire contract is every byte format and rule that the iPad app expects from the host. The App Store app does not change with this fork, so the host keeps the contract. `docs/UPSTREAM.md` lists it.

## How it runs today

- The host listens only on the address in `tailscale.conf`, on port 7455 unless the file sets another.
- Without a usable file, the host opens no listener. The menu and the log say why.
- The host keeps the Mac out of idle sleep while it listens.
- The log is `~/Library/Logs/Sill/Sill.log`. At 10 MB it moves to `Sill.1.log`.
- `~/Library/Application Support/Sill/status.json` shows the host's health for the command line.
- The CI workflow runs only when you start it by hand.

## Known traps

- With FileVault on, the host starts only after you log in at the Mac after a restart.
- The host cannot work if Tailscale is not running on the Mac.
- Without a provisioning profile, Sill keeps its key in the login keychain. `docs/BUILD-AND-VERIFY.md` tells you how to clear old items before the first launch.
- Nobody has built or run this branch on a Mac yet.

## What changed recently

`docs/UPSTREAM.md` lists each hardening commit and the upstream commit that the fork started from.

## What is not done yet

- A build and a full test on a Mac with the App Store iPad app.
- A rebase onto a newer upstream commit.

## License

Sill is under the [Apache License 2.0](LICENSE). The upstream copyright notice in `LICENSE` stays as it is.
