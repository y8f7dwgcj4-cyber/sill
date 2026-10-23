# Hardening report: Sill host for one Mac on a Tailscale network

Status: Phase 3 and Phase 4 are done on the `hardening` branch. Sections 1 to 8 are the checkpoint report, as you approved it. Sections 9 to 13 tell you what changed, what did not, and what is open. Nobody has built or run the branch.

## 1. Scope and start point

- Upstream: `https://github.com/Saffsanity/sill`.
- Start commit: `4d990e9b92d5b87b4b4afed6213ffbab91ac0f39` ("Merge pull request #88 from ipavlidakis/universal-mac-app", 2026-10-20). The fork `main` and the upstream `main` had the same commit when the review started.
- Branch: `hardening`. Commit identity: a GitHub noreply address.
- Target: the macOS host only (`Sill.app`, the `SillMenuBar` executable). The iPad app stays the App Store build.

### 1.1 Method and limits

- I read the source. I ran nothing from the repository. I did not build anything.
- I did not register the repository with the session. The session loaded `CLAUDE.md` by itself when the work directory moved. I used it as data only.
- `iOSClient/` is the best description of the App Store app. I cannot confirm that the App Store binary matches this source.
- Line references are for the start commit.

### 1.2 Instructions found in the repository

The repository content contains instructions. I did not follow them as instructions. Examples:

- `CLAUDE.md`: "Read `docs/BRIEF.md` before doing product-level work."
- `CLAUDE.md`: "Decisions already made (don't relitigate without asking Noah)".
- `CLAUDE.md`: "Operational rule, from the same logs: while Noah streams, agents do not run `simctl io recordVideo`, SillHost streams, ReelRenderer or encoder benchmarks".
- `CLAUDE.md`: "A change to a checked file updates its check (and a mutant's pattern) in the same commit."
- `README.md` and `docs/DEVELOPMENT.md` tell the reader to run `Scripts/make-app.sh --install --open`.

## 2. Phase 0: supply chain

### 2.1 Build system

- The Mac host has no Xcode project. SwiftPM builds it (`Package.swift`). `Scripts/make-app.sh` wraps the `SillMenuBar` executable into `Sill.app` and signs it.
- The only Xcode project is `iOSClient/Sill.xcodeproj`, for the iPad app. It has no run-script phases and no build rules. Its build phases are `PBXFrameworksBuildPhase`, `PBXResourcesBuildPhase` and `PBXSourcesBuildPhase` (`project.pbxproj:113`, `:255`, `:267`). Its one package reference is the local package `..` (`project.pbxproj:531`).
- `DEVELOPMENT_TEAM` (`project.pbxproj:355`, `:420`) and `PRODUCT_BUNDLE_IDENTIFIER` (`:466`, `:498`) are in the iPad project only. They are the upstream developer's values, not yours.

### 2.2 Swift Package dependencies

- None. `Package.swift` lists no dependencies. There is no `Package.resolved`.
- Targets: `StreamProtocol`, `SillHostCore` (folder `Sources/SillHost`), `SillHostCLI`, `SillMenuBar`, `CaptureProbe`, `VirtualDisplayProbe`.
- `Sources/VirtualDisplayProbe/VirtualDisplay.swift` is a symbolic link to `../SillHost/VirtualDisplay.swift`. It points inside the repository.

### 2.3 Scripts, binaries and blobs

- No `.xcframework`, no `.a`, no `.dylib`, no `.framework`, no archive and no executable binary is in the repository.
- Binary files: six JPEG screenshots in `design/screenshots/`, `site/preview.jpg` and `iOSClient/Assets.xcassets/AppIcon.appiconset/AppIcon.png`. Each file ends at its end marker. No file has data after the image.
- Shell and Python scripts: `Scripts/` (40 files: `make-app.sh`, `make-dmg.sh`, `release.sh`, `release-ios.sh`, encoder, menu, pacing and restore probes, `sillclient.py`, `sillfeed.py`, `sillrelay.py`), `Tests/checks/*/run.sh`, `build.sh`, `mutants.py`, `Tests/duorig`, `Tests/keyrig`, `Tests/touchrig`.
- `Tests/duorig`, `Tests/keyrig` and `Tests/touchrig` use private Apple interfaces for the iOS Simulator only.
- `Scripts/make-app.sh` does these steps on your Mac: `swift build`, `vtool`, `qlmanage`, `actool`, `codesign`, `security find-identity`, and with `--install` it does `pkill` on a Sill process, `rm -rf /Applications/Sill.app` and `lsregister`. It makes no network connection.
- `Scripts/release.sh` and `Scripts/release-ios.sh` use `notarytool`, `gh release` and App Store Connect. You do not need them.

### 2.4 Entitlements and Info.plist (host)

- `Packaging/SillDebug.entitlements`: `com.apple.security.get-task-allow` only. A debugger can attach to the app.
- `Packaging/SillRelease.entitlements`: `com.apple.application-identifier`, `com.apple.developer.team-identifier` and `keychain-access-groups`, all for team `9B2KKVM937`. `make-app.sh --release` uses it only with a Developer ID provisioning profile. A build with a free personal team cannot use it.
- No App Sandbox. Hardened runtime is on (`codesign --options runtime`).
- `Packaging/Info.plist`: bundle ID `me.saffer.sill.mac`, `LSUIElement` true, `NSBonjourServices` `_sill._tcp`, `NSLocalNetworkUsageDescription`.

Permissions that the host asks for:

| Permission | Where | Why |
|---|---|---|
| Screen Recording | ScreenCaptureKit (`WindowCapture.swift`) | Window and desktop capture. |
| Accessibility | `WindowSizer.swift`, `MenuReader.swift`, `InputInjector.swift` | Move and resize windows, read and press menus, activate apps. |
| Event post | `CGEvent` post in `InputInjector.swift` | Keyboard and mouse input from the device. macOS gives it with Accessibility. |
| Local Network | Bonjour, the listeners | The home door. |
| Paste from other apps | `NSPasteboard` (`HostClipboard.swift`) | Clipboard sync. macOS 15.4 and later asks. |
| Login item | `SMAppService.mainApp` (`LoginItem.swift`) | Launch at Login. |

The host also calls a private API, `CGVirtualDisplay`, through the Objective-C runtime (`VirtualDisplay.swift`). It needs no entitlement.

### 2.5 Outbound network connections

| Connection | Where | When |
|---|---|---|
| `https://api.github.com/repos/Saffsanity/sill/releases/latest` | `UpdatePolicy.swift:15`, `UpdateChecker.swift` | 30 s after launch, then every 24 h, and on Check Now. On by default. |
| NAT-PMP or PCP query to the router | `RouterAddress.swift:25` (`DNSServiceNATPortMappingCreate`, all ports zero) | Only with Remote Access and internet access on. It asks for the external address. It makes no port mapping. |
| DNS lookup of the Mac's MagicDNS name | `Reachability.swift:168` (`getaddrinfo`) | While the remote door runs. It checks that the name resolves to the Mac's own Tailscale address. |
| `NSWorkspace.open` of a release page or System Settings | `StatusItemController.swift:302`, `SettingsPanes.swift:128`, `Permissions.swift:92` | Only when you click. |

There is no analytics, no crash reporter, no licence check, no remote configuration and no Sparkle.

### 2.6 Automatic update

- `UpdateChecker` shows "Sill X Is Available" and opens the release page in the browser. It downloads and installs nothing.

### 2.7 CI under `.github/`

| File | Trigger | What it does in your fork |
|---|---|---|
| `workflows/ci.yml` | push to `main`, pull requests, manual | Builds on a `xcode-27` macOS runner, runs `Tests/checks`, builds the iPad app. No secrets. |
| `workflows/release.yml` | push of a tag `v*`, manual | Without secrets it builds an ad hoc `Sill.app` and uploads it as an artifact. With secrets it signs, notarizes and publishes. |
| `workflows/testflight.yml` | manual only | Builds and can upload the iPad app to TestFlight. |
| `actions/select-xcode` | used by the workflows | Runs `sudo xcode-select` on the runner. |

- The actions are pinned to commit hashes.
- GitHub turns off Actions in a new fork until the owner turns them on.
- A push to `hardening` starts no workflow. Plan item C1 changes `ci.yml` and `release.yml` to manual triggers only.

## 3. Phase 1: the system and the compatibility contract

### 3.1 Listeners

Your earlier analysis is correct, with three additions.

**Home door.** `StreamServer.swift`.

- `makeListener` (`StreamServer.swift:591`) creates an `NWListener` with no local address. It listens on every interface, on a port that the system selects at each launch (`:613`).
- `bindToLoopback` (`:624`) is for test hosts only. It runs only with `SILL_TEST_LOOPBACK=1` on a host that does not advertise and is not `Sill.app`.
- The listener advertises `_sill._tcp` with the Mac's name and a TXT record (`r`, the recognition tag, and `p`, the door type) (`:431`, `:883`).
- In `Sill.app` it speaks TLS 1.3 with pinned keys (`StreamCoordinator.swift:303`). The CLI speaks plain TCP unless you give `--pairing`.
- `OriginPolicy.homeAdmits` (`OriginPolicy.swift:91`) admits loopback, `direct` (AWDL) and `lan`. Addition 1: `lan` also includes every RFC 1918 or ULA source that arrives on a non-tunnel interface, on-link or not (`:79`).
- Addition 2: if the identity cannot load, the home door stays closed (`.closed`, `StreamCoordinator.swift:305`). The server makes the listener but does not start it (`StreamServer.swift:864`).

**Remote door.** `RemoteServer.swift`.

- Port 7455 by default (`HostConfig.swift:90`, `:94`). It listens on every interface (`RemoteServer.swift:99`).
- It runs while Remote Access is on, or while a pairing window that you opened is open (`RemoteAccess.swift:860`).
- `OriginPolicy.remoteAdmits` (`OriginPolicy.swift:97`) admits loopback, `lan` and `vpn`, and `internet` only with internet access on. It never admits AWDL.
- Addition 3: a source is `vpn` because it arrives on a tunnel interface (`utun`, `wg` and others). The code does not check the Tailscale ranges for this.

**Other listeners.** None. There is no XPC service, no helper tool and no URL scheme in the host.

### 3.2 How the iPad app finds and connects to the host

| Method | Code | Across Tailscale |
|---|---|---|
| Bonjour browse of `_sill._tcp` (Wi-Fi, Ethernet rows) | `StreamClient.swift`, `DiscoveryPolicy.swift` | No. Multicast does not cross Tailscale. |
| AWDL (Direct Wireless) | `DiscoveryPolicy.swift` | No. |
| USB cable (a Bonjour row on the cable interface) | `StreamClient+Home.swift` | No. |
| Add a Mac: QR scan of a `sill://pair` link | `CodeScanner.swift`, `StreamClient+Remote.swift:862` | Yes. The link carries the addresses and the port. |
| Add a Mac: typed address and 12-digit code | `StreamClient+Remote.swift:816`, `:871` | Yes. The port is 7455 when you type none (`:1084`). |
| A `sill://pair` link from another app | `StreamClient+Remote.swift:791` | Yes, after a confirmation. |
| Dial of a saved Mac (remote rows, reconnect) | `StreamClient+Remote.swift:293`, `RemoteConnector.swift` | Yes. It dials the saved addresses with ALPN `sill/1`. |

### 3.3 Which door each pairing method uses

| Method | Door | Notes |
|---|---|---|
| QR code from Pair iPhone or iPad… | Remote door, ALPN `sill-pair/1` | The device pins the Mac key from the link. The proof key is the link's 16-byte secret. |
| Typed 12-digit code from Pair iPhone or iPad… | Remote door, ALPN `sill-pair/1` | PBKDF2-HMAC-SHA256, 600,000 rounds (`Pairing.swift:81`). Window of 300 s, 5 wrong proofs close it (`PairingWindow.swift:75`, `:76`). No PAKE. |
| Ask ("pair me") from a home row | Home door, kind 19 `ask` | The Mac opens a pairing window by itself (`DoorPolicy.swift:252` and the ask rule). |
| USB cable | Home door, kind 19 `ask` with `cable: true` | Pairs with no code while the Mac is unlocked (`DoorPolicy.swift:252`). |
| Pair This iPad… over a home session | Home door | Needs a home session. |

**The key question.** Yes. The App Store app can pair with, and then connect to, a host that has only a remote door on a Tailscale address:

1. On the Mac, open Pair iPhone or iPad…. The window is a remote window (`forRemote` true), so the remote door takes its proofs (`DoorPolicy.swift:75`, `:105`).
2. On the iPad, use Add a Mac. Scan the QR code, or type the Tailscale address and the code.
3. The device saves the Mac's key, the port and the addresses (`StreamClient+Remote.swift:1033`). It then dials the saved Mac with `sill/1` (`dialSaved`).
4. The remote door admits a paired key while Remote Access is on (`DoorPolicy.atReady`).

Conditions: Remote Access must be on. The QR link must hold the Tailscale address. If you type the address, the device saves only that address until a kind 18 message adds more.

### 3.4 The compatibility contract

Nothing in this list may change. File references are for the host side unless the row says otherwise.

| Item | Value | Where |
|---|---|---|
| TLS | TLS 1.3 only. Mutual. Self-signed P-256 certificates. Tickets and resumption off. | `RemoteTLS.swift:53` |
| Server ALPNs | `sill/1` and `sill-pair/1`, both, always | `RemoteTLS.swift:35` |
| Client SNI | `sill` (the host ignores it) | `RemoteTLS.swift:38` |
| Key pin | SHA-256 of the P-256 SubjectPublicKeyInfo DER | `RemoteIdentity.swift` (`SPKI`) |
| Mac ID | Crockford base32 of the first 10 bytes of the pin | `RemoteIdentity.swift` (`MacID`) |
| Certificate | Hand-built X.509 v3, ECDSA-SHA256, random CN and serial | `RemoteIdentity.swift` (`SelfSignedCertificate`) |
| Framing | 14-byte header: kind (1), timestamp (8, Double, big endian), keyframe (1), length (4, big endian) | `StreamMessage.swift:4` |
| Payload caps | Client to host 1 MiB, pairing 4 KiB, frame 32 MiB, other host messages 4 MiB | `StreamMessage.swift:95` |
| Message kinds | 0 to 28 and 32, with their JSON or binary payloads | `StreamMessage.swift:5`, `Switcher.swift`, `Input.swift`, `Viewport.swift`, `HostSettings.swift`, `Remote.swift`, `Compatibility.swift`, `Pointer.swift`, `MacMenu.swift`, `Gesture.swift`, `Clipboard.swift` |
| Video | HEVC, no B-frames, parameter sets as kind 0 | `HEVCEncoder.swift`, `StreamMessage.swift:138` |
| Hello | Kind 23, the first message of every session | `Compatibility.swift` |
| Protocol version | `SillProtocol.current` = 1 | `Compatibility.swift` |
| Device floor | `DeviceGate.minimumDeviceVersion` = "0" | `DeviceGate.swift` |
| Window list fields | `hostVersion`, `protocol`, `launchID`, `gestures`, `clipboard` | `Switcher.swift` |
| Pairing request | Kind 19 `PairRequest`: `method` (`qr`, `code`, `ask`, `cancel`), `proof`, `name`, `model`, `cable`, `v` = 1 | `Remote.swift` |
| Pairing result | Kind 20 `PairResult`: `ok`, `reason`, `proof`, `macID`, `name`, `recognitionKey`, `triesLeft`, `retryAfter`, `method`, `message` | `Remote.swift` |
| Proofs | `proof_D` and `proof_M` as HMAC-SHA256 over the label, a zero byte and both pins | `Pairing.swift:80` |
| Typed code | 11 random digits and a Damm check digit | `Pairing.swift:14` |
| QR link | `sill://pair?v=1&m=&k=&s=&n=&p=&a=` (up to 5 `a`) | `Pairing.swift:223` |
| Mac info | Kind 18 `SignedMacInfo`, signed with the Mac key | `Remote.swift` |
| Goodbye | Kind 22: `reason`, `message`, `minimumVersion`, `reconnect` | `Remote.swift` |
| Bonjour (home door only) | `_sill._tcp`, TXT `r` and `p` | `Pairing.swift:138`, `:185` |
| Remote port | 7455 is the device's default for a typed address | `iOSClient/StreamClient+Remote.swift:1084` |

The device does not check the host's bundle ID or code signature. It checks the key pin and the Mac ID only.

## 4. Phase 2: security review

Severity is for your target setup: one Mac, one owner, a Tailscale network, the App Store iPad app.

| ID | Severity | Finding | Touches the contract |
|---|---|---|---|
| S1 | High | The remote door listens on every interface. | No |
| S2 | High | The home door listens on every interface and advertises on Bonjour. Unpaired devices on the LAN reach pairing. | No (the door goes) |
| S3 | High | The CLI's default home door is plain TCP with no authentication. | No |
| S4 | Medium | The USB cable pairs with no code. | No (the door goes) |
| S5 | Medium | Require pairing off lets any key on the LAN in. | No (the door goes) |
| S6 | Medium | A self-signed build uses the legacy login keychain. Another process can plant the items first. | No |
| S7 | Medium | Remote Access, the port and internet access come from `UserDefaults` and launch arguments. | No |
| S8 | Medium | The update check contacts the upstream GitHub repository every day. | No |
| S9 | Low | The router query runs with internet access on. | No |
| S10 | Low | A local app with Screen Recording can read the pairing code and pair from this Mac. | No |
| S11 | Low | The typed code has no PAKE. An active relay can grind the code offline. | Yes, if changed. No change proposed. |
| S12 | Low | Kind 18 and the QR link list every address of the Mac. | No |
| S13 | Low | Unauthenticated peers can hold the admission slots. | No |
| S14 | Low | The Mac can go to idle sleep with no device connected. | No |
| S15 | Info | A paired device has full control of the Mac. | No |
| S16 | Info | Clipboard sync is on by default. | No |
| S17 | Info | Logs hold addresses and device names. | No |

### S1. The remote door listens on every interface (High)

- Where: `RemoteServer.swift:92`, `:99`.
- What an attacker needs: a route to port 7455 on any interface of the Mac. On the home LAN that is every device on the Wi-Fi.
- What they get: the TLS handshake and, while a pairing window is open, the pairing exchange. With a stolen device key, a session.
- Fix: bind the listener to the configured Tailscale address with `requiredLocalEndpoint`. Fail closed when the address is absent. Plan items N1 to N4.

### S2. The home door is open to the LAN and to Bonjour (High)

- Where: `StreamServer.swift:591` to `:613`, `DoorPolicy.swift:75` (`sill-pair/1` always at home), the ask rule in `DoorPolicy.ask`.
- What an attacker needs: a device on the same LAN or in AWDL range that runs Sill.
- What they get: the Mac name on Bonjour. An ask puts a pairing window with the QR code and the code on the Mac's screen, up to three times in 10 minutes. A person who sees the screen can then pair.
- Fix: do not start the home door. Use the `.closed` mode that the code has. Do not advertise. Plan item N5.

### S3. The CLI's plain home door (High)

- Where: `StreamServer.HomeDoorMode.plain`, the CLI without `--pairing` (`SillHostCLI/main.swift`).
- What an attacker needs: any device on the LAN.
- What they get: full keyboard and mouse control of the Mac, with no key and no code.
- Fix: the CLI uses the same Tailscale-only remote door as the app, or the build drops the CLI. Decision D3.

### S4. USB cable pairing with no code (Medium)

- Where: `DoorPolicy.swift:252`, `RemoteAccess.pairOverCable`.
- What an attacker needs: physical access to an unlocked Mac and an iPhone or iPad with Sill.
- What they get: a permanent pairing. A 10-second notice shows on the Mac.
- Fix: removed with the home door (N5).

### S5. Require pairing off (Medium)

- Where: `DoorPolicy.trusts`, `DoorPolicy.atReady` (home door).
- What an attacker needs: you turn Require pairing off. Then any device on the LAN.
- What they get: a session with any key.
- Fix: removed with the home door (N5). The setting has no effect on the remote door.

### S6. Legacy login keychain for a self-signed build (Medium)

Your earlier analysis is correct.

- Where: `IdentityStorePlan.swift:40`, `KeychainIdentityStore.swift:84`, `make-app.sh` (the `--release` path only embeds the profile).
- A build signed with a free personal team has no `keychain-access-groups` entitlement. The plan selects `.legacy`, the file-based login keychain.
- What an attacker needs: a process of your user that runs before the first launch of Sill. It creates the items `me.saffer.sill.remote.host-key`, `recognition-key` and `paired-devices` with an access list that includes Sill.
- What they get: Sill adopts a known Mac key and a trust list with the attacker's device key in it.
- Proposed fix, in order of strength:
  1. Build with an Xcode project and a free personal team. Add Keychain Sharing. Xcode makes a macOS development profile. Then `keychain-access-groups` is real and the data-protection keychain works. This needs a new Xcode project for the host, which is a large change. Decision D1.
  2. Keep the legacy keychain. Add a first-launch check: if any of the three items exists and the local marker file does not, stop and log an error. Do not adopt the items. Show the Mac key fingerprint in the log and in Settings, so that you can compare it with the iPad. This is a speed bump only, because the same process can write the marker file too.
  3. Run a documented one-time reset before the first launch: delete the three items with `security delete-generic-password` and `security delete-key`. `docs/BUILD-AND-VERIFY.md` will have the commands.
- I propose 2 and 3 now, and 1 as an open decision.
- Client side (`iOSClient/DeviceIdentity.swift:106`): the key is `WhenUnlockedThisDeviceOnly`. The Secure Enclave path exists behind the `SillDeviceKeySE` default. I do not change the client.

### S7. Exposure settings in UserDefaults and launch arguments (Medium)

- Where: `Sources/SillMenuBar/HostSettings.swift`, `HostConfig.remoteAccess`, `remotePort`, `internetAccess`.
- What an attacker needs: a process of your user. It runs `defaults write`, or starts `Sill.app` with `-internetAccess 1`.
- What they get: the remote door also admits internet sources. A router port forward is still necessary.
- Fix: remove internet access. Read the bind address from a config file and accept only an address in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`. The same process can edit the file, but it cannot widen the door past your tailnet.

### S8. The update check (Medium)

- Where: `UpdatePolicy.swift:15`, `UpdateChecker.swift`.
- What an attacker needs: control of the upstream repository releases. You told me that you do not trust the upstream developer.
- What they get: a daily request from your Mac with your IP address and Sill version. A notice that asks you to install their newer build.
- Fix: remove the update check and its UI. Plan item B1.

### S9. Router query (Low)

- Where: `RouterAddress.swift:25`, `RemoteAccess.swift:875`.
- It runs only with internet access on. It goes with S7's fix.

### S10. Pairing from this Mac (Low)

- Where: `OriginPolicy.remoteAdmits` admits `loopback`. A connection from the Mac to its own Tailscale address also arrives on the tunnel.
- What an attacker needs: a local app with Screen Recording, at the moment you open the pairing window.
- What they get: it reads the QR code or the code and pairs its own key.
- The ask rule refuses asks from this Mac (`DoorPolicy.isFromThisMac`). The remote door has no such check.
- Fix: the remote door refuses loopback and the Mac's own addresses. Plan item N6.

### S11. Typed code without a PAKE (Low)

- Where: `Pairing.swift:75` to `:136`.
- What an attacker needs: an active relay between the iPad and the Mac during pairing, and the typed path. On Tailscale that needs a node inside your tailnet or control of DNS for the typed name.
- What they get: the device's `proof_D`. The code has about 36.5 bits (10^11 codes). Each guess costs 600,000 PBKDF2 rounds. The attacker must find the code within the 5-minute window to use it.
- Brute force over the network is limited: 5 wrong proofs close the window, the spacing is 1, 2, 4 and 8 s, and one source can try once in 5 s. A restart closes the window.
- Replay: a proof binds both TLS pins. It does not work in another session.
- Two devices at the same time: the first valid proof closes the window (`used`). The second gets `closed`.
- Fix: none. A PAKE changes kind 19 and kind 20. Use the QR path, which uses a 128-bit secret.

### S12. Address lists (Low)

- Where: `AddressList.swift`, `RemoteAccess.addresses()`.
- Kind 18 and the QR link carry the MagicDNS name, the Tailscale addresses, the LAN IPv4 and other VPN addresses. The device saves them.
- Fix: list only the configured Tailscale address. These are data fields, so the contract does not change. Plan item N7.

### S13. Admission slots (Low)

- Where: `Door.swift:55` to `:59`.
- At most 8 connections wait for admission, 2 for each source, 10 s to admission. A source with 5 refusals in 60 s waits 300 s.
- What an attacker needs: four addresses that can reach the door. After N1 that means four nodes in your tailnet.
- What they get: your iPad cannot connect for up to 10 s at a time while they keep the slots full.
- Fix: none proposed. The tailnet limits the attacker.

### S14. Idle sleep (Low, reliability)

- Where: `AppModel.swift:379`. The app holds a user-initiated activity only while a remote device is connected.
- With no device connected, the Mac can go to idle sleep. Then the iPad cannot reach it.
- Fix: document `pmset` settings, or hold an idle-sleep assertion while the remote door listens. Decision D5.

### S15. A paired device has full control (Info)

- Where: `StreamCoordinator.swift:903` (`launchApp` opens any installed app), `:915` (input), menus (`MenuMirror`), window commands, gestures.
- Only an admitted session reaches these. The remote door admits only a paired key while Remote Access is on.
- There are no special key combinations. Input goes through `CGEvent` as a normal keyboard and mouse.
- Revocation: Settings › Devices › Remove updates the trust list and closes that device's sessions (`RemoteAccess.swift:452`). If the keychain write fails, the device stays paired and the pane says so.

### S16. Clipboard sync (Info)

- Where: `HostConfig.swift:91` (`shareClipboard: true`), `HostClipboard.swift`, `ClipboardPolicy.swift`.
- The Mac's copied text goes to each subscribed device. A device's text becomes the Mac's clipboard. Items that password managers mark as concealed do not go.
- Other features that move data: video, thumbnails, app icons, the installed-app list, window titles, menu titles, the cursor shape. No file transfer. No audio.
- Decision D4: keep clipboard sync, or turn it off by default.

### S17. Logging (Info)

- Where: `HostLog.swift`. The file is `~/Library/Logs/Sill/Sill.log`, rotated at 10 MB to one `Sill.1.log` (`HostLog.swift:117`).
- The log holds source addresses, device names and model IDs, and the first characters of key fingerprints. `Sill.app` never logs the pairing code, the QR secret or a key.
- The CLI prints the code and the link on its own standard output (`SillHostCLI/main.swift:168` to `:176`).
- `~/Library` is readable by your user only. No change proposed.

### 4.1 TLS and key pinning

- TLS 1.3 only, minimum and maximum (`RemoteTLS.swift:57`). Cipher suites are the TLS 1.3 defaults of Network.framework. Measured upstream: `0x1302` (AES-256-GCM).
- Both sides must send a certificate (`set_peer_authentication_required`).
- The verify block reads the peer leaf only and compares the SPKI pin. It does not evaluate the chain, so there is no network access during the handshake.
- On a pin mismatch the host refuses in the handshake. The device sees `-9808` or `-9825`.
- The verify block returns false for a key that is not P-256.
- I found no path in `Sill.app` that skips the pin on the remote door. The home door's Require pairing off is a path that skips the trust list. It goes with N5.

### 4.2 Network input parsing

- The header length field is a `UInt32`. Each reader checks it against a cap before it reads (`StreamServer.swift:1110`, `:1373`, `Door.swift:344`). No unbounded allocation.
- `ParameterSets.init(encoded:)` checks every length (`StreamMessage.swift:159`).
- JSON payloads go through `JSONDecoder`. A malformed payload is dropped.
- There is no decompression on the host.
- Parsers that run before authentication: the TLS stack, the SPKI pin of the client certificate, and kind 19 (4 KiB JSON) on a `sill-pair/1` connection while a pairing window is open.

### 4.3 Local attack surface

- No XPC service, no helper tool, no URL scheme in the host `Info.plist`.
- Preferences: `UserDefaults` domain `me.saffer.sill.mac`. See S7.
- Test hooks (`SILL_TEST_*` variables, `-Sill…` arguments) are ignored by `Sill.app` (`DoorPolicy.isTestHost`, `TestHooks.swift`). A few preview arguments still work in the bundle. They do not touch the doors.

## 5. Plan for Phase 3 (approved)

One commit for each item. Each item names the files it changes.

### Network

- N1. Add a run-time config file: `~/Library/Application Support/Sill/tailscale.conf` with one key, `address = 100.x.y.z`. A pure parser accepts only one IPv4 address in `100.64.0.0/10` or one IPv6 address in `fd7a:115c:a1e0::/48`. Commit only `docs/tailscale.conf.example`. New file `Sources/SillHost/TailnetConfig.swift`.
- N2. Bind the remote door to that address (`requiredLocalEndpoint`). `RemoteServer.swift`.
- N3. Fail closed. No address, an invalid address, or an address on no interface: no listener and one clear log line. `RemoteServer.swift`, `RemoteAccess.swift`.
- N4. Retry the bind with backoff (2, 4, 8, … up to 60 s) and on every network change. Rebind when the address comes back after sleep or a Tailscale restart. Never another interface. `RemoteServer.swift`.
- N5. Home door closed in `Sill.app`. No Bonjour, no AWDL, no cable pairing, no ask. `StreamCoordinator.swift` (home mode `.closed`), `AppModel.swift`.
- N6. Tighten OriginPolicy at the remote door: admit only a source in the two Tailscale ranges that arrives on the interface that owns the configured address. Refuse loopback and the Mac's own addresses. `OriginPolicy.swift`, `Door.swift`.
- N7. Kind 18 and the QR link list only the configured address. `RemoteAccess.swift`.
- N8. Remote Access always on in this build. Remove internet access and the router query. `HostConfig.swift`, `RemoteAccess.swift`, `RemoteAccessPane.swift`.

### Personal information

- P1. Move the bundle ID and the signing identity into an untracked `Local.config` that `make-app.sh` reads. Commit `Local.config.example`. Add `Local.config` to `.gitignore`. The host has no Xcode project, so a `Local.xcconfig` does not apply. I leave the iPad project unchanged.
- P2. Add `Scripts/check-personal-info.sh`. It scans tracked files for IP addresses outside the documentation ranges, email addresses and Apple team IDs. You run it on your Mac.
- Bundle ID effects. A new bundle ID gets new Screen Recording and Accessibility grants. It gets a new `UserDefaults` domain. The legacy keychain items have an access list for the old signature, so a new signature makes a new Mac key and you pair again. The iPad does not check the bundle ID. The contract does not change.

### Security fixes

- K1. S6 options 2 and 3.
- K2. S10, part of N6.

### Reliability

- R1. `docs/launchagent.plist.example` with `KeepAlive` and `RunAtLoad`, and placeholders.
- R2. A status file `~/Library/Application Support/Sill/status.json`, written each 10 s: the bound address, the port, the listener state, the number of sessions, the time.
- R3. Sleep, wake, display change, screen lock and a lost client: I will read the handlers in the code and fix only what I find broken. I will report what I cannot verify without a Mac.

### Bloat

- B1. Remove the update check (S8): `UpdateChecker.swift`, `UpdatePolicy.swift`, its menu item and Settings rows, `Tests/checks/update-policy`, `Scripts/sillfeed.py`.
- B2. Remove the release and App Store tools that you do not use: `Scripts/release.sh`, `Scripts/release-ios.sh`, `Scripts/make-dmg.sh`, `Scripts/dmg-layout`, `Packaging/ExportOptions-appstore.plist`, `Packaging/SillRelease.entitlements`, `.github/workflows/release.yml`, `.github/workflows/testflight.yml`.
- B3. Remove `site/` and `design/screenshots/`.
- B4. I keep the home door code, the Bonjour code and the AWDL code. Removal from `StreamServer.swift` and `StreamCoordinator.swift` is a large diff and makes a rebase onto upstream hard. N5 makes them unreachable. Decision D2.

### CI

- C1. `ci.yml` and `release.yml`: manual trigger only (if B2 does not delete `release.yml`).

### Documents and tests

- T1. XCTest target `SillHostTests` with tests for the config parser, the address check and bind decision, and OriginPolicy. It runs with `xcodebuild test -scheme Sill-Package -destination 'platform=macOS'`.
- D-docs. `docs/BUILD-AND-VERIFY.md`, `docs/UPSTREAM.md`, `docs/pf-tailscale-only.conf.example`, and STE versions of `README.md` and `SECURITY.md`.

## 6. Decisions for you (answered)

Your answers: D1, the stronger data protection option. D2, remove the unreachable code. D3, the CLI is Tailscale-only. D4, clipboard on. D5, option 1: hold an idle-sleep assertion while the door listens.

- D1. Keychain: accept options 2 and 3 for now, or do I add an Xcode project for the host to get the data-protection keychain with a free personal team?
- D2. Bloat in the network code: keep the unreachable home door code (small diff, easy rebase), or remove it (smaller attack surface, hard rebase)?
- D3. The CLI (`SillHost`): remove the product, or make it use the same Tailscale-only remote door?
- D4. Clipboard sync: keep it on by default, or off?
- D5. Idle sleep: hold an assertion while the door listens, or only document `pmset`?

## 7. What I could not verify

- That the App Store iPad binary matches `iOSClient/`.
- Any behaviour at run time. I built nothing and ran nothing.
- That `NWListener` with `requiredLocalEndpoint` on a Tailscale `utun` address behaves as on loopback. You must check it with `lsof` on your Mac.
- Screen capture before login after a reboot. With FileVault on, macOS starts no user session until you log in, so a login agent cannot run. I expect no capture until you log in.

## 8. Comments that do not follow STE

I leave comments in code that I do not change. Almost every source file has comments that do not follow ASD-STE100 (long sentences, semicolons, contractions). Section 9 of the final report will list the files that I changed and the files that I did not.

## 9. What changed in Phase 3

`docs/UPSTREAM.md` lists every commit. This section groups them by goal.

### 9.1 Listen only on the Tailscale address

- `TailnetConfig.swift` reads `~/Library/Application Support/Sill/tailscale.conf`. It takes one literal address in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`, and an optional port. It refuses a host name, a zone, a range, `100.100.100.100`, an unknown key, a second value for a key, a symbolic link, a file that another user owns, and a file that the group or other users can write.
- `RemoteServer.swift` binds with `NWParameters.requiredLocalEndpoint` to that address and port. It never binds to a wildcard address. It binds only while an up tunnel interface holds the address (`TailnetBind.owner`).
- Fail closed: without a usable file, the door opens no listener. The log, the menu, the Remote Access pane and `status.json` say why.
- The bind tries again after 2, 4, 8, 16, 32 and then every 60 seconds. A network change, a wake from sleep and a 30-second check make it look again. When the address goes away, the listener stops. When the address comes back, the listener binds again.
- `OriginPolicy.tailnetAdmits` admits only a tunnel arrival from a Tailscale source. Loopback, the LAN, peer-to-peer Wi-Fi and the internet get no byte. Because of the bind, a forged Tailscale source from the LAN cannot complete the TCP handshake: the reply goes into the tunnel.
- Kind 18 and the pairing link carry only the configured address. Before, they carried every LAN, VPN and internet address of the Mac.
- Remote Access is on by default. The switch stays as a way to stop the door. The CLI always runs the door.

Deviation from N6: I did not refuse "the Mac's own addresses" by a separate rule. With the bind on the Tailscale address, a connection from the Mac itself arrives from that same address on `lo0`, which is not a tunnel. So `remoteAdmits` refuses it already. Deviation from 3a: there is no loopback exception for tests. The door binds to the Tailscale address, so loopback cannot reach it.

### 9.2 Removed for the Tailscale-only setup (decision D2)

One commit (`80e6aac`) removes the home door and its parts together. They share types, so smaller commits would not compile one by one. This is a deviation from "one change per commit".

- The home door in `StreamServer.swift`: the plain door, the TLS home door, the listener and its live swap.
- Bonjour: the `_sill._tcp` service, the TXT record (`HostIdentity.txtRecord`) and `NSBonjourServices` in `Info.plist`.
- Direct Wireless (AWDL): `HostConfig.directWireless`, the menu item, the Settings row. A device that asks for it is refused.
- USB cable pairing: `CableLink.swift`, `CableReport.swift`, the IOKit reads in `InterfaceSnapshot.swift`, the cable notice window, `--print-cable`.
- The pairing ask and kind 21: `AskLimits`, `SessionLock.swift`, the "‹device› Wants to Pair" menu item. The door answers an ask or a cancel `closed`, as the remote door did before.
- Require pairing: `RequirePairingValue`, its keychain item, the Devices pane's switch. Every session needs a paired key.
- The internet switch, the address name and the router query: `RouterAddress.swift`, the Internet section of the Remote Access pane, `--internet`.
- `ClientLink.swift` (the home door's route word) and `TestHooks.swift` (the home door's test hooks).
- The checks of removed code: `ask-limits`, `cable-link`, `clientlink`, `door-policy`, `home-records`. `Tests/SillHostTests` covers the new `DoorPolicy`.

### 9.3 Other removals (3e)

- The update check (`UpdateChecker.swift`, `UpdatePolicy.swift`, its check, `Scripts/sillfeed.py`): the only outbound call, to `api.github.com`.
- The app's test hooks and preview renderer (`DebugHooks.swift`): launch arguments that any process could pass.
- The release workflows, `Scripts/release.sh`, `Scripts/release-ios.sh`, `Scripts/make-dmg.sh`, `Scripts/dmg-layout/` and its check, `Packaging/ExportOptions-appstore.plist`, and `Packaging/SillRelease.entitlements`, which held the upstream team ID.
- `site/`, `design/screenshots/`, `design/DMGBackground.svg`, `.github/FUNDING.yml` and `.github/ISSUE_TEMPLATE/`.
- `docs/release-checklist.md`, `docs/app-store-metadata.md`, `docs/BRIEF.md`, `docs/DEVELOPMENT.md` and the 20 plans under `docs/`. They describe upstream work, many of them for removed features, and some hold upstream's home paths.
- `Scripts/pacing/`, which compiled the removed home door.
- `--print-reachability` and `ReachabilityReport`. `--print-tailnet` replaces them.
- The upstream `CLAUDE.md`, 6,126 lines of upstream work log. A short file for this fork replaces it.

### 9.4 Personal information (3b)

- `Packaging/Local.xcconfig` holds `SILL_BUNDLE_ID`, `SILL_TEAM_ID`, `SILL_SIGN_IDENTITY` and `SILL_PROVISION_PROFILE`. Git ignores it. `Packaging/Local.xcconfig.example` has placeholders. `make-app.sh` reads only those four keys, and only values of safe characters, without running the file.
- Deviation from P1: the plan named the file `Local.config`. I used `Local.xcconfig`, the name in your prompt, with the xcconfig syntax. The host has no Xcode project, so `make-app.sh` reads it.
- `Scripts/check-personal-info.sh` scans the tracked files, the staged changes and, with `--history`, every commit. It fails on your own values from `~/.config/sill/private-patterns.txt` and on a tracked local-only file. It lists emails, Tailscale and other IPv4 addresses, MagicDNS names, home paths and team IDs for review.
- Bundle ID effects: a new `SILL_BUNDLE_ID` gives new Screen Recording and Accessibility grants, a new `UserDefaults` domain, a new keychain access group and so a new Mac key. Each device pairs again. The iPad checks only the pinned key, never the bundle ID, so the wire contract does not change.
- Not changed: `iOSClient/Sill.xcodeproj` holds the upstream team ID `9B2KKVM937` and the bundle ID `me.saffer.sill`. Those are upstream's values, not yours, and you asked me not to change the client.
- The upstream identifiers `me.saffer.sill.remote` (the keychain service), `me.saffer.sill.clipboard` (a pasteboard type) and `me.saffer.sill.mac` (the default bundle ID in `Packaging/Info.plist`) stay. They are upstream's public names, and the clipboard type is part of the behaviour that the iPad app sees.

### 9.5 Keychain (decision D1)

- With a provisioning profile at `Packaging/embedded.provisionprofile`, `make-app.sh` makes the entitlements from your values (`com.apple.application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups`). It signs a development build with them too, not only a release. `IdentityStorePlan` then picks the data-protection keychain.
- `AppModel.entitledKeychainAccessGroup` now matches the running bundle ID, not the upstream one.
- Without a profile, the build uses the login keychain, as before. `docs/BUILD-AND-VERIFY.md` tells you how to delete old items before the first launch.
- Open risk: a free personal team's profile expires after a short time. Apple states 7 days for free iOS profiles. An app that embeds an expired profile does not launch. Then the always-on Mac needs a rebuild each week. See section 12.

### 9.6 Reliability (3d)

- `Packaging/LaunchAgent/local.sill.host.plist.example`: runs Sill.app in the user's session (`LimitLoadToSessionType` Aqua), restarts it after a crash, sends standard output to `/dev/null`.
- Logs: `Sill.app` already writes `~/Library/Logs/Sill/Sill.log` and moves it to `Sill.1.log` at 10 MB, so at most about 20 MB. The CLI writes to standard output only.
- `status.json` in `~/Library/Application Support/Sill/`: the listener state, the address, the port, device counts, streaming and the encoder. Written on a change and every 30 seconds, mode 0600. `lsof -nP -iTCP -sTCP:LISTEN` shows the bind.
- Sleep: while the door listens, the host holds `ProcessInfo` activity `.idleSystemSleepDisabled` (D5).
- Wake: the door reads the file again and checks its address at the wake and 5 seconds later.
- Display change, screen lock and a lost client: I changed nothing. The upstream code stops capture when the last device leaves, and evicts a remote client after 8 seconds of silence. I did not trace a display change or a screen lock from end to end.

### 9.7 Tests (3g)

- `Tests/SillHostTests` is an XCTest target in `Package.swift`. It tests the config parser and its file checks, the bind's interface choice, endpoint and backoff, the Tailscale-only origin rule, and the door's admission rules.
- Run: `swift test`, or `xcodebuild test -scheme Sill-Package -destination 'platform=macOS'`.
- The upstream checks under `Tests/checks` that compile changed files were updated: `origin`, `away-quality`, `home-model`.

### 9.8 Wire contract

No commit changes `Sources/StreamProtocol/` or `iOSClient/`. The door keeps TLS 1.3, the pins, the ALPNs, the pairing proofs and every message kind. The host sends `directWireless` as nil in kind 16, which a host without Direct Wireless always did. A device sees no Direct Wireless row.

## 10. What I did not change, and why

- `Sources/StreamProtocol/` and `iOSClient/`: the wire contract and your instruction.
- `PairingWindowAddress.swift` and `AddressList.build`: they still work with the one Tailscale address. `AddressList.build` is now used only by its checks. It can go in a later cleanup.
- `Scripts/sillclient.py`: its default is the removed plain door. It still works with `--tls`.
- The S11 finding (no PAKE): a fix changes the pairing proof, which is part of the wire contract.
- `KeychainIdentityStore.swift`'s logic: only its Require pairing item went.

## 11. What I could not verify

- Any build. The cloud session cannot compile Apple frameworks. I checked the syntax of every changed Swift file with a tree-sitter parser. A second reader looked for compile errors and found one, a duplicate `rename` function, which commit `ce69d7d` fixes. A first build can still show other errors.
- Any behaviour at run time, `requiredLocalEndpoint` on a `utun` address included.
- That the App Store iPad binary matches `iOSClient/`.
- That a free personal team can get a macOS profile with `keychain-access-groups`, and how long it lasts.
- Screen capture with the screen locked, and before login after a restart.
- The scan script on macOS. I ran it on Linux with GNU tools. macOS has BSD `grep` and `sed`.

## 12. Open risks and decisions for you

- D6. The free team's profile expires. Choose: a rebuild each week with the data-protection keychain, or no profile and the login keychain with the manual clean-up before the first launch.
- D7. S11, no PAKE for the typed code. An attacker needs an active relay inside your tailnet during a typed pairing, and must find the code within the window. The risk is low. A fix changes kinds 19 and 20, so it needs a client change. Use the QR code to pair.
- D8. Any device in your tailnet can reach the port. Use Tailscale ACLs to limit it to your iPad.
- D9. Every session now comes through the Tailscale door, so the host counts every device as away. The away quality (Low · Standard by default) always runs. To stream at a higher quality, set it in Settings, Streaming, "Away from home". Or decide whether the host should count a Tailscale session as at home.
- Risk: the first build can fail. `docs/BUILD-AND-VERIFY.md` asks you to note each failure.
- Risk: the upstream history in the fork still holds upstream's names and email. They are not yours.

### 12.1 Your answers (2026-10-23)

- D6: no weekly rebuild. Build without a provisioning profile, so Sill uses the login keychain. Delete the old Sill items before the first launch, as `docs/BUILD-AND-VERIFY.md` says. With D8, a planted trust entry gives an attacker little: the port answers only Tailscale sources that your ACL admits, and a process on the Mac itself cannot reach the door.
- D7: accepted as it is.
- D8: you set Tailscale ACLs.
- D9: the away quality stays Low · Standard.

## 13. Comments that do not follow STE

I wrote the new files and the changed comments in STE: `TailnetConfig.swift`, `TailnetBind.swift`, `StatusFile.swift`, the new tests, the new parts of `RemoteServer.swift`, `RemoteAccess.swift`, `DoorPolicy.swift`, `OriginPolicy.swift` and `Door.swift`, `Scripts/check-personal-info.sh`, the templates and the documents.

The comments that I did not touch do not follow STE. That is true of almost every Swift file under `Sources/`, of `Scripts/make-app.sh` outside its new parts, of `Tests/checks/`, of `Scripts/encoder-check/`, `Scripts/menu-check/` and `Scripts/restore-probe/`, of `design/README.md` and of `Tests/checks/README.md`. In the files that I changed, the old comments around my changes keep their upstream style.
