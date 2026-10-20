# Build and verify the hardened Sill host

## What this does

This document tells you how to build the hardened Sill host on your Mac. It also tells you how to verify that the host listens only on your Tailscale address. Do the steps in the order that they have here.

## Why it exists

The hardening was done in a cloud session that cannot build or run macOS code. Thus nobody has built or run this branch yet. You are the first person to build it, and these steps are the only test of it on a real Mac.

## How it works

You do eight steps:

1. Review the build steps and the dependencies.
2. Make your local configuration files.
3. Build and sign Sill.app with a free personal team.
4. Give the macOS permissions that the host needs, and only those.
5. Verify the listener with `lsof`.
6. Verify from another device on your home Wi-Fi that the port does not answer.
7. Pair the App Store iPad app over Tailscale and test a full session.
8. Restart the Mac and verify that the host starts again.

### Step 1: Review the build steps and the dependencies

Do this before the first build. The repository is untrusted until you read what runs.

1. Open `Package.swift`. Make sure that `Package(` has no `dependencies:` list of its own. The `dependencies:` of each target name only local targets.
2. Open `Scripts/make-app.sh`. Read it from top to bottom. It runs these tools: `swift build`, `xcrun vtool`, `qlmanage`, `xcrun actool`, `PlistBuddy`, `plutil`, `security cms`, `codesign`, `ditto`, `pkill` and `lsregister`.
3. Look at `git log e4737d2..hardening`. Read each commit. `docs/UPSTREAM.md` lists what each commit does.
4. Do not build the iOS project in `iOSClient/`. You use the App Store app.

### Step 2: Make your local configuration files

You make two files. Git ignores both of them.

1. Get your Mac's Tailscale address. Run `tailscale ip -4`.
2. Make the folder: `mkdir -p ~/Library/Application\ Support/Sill`.
3. Copy `docs/tailscale.conf.example` to `~/Library/Application Support/Sill/tailscale.conf`.
4. In that file, replace `100.x.y.z` with your Tailscale address.
5. Run `chmod 600 ~/Library/Application\ Support/Sill/tailscale.conf`.
6. Copy `Packaging/Local.xcconfig.example` to `Packaging/Local.xcconfig`.
7. In `Packaging/Local.xcconfig`, set `SILL_BUNDLE_ID` and `SILL_TEAM_ID` to your own values.
8. Put your private values in `~/.config/sill/private-patterns.txt`, one on each line. `Scripts/check-personal-info.sh` looks for them.
9. Run `Scripts/check-personal-info.sh` before each push.

### Step 3: Build and sign with a free personal team

1. In Xcode, open Settings, then Accounts. Add your Apple Account. Xcode makes an Apple Development certificate for your personal team.
2. If you want the data-protection keychain, get a macOS development provisioning profile:
   1. In Xcode, make a new macOS App project. Set its bundle identifier to your `SILL_BUNDLE_ID`.
   2. Set its team to your personal team.
   3. Add the Keychain Sharing capability.
   4. Build the project one time. Xcode makes the profile.
   5. Find the profile in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
   6. Copy it to `Packaging/embedded.provisionprofile`.
3. Run `Scripts/make-app.sh`.
4. Read the last lines of the output. The line `identity keychain:` tells you which keychain Sill uses.
5. If the output names the login keychain, read "Known traps" below before the first launch.
6. Run `Scripts/make-app.sh --install` to copy Sill.app to `/Applications`.

### Step 4: Give the permissions that the host needs

Open Sill.app from `/Applications`. Then open Sill's Settings, and select Permissions.

Give these permissions:

- **Screen Recording.** The host needs it to capture the windows that you pick.
- **Accessibility.** The host needs it to send clicks, scrolls and keys from the iPad.

Give this permission only if you want clipboard sharing:

- **Paste from Other Apps** (macOS 15.4 and later). Without it, Sill does not read your clipboard.

Do not give any other permission. Sill does not need Input Monitoring, Full Disk Access, Camera or Microphone. If macOS asks for Local Network access, you can refuse it. The door does not use the local network.

### Step 5: Verify the listener with lsof

1. Run `lsof -nP -iTCP -sTCP:LISTEN | grep -i sill`.
2. Make sure that each line shows your Tailscale address, for example `100.x.y.z:7455 (LISTEN)`.
3. Make sure that no line shows `*:7455`, `0.0.0.0`, `[::]` or a LAN address.
4. Make sure that no Sill line shows a second port. The home door and Bonjour are gone.
5. Run `cat ~/Library/Application\ Support/Sill/status.json`. Make sure that `listener` is `listening`.
6. Run `dns-sd -B _sill._tcp` for 10 seconds. Make sure that no line shows your Mac.

### Step 6: Verify from another device on your home Wi-Fi

Use a device on your home Wi-Fi that does not use Tailscale.

1. Get the Mac's LAN address: `ipconfig getifaddr en0`.
2. On the other device, run `nc -vz -w 3 <LAN address> 7455`.
3. Make sure that the connection fails.
4. If you have the pf anchor, also test it. `Packaging/pf/sill.anchor.example` tells you how.

### Step 7: Pair the iPad over Tailscale and test a full session

1. On the iPad, turn on Tailscale. Make sure that it shows your Mac.
2. On the Mac, open the Sill menu and select "Pair iPhone or iPad…".
3. On the iPad, open Sill and tap "Add a Mac…". Scan the QR code.
4. Make sure that the iPad connects. The Mac's menu shows the iPad "through Tailscale".
5. Pick a window. Click, scroll and type on it from the iPad.
6. Disconnect, then connect again from the iPad's saved Mac.
7. In Settings, open Devices. Remove the iPad. Make sure that the session stops.
8. Pair the iPad again.

If you type the code instead of a scan, type the Tailscale address that the pairing window shows.

### Step 8: Restart the Mac and verify that the host starts again

1. Choose one way to start Sill at login. Do not use both.
   - Sill's Settings, General, Launch at Login.
   - The LaunchAgent in `Packaging/LaunchAgent/local.sill.host.plist.example`. It also restarts Sill after a crash.
2. Restart the Mac. Log in.
3. Wait for Tailscale to connect.
4. Do step 5 again.
5. Connect from the iPad.
6. Let the Mac go to sleep, then wake it. Do step 5 again.

## Concepts

**Tailscale address.** Tailscale gives each device in your tailnet an IPv4 address in 100.64.0.0/10. It also gives an IPv6 address in fd7a:115c:a1e0::/48. Only devices that your Tailscale account admits can send packets to it. In this system, the host listens on that one address and on no other address.

**Door.** The door is the one TLS listener of the host. It accepts a paired device for a session, and an unpaired device only while a pairing window is open. In this system, the door is the only way into the host.

**TLS pinning.** Each side keeps the key of the other side from the pairing. A connection with another key fails before any Sill message. In this system, the Mac and the iPad pin each other's P-256 key.

**Pairing window.** The pairing window is a 5-minute period, opened by you on the Mac, in which one device can pair. It shows a QR code and a 12-digit code. Five wrong codes close it.

**PBKDF2.** PBKDF2 is a slow key derivation function. It makes each guess of a typed code cost time. In this system, the 12-digit code goes through 600,000 rounds of PBKDF2-SHA256.

**Data-protection keychain.** The data-protection keychain stores items under a keychain access group. Only an app with that group in its signed entitlements can read or create the items. In this system, it keeps the Mac's key and the paired devices safe from other apps.

**Bonjour.** Bonjour announces services on the local network with multicast DNS. The upstream host announced itself with Bonjour. This host does not use Bonjour.

## How it runs today

- The host listens only on the address in `~/Library/Application Support/Sill/tailscale.conf`.
- Without a usable file, the host opens no listener and says why in the log and the menu.
- If the address is not on an up tunnel interface, the host waits. It tries again after 2, 4, 8, 16, 32 and then every 60 seconds.
- A network change, a wake from sleep and a 30-second check make the host look at the address again.
- The host keeps the Mac out of idle sleep while it listens. The display can sleep.
- The log is `~/Library/Logs/Sill/Sill.log`. At 10 MB it moves to `Sill.1.log`.
- `~/Library/Application Support/Sill/status.json` shows the host's health. The host writes it every 30 seconds.

## Known traps

- **FileVault and a restart.** With FileVault on, the Mac waits at the login window after a restart. No user session exists, so no LaunchAgent runs and screen capture cannot start. Sill listens only after you log in at the Mac.
- **The locked screen.** Sill was not tested with the screen locked. Screen capture can show the lock screen, or stop. Test it on your Mac.
- **A closed laptop lid.** A laptop sleeps when you close its lid, unless it has an external display and power. The sleep hold does not stop that.
- **The free team's profile.** A development profile from a free personal team expires after a short time. Apple states 7 days for free iOS profiles. An app that embeds an expired profile does not launch. `make-app.sh` refuses an expired profile, and you must build again.
- **The login keychain fallback.** Without a profile, Sill keeps its key in the login keychain. Another app of your user can create that item first. Before the first launch, delete old items: `security delete-generic-password -s me.saffer.sill.remote` until it says that it found none. Then also remove the key "Sill Remote Access" in Keychain Access.
- **A new bundle ID.** A new `SILL_BUNDLE_ID` makes Sill new to macOS. You give Screen Recording and Accessibility again, Sill's settings start empty, and each device pairs again.
- **The away quality.** Every session comes through Tailscale, so the host uses the away quality, Low · Standard by default. For a better picture, set the quality in Settings, Streaming, "Away from home".
- **Two copies.** Launch at Login and the LaunchAgent together start two copies. The second copy finds the port in use and waits for ever.
- **The pf anchor and utunN.** Tailscale's interface name can change after a restart. A pf anchor with an old name blocks the Sill port everywhere.

## What changed recently

`docs/UPSTREAM.md` lists each hardening commit. `HARDENING-REPORT.md` tells you why each change was made.

## What is not done yet

- Nobody has built or run this branch on a Mac.
- Nobody has tested the App Store iPad app against this host.
- The steps above are the first test. Write down each step that fails, and its log lines.
