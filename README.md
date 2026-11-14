# Dobi for iPhone — Controller 1.1

This app bundles the actual HTML, CSS and JavaScript from Dobi Controller v1.1 for Windows. The stylesheet is byte-for-byte identical. A WKWebView renders the existing screens, and a native Network.framework bridge replaces the Python HTTP server. No PC, cloud account, token or internet service is required to control the lamp.

## Install and connect

Download `Dobi-unsigned-IPA` from the latest successful GitHub Actions run, unzip it, then sign/install the IPA using your sideloading tool. Enter the bulb's local IPv4 address in Connection settings. Allow Local Network access when iOS asks. The iPhone and bulb must be on the same reachable Wi-Fi network and Yeelight LAN control must be enabled (TCP 55443).

## Included from the Windows controller

Power, brightness, color temperature, color palette, immediate temperature/color mode switching, four white presets, traditional gesture controls, color wheel and saturation, color flow, favorites, recommended scenes, lamp turn-off timer, power-on default, name/room/IP settings, and once/daily/custom schedules. Settings and favorites persist locally on the iPhone; they are not automatically imported from a PC installation.

## Scheduling difference on iOS

Clock schedules run only while the app is active and the phone is awake. iOS suspends background apps, so this is not a reliable background scheduler. Occurrences missed by over 90 seconds are marked as missed instead of unexpectedly toggling the bulb on reopening. The separate Turn-off delay is sent to the lamp's own timer and continues independently of the app after the lamp accepts it. Repeated schedules with the phone locked require an always-on automation host or supported bulb/cloud scheduling.

Scenes retain the Windows version's approximate local presets; they are not claimed to reproduce Xiaomi's proprietary presets exactly. Xiaomi account sharing and firmware updates remain in Xiaomi Home.

## Build and validation

GitHub Actions builds on macOS with XcodeGen and produces an unsigned device IPA. Run `node tests/native.test.cjs` for the adapter tests. Actual lamp operation and iPhone permission prompts require testing on the installed device.
