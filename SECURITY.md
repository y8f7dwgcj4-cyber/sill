# Security of the hardened host

## What this does

This document tells you what the hardened host protects, where its limits are, and what to do when you find a security problem.

## Why it exists

The host lets a paired iPad see and control the Mac. A flaw in the host can give another person that control. You run this fork alone, so you are the person who must act on a problem.

## How it works

The host has these layers, from the outside in:

1. Tailscale admits only devices in your tailnet to the Mac's Tailscale address.
2. The host binds its only listener to that address. It never binds to a wildcard address.
3. The door refuses a connection that does not come from a Tailscale source on a tunnel interface, before TLS starts.
4. TLS 1.3 with pinned P-256 keys admits only a paired key for a session.
5. An unpaired key can only pair, and only while you have a pairing window open on the Mac.
6. The optional pf anchor in `Packaging/pf/sill.anchor.example` drops the port on every other interface.

## Concepts

**Paired device.** A paired device is an iPad or iPhone whose key is on the Mac's trust list. It can see and control the Mac while the door listens. Remove it in Sill's Settings, Devices, if you lose it.

**Trust list.** The trust list is the list of paired keys. Sill keeps it in the keychain with the Mac's own key, never in a preference file.

**Pairing window.** The pairing window is a 5-minute period, opened by you on the Mac, in which one device can pair. Five wrong codes close it.

## How it runs today

- The door listens only on the address in `~/Library/Application Support/Sill/tailscale.conf`.
- The host makes no outbound connection to the developer's servers. The update check is gone.
- The log has no pairing code, no key and no clipboard text.
- `HARDENING-REPORT.md` lists each finding, its severity and its fix.

## Known traps

- Any device in your tailnet can reach the port and try to pair while a pairing window is open. Keep a pairing window open only while you pair.
- Tailscale's own access controls decide who is in your tailnet. Use Tailscale ACLs to limit which devices can reach the Mac.
- Without a provisioning profile, Sill keeps its key in the login keychain. Another app of your user can create that item before the first launch.
- A paired device has full control of the Mac's screen, keyboard and mouse.

## What to do when you find a problem

1. Remove each paired device in Sill's Settings, Devices.
2. Turn off Remote Access, or quit Sill.
3. Write down the log lines from `~/Library/Logs/Sill/Sill.log`.
4. If the problem is also in upstream Sill, decide whether to tell the upstream developer. Do not put your own addresses or names in that report.

## What changed recently

The fork removed the home door, Bonjour, Direct Wireless, the USB cable pairing, the internet switch and the update check.

## What is not done yet

Nobody has tested the hardened host against an attacker on a real network.
