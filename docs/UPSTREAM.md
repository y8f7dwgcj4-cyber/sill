# Upstream and the hardening commits

## What this does

This document records the upstream commit that the hardening started from. It lists each hardening commit and what it does. It also tells you how to move the hardening onto a new upstream release.

## Why it exists

The hardening is a set of small commits on top of upstream. You will want new upstream fixes later. A rebase is safe only when you know each commit and when you check the wire contract again after it.

## How it works

The `hardening` branch starts at the upstream commit below. Each later commit makes one change. Most commits touch the Mac host only. No commit changes `iOSClient/`.

### The upstream commit

- Repository: `https://github.com/Saffsanity/sill`
- Commit: `4d990e9b92d5b87b4b4afed6213ffbab91ac0f39`
- Title: "Merge pull request #88 from ipavlidakis/universal-mac-app"
- Date: 2026-10-20

### The hardening commits, oldest first

| Commit | What it does |
|---|---|
| `e4737d2` | Adds `HARDENING-REPORT.md` with the Phase 0 to 2 results. |
| `161588c` | Runs CI only when you start it by hand. Removes the release and TestFlight workflows. |
| `8d40fd8` | Removes the app's test hooks and its preview renderer, which took launch arguments. |
| `c015796` | Removes the update check, the only call to GitHub. |
| `80e6aac` | Removes the home door, Bonjour, Direct Wireless, cable pairing, the pairing ask, Require pairing, the internet switch and the router query. |
| `cb56018` | Adds `TailnetConfig`, the parser of `tailscale.conf`, and `docs/tailscale.conf.example`. |
| `47bb25b` | Binds the door to the configured Tailscale address only. Adds the retry with backoff and the rebind. |
| `cef8f21` | Admits only a tunnel arrival from a Tailscale source. |
| `635449e` | Gives devices only the configured address in kind 18 and in the pairing link. Adds `--print-tailnet`. |
| `bb61b2f` | Makes the CI step check `--print-tailnet`. |
| `02d332f` | Turns the door on by default in the app and in the CLI. |
| `0b2bb23` | Keeps the Mac out of idle sleep while the door listens. |
| `04fbd36` | Writes `status.json` for health checks from the command line. |
| `ddfc119` | Adds the LaunchAgent template. |
| `368bba1` | Checks the Tailscale address again after a wake from sleep. |
| `4c948a7` | Reads your signing values from an untracked `Packaging/Local.xcconfig`. Removes the upstream team's entitlements file. |
| `3c903fd` | Adds `Scripts/check-personal-info.sh`. |
| `a710e07` | Fixes two errors in that scan. |
| `62d2fc6` | Adds the `SillHostTests` unit test target. |
| `a97681b` | Removes the release tools, the website and other upstream-only files. |
| `a7c403c` | Removes the pacing harness and fixes the menu check's server. |
| `ee2b140` | Adds team IDs and other IPv4 addresses to the scan. |
| `c5a9b22` | Adds the optional pf anchor template. |

Later commits add the documents and fix review findings. `git log 4d990e9..hardening` shows all of them.

### Move the hardening onto a new upstream release

1. Add upstream as a fetch-only remote: `git remote add upstream https://github.com/Saffsanity/sill.git`.
2. Stop pushes to it: `git remote set-url --push upstream DISABLED`.
3. Fetch it: `git fetch upstream`.
4. Read every upstream commit since `4d990e9`: `git log -p 4d990e9..upstream/main`.
5. Look for new listeners, new network calls, new message kinds and new scripts. Treat each one as untrusted.
6. Make a new branch: `git switch -c hardening-next hardening`.
7. Rebase it: `git rebase upstream/main`.
8. Resolve each conflict. Keep the hardening's rule when a conflict touches a listener, the origin rule or the keychain.
9. Check the wire contract again, with the list below.
10. Do all the steps in `docs/BUILD-AND-VERIFY.md` again.
11. Update the upstream commit in this document.

### The wire contract to check again

The App Store iPad app depends on these items. A rebase must not change any of them:

- the 14-byte message header in `Sources/StreamProtocol/StreamMessage.swift`
- the message kinds 0 to 28 and 32, and their payloads
- the ALPNs `sill/1` and `sill-pair/1`, and the SNI `sill`, in `Sources/StreamProtocol/RemoteTLS.swift`
- TLS 1.3 with self-signed P-256 certificates and SPKI SHA-256 pins
- the pairing link `sill://pair?…` in `Sources/StreamProtocol/Pairing.swift`
- the pairing proofs and the 12-digit code with PBKDF2-SHA256 at 600,000 rounds
- the fields of kinds 18, 19, 20 and 22 in `Sources/StreamProtocol/Remote.swift`
- the hello, kind 23, and the device floor "0" in `Sources/SillHost/DeviceGate.swift`
- the default port 7455

## Concepts

**Upstream.** Upstream is the original Sill repository. In this system it is a fetch-only remote, so a push can never go there by mistake.

**Rebase.** A rebase moves a set of commits onto a new base commit. Small commits with one change each make the conflicts small.

**Wire contract.** The wire contract is every byte format and rule that the iPad app expects from the host. The App Store app cannot change with this fork, so the host must keep the contract.

## How it runs today

The `hardening` branch is in your fork. No upstream remote is set in the cloud session that made it.

## Known traps

- Many code comments name a plan under `docs/`, such as `docs/remote-access-plan.md`. The fork removed those plans. Read them in upstream at `4d990e9`.
- Upstream can add a listener or a network call in a file that the hardening does not touch. Such a change gives no conflict. Read each upstream commit.
- A new upstream feature can need the home door, Bonjour or the internet switch. Leave such a feature out.
- The CI workflow runs only by hand. A rebase that brings upstream's workflow back can make it run on each push. Look at `.github/workflows/` after each rebase.

## What changed recently

The branch was made from `4d990e9` on 2026-10-20.

## What is not done yet

No rebase onto a newer upstream commit has been done.
