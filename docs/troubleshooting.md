# QuickShare-Mac Troubleshooting

## Phone doesn't see the Mac
1. Both devices must be on the **same Wi-Fi / LAN**. Guest networks and client isolation block discovery.
2. macOS: **System Settings → Privacy & Security → Local Network** — QuickShare-Mac must be allowed. Toggle off/on if it was denied.
3. Menu bar: **Receive Mode: ON** (auto-off may have kicked in — check Preferences).
4. Some Android skins need **Quick Share → Phone visibility → Everyone** or contacts mode.

## Phone sees the Mac but connect fails
- Confirm the **4-digit PIN** matches on both screens.
- Keep both screens awake; doze can drop the TLS-less TCP session.
- VPNs / firewalls on the Mac can block the inbound port. Allow `QuickShare-Mac` in **Firewall** settings.

## Transfer stalls or is slow
- Large single files stream in 512 KB encrypted chunks — progress resumes after the phone accepts.
- Folders are zipped with `ditto` before sending; the staging zip is deleted after delivery.
- Disk-full on the Mac rejects with `notEnoughSpace` before writing.

## Files land in the wrong folder
- Menu bar → **Preferences…** → Download folder. Bookmarks persist across relaunches.

## Share from Finder
QuickShare registers the `quickshare://send?handoff=` URL. The bundled contractor flow:
1. Select files in Finder → right-click → Services / Quick Action **Send via QuickShare** (Automator action writing the handoff JSON to `$TMPDIR` and opening the URL).
2. The Send window opens with the files prefilled.

A native Finder Share appex is tracked as future work; the handoff path above is the supported route.

## Still stuck
Run `./build.sh --test` (protocol self-test incl. full loopback handshake) and include the output in a bug report.
