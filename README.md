# MenuCloak

Turn the unused left side of the macOS menu bar into a calm, persistent focus surface.

Hides the **app menus in the macOS menu bar** behind a black overlay. The Apple menu
() stays visible and clickable; everything on the right — status items, Control
Center, clock — stays visible. On a notched MacBook the black strip merges with the
notch. `MENUCLOAK_LEFT` env tunes where the cover starts (default 46pt; 0 = cover the
Apple menu too).

Move the mouse into the covered area and the menus reveal themselves; move away and
they re-cover after 0.6s. Open menus keep it revealed.

The cloak stores and displays its own focus text. Open MenuCloak to edit it directly;
the text updates immediately, stays left-aligned in the usable side of the menu bar,
keeps clear of the camera notch, and truncates only when it cannot fit. On the first
launch after upgrading from the earlier One Thing-powered version, MenuCloak imports
the existing One Thing text once. It never reads One Thing again after that migration.

## How it works

A borderless, click-through black `NSWindow` at status-window level (25) — one level
above the menu bar backdrop (24) — spanning from the left screen edge to the leftmost
visible status item. Width and menu bar height are re-read from the window server every
0.3s, so it adapts when status items appear/disappear or the frontmost app changes.
No Accessibility / Screen Recording permissions needed.

The window lives in its own private CGS space (`CGSSpaceCreate` +
`CGSSpaceSetAbsoluteLevel`, the Übersicht/Pock recipe) pinned above the managed
desktops. Desktop-switch slide animations composite the desktops *below* it, so the
cover physically cannot blink during switches. Private SkyLight API — verified present
on macOS 26; if it ever vanishes, the app falls back to a plain `canJoinAllSpaces`
window (cover works, switch animations may briefly overlay it).

Same overlay family as [MacTools](https://github.com/ggbond268/MacTools)' notch mask;
unlike [TopNotch](https://topnotch.app/), which repaints the wallpaper (all-or-nothing —
it can't leave the right side visible).

## Install

Download the latest `MenuCloak.zip` from [GitHub Releases](https://github.com/dans-huang/MenuCloak/releases),
unzip it, and move the app to `/Applications`. The current community build is ad-hoc
signed rather than Apple-notarized, so macOS may require right-clicking the app and
choosing **Open** the first time.

To build from source instead, install the Xcode Command Line Tools and run:

```bash
git clone https://github.com/dans-huang/MenuCloak.git
cd MenuCloak
./build.sh          # builds MenuCloak.app
open MenuCloak.app
```

The installed app lives at `/Applications/MenuCloak.app`. Open it from Applications
or Spotlight to edit the focus text or use the on/off switch. Closing the control window leaves the app
waiting quietly in the background and removes its Dock icon; opening the app again
brings the switch back. The setting is remembered across restarts. Login startup uses
the `--background` flag so no window or Dock icon appears automatically.

`MenuCloak --selftest` runs the geometry checks.

To install it in `/Applications` and start it at login:

```bash
./install-launchagent.sh
```

## Raycast

The companion extension lets you set the focus text, toggle MenuCloak, and open its
settings from Raycast. Until the Store submission is accepted, install it for local
development with:

```bash
cd raycast-extension
npm install
npm run dev
```

Quit / toggle: open the app, or use its menu bar icon (◧). Note: if a menu bar manager
(e.g. Ice) auto-hides new items, the icon lands in its hidden section — or just
`pkill MenuCloak`.

## Behavior details

- **Black by default.** The cover holds through desktop/Space switches — transient
  window-server gaps during switch animations (measured ≤0.4s) never uncover it;
  the cover snaps back instantly (no fade) the moment a switch lands.
- Real fullscreen: cover yields ~1s after the menu bar is confirmed gone,
  re-covers within ~0.2s of leaving fullscreen.
- `MENUCLOAK_SPACE_LEVEL` env overrides the private space's absolute level
  (default 100) if a macOS update reshuffles space levels.

## Known limits (ponytail ceilings)

- Primary display only. Upgrade path: one overlay per `NSScreen`.
- Keyboard-opened menus reveal with up to 0.5s delay.
- The overlay uses private macOS window-server APIs. They can change in future macOS
  releases; MenuCloak falls back to a normal all-Spaces window if they are unavailable.

## License

[MIT](LICENSE)
