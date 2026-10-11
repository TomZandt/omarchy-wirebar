# Credits

Wirebar is an unofficial community plugin for the Omarchy shell. It is not
affiliated with, endorsed by, or connected to the WireGuard project or Omarchy.

Its feature set was shaped by studying these MIT-licensed Omarchy WireGuard
widgets. The code here is a fresh implementation, but the ideas are theirs and
deserve credit:

- **glafeara/omarchy-wireguard** ("Omawire") — Copyright (c) 2026 glafeara.
  Name-on-import with the 15-character interface rule, never connecting on
  import, exclusive switching, connected-first ordering, drop notifications,
  click-to-copy details, ping through the tunnel, rename and QR export.
- **VirtualDataPro/omarchy-wireguard** — Copyright (c) 2026 VirtualDataPro.
  The 60-second traffic graph, address/DNS/MTU edit form, and refusing configs
  that use hooks.
- **codemonkey76/omarchy-wireguard** — Copyright (c) 2026 Shane Poppleton.
  The handshake-based health idea (not used here: it needs a root helper) and
  the observation that wg-quick runs hooks as root.
- **studylamp/omarchy-wireguard** — Copyright (c) 2026 Brandon Staggs.
  The unprivileged, NetworkManager-only approach.
- **tushar-chauhan/omarchy-wireguard** — Copyright (c) 2026 Tushar Chauhan.

"WireGuard" is a registered trademark of Jason A. Donenfeld.
