# AGENTS.md

Guide for AI agents and contributors working on this repo.

## Purpose

`macosdragfix` is a single Swift binary that restores window dragging on the
macOS 27 beta, where title-bar drag is broken for apps with a custom chrome
(Electron/Chromium). It works around the system bug by moving windows through
the Accessibility API, skipping the broken WindowServer gesture.

## Layout

- `macosdragfix.swift` — the only source file (no external dependencies).
- `macosdragfix` — the compiled binary.
- `it.m6i.macosdragfix.plist` — LaunchAgent template (start at login).
- `README.md` — user documentation.

The command is on PATH as `~/bin/macosdragfix` (a symlink to the binary here).

## Build and run

    swiftc -O -o macosdragfix macosdragfix.swift \
      -framework ApplicationServices -framework CoreGraphics
    codesign --force --sign - --identifier it.m6i.macosdragfix macosdragfix
    ./macosdragfix --xoffset 10 --yoffset 8

There is no automated test suite. Verification is manual (see below).

## How it works (invariants to keep)

- Event tap `cgSessionEventTap` on leftMouseDown/Dragged/Up. It exists only with
  the Accessibility permission.
- Coordinates: `CGEvent.location` and `AXPosition`/`AXSize` share an origin at
  the top-left of the main display. The Y axis stays as-is.
- mouseDown is always delivered: a click must reach the app. Only
  leftMouseDragged is consumed, and only while a move is actually in progress.
- `threshold` (4 px): "moving" starts only after real movement, so a plain click
  moves nothing.
- A down is ignored when the hit element or one of its parents (up to the
  window) has an interactive role (`interactiveRoles`: AXButton, AXTextField,
  AXTab, ...), so a label inside a button, tab, or field stays with the app.
- `~/.macosdragfix.yml` (created if missing) holds per-app exclusion rectangles
  and optional `band` / `xoffset` / `yoffset`. App name is the top-level key.
  It is re-read when the file's modification time changes.
- Chrome tabs are not a fixed rectangle. On mouse down the top band is scanned
  for tab and button frames, and only those frames stay with Chrome. The empty
  gap is the drag region and follows the open tabs.
- Active zone, relative to the window: x in [xoffset, width-xoffset],
  y in [yoffset, band]. The top edge and the corners (resize zones) stay out.
- Movement uses `AXUIElementSetAttributeValue(win, kAXPositionAttribute)`.
  That is the key: it bypasses the broken gesture, so it works on Electron apps.

## Parameters

CLI `--xoffset/-x`, `--yoffset/-y`, `--band/-b`, `--mod/-m`; environment
fallback `MACOSDRAGFIX_{XOFFSET,YOFFSET,BAND,MOD}`. CLI wins over the
environment. An empty `--mod` means no modifier is required.

## Manual check after a change

1. Rebuild. A rebuild changes the cdhash: Accessibility may need to be granted
   again (TCC binds the permission to the unsigned binary's identity).
2. Launch from a terminal and check the status line on stderr for the parameters.
3. Drag test on an Electron app (Claude, Cursor) and a native app (Safari):
   both must move when dragging the top band.
4. Regression test: a click on a button or tab in the top band must still work
   (the tool steps aside).
5. To inspect WindowServer behavior:
   `log show --last 60s --predicate 'process == "WindowServer"' --style compact | grep "drag trait"`

## Gotchas

- Ad-hoc signature only. `swiftc` leaves a linker signature, which TCC ignores:
  always re-sign with the `codesign` line above. A rebuild still changes the
  cdhash, so Accessibility must be granted again. Remove the old row with the
  minus button. Toggling the existing switch keeps the previous binary.
- Electron AX trees are sparse: the `interactiveRoles` filter can miss some
  controls. Prefer adjusting `band`/`xoffset` over widening what gets hijacked.
- Consuming mouseDown would break clicks everywhere. Leave it delivered.
- Keep dependencies at zero (system frameworks only) and keep everything in one
  file: this is a workaround, and it should stay simple and rebuildable anywhere.

## Context

Real target: a MacBook Pro M5 Max (Mac17,7) on macOS 27.x beta. The upstream bug
is tracked in Apple Developer Forums 834488 and Chromium 564169077. Once Apple
ships a fixed build, this tool is no longer needed.
