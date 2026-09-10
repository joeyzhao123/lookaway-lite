# LookAwayLite

A ~350-line Swift menu bar app for macOS that reminds you to look away from your screen
(the 20-20-20 rule), and — the actual point — **never interrupts you during a meeting**.

No dependencies, no Xcode project, no frameworks beyond what ships with macOS.

## Install

```sh
./build.sh
cp -R LookAwayLite.app /Applications/
open -a LookAwayLite
```

Requires macOS 14+ and the Command Line Tools (`xcode-select --install`).

## What it does

Every 20 minutes (configurable), every screen dims and a 20-second countdown appears.
Press <kbd>esc</kbd> to skip a break.

The menu bar item shows state at a glance:

| Glyph | Meaning |
|---|---|
| `◔19m` | 19 minutes until the next break |
| `◉18s` | break in progress |
| `✆call` | break held — you're in a meeting |
| `❙❙` | paused |

The menu offers pause/resume, break now, skip, work interval (5–60 min), break length
(20s–5min), separate start and end sounds, a completion card, and a compact mode that reduces the item to a single glyph — useful because a
full macOS menu bar silently drops items that don't fit, especially on notched displays.

## Meeting detection

Breaks are *held*, not skipped: the countdown still hits zero, then refuses to fire and
re-checks every 10 seconds, so the break arrives the moment your meeting ends. A meeting
starting mid-break also dismisses the overlay immediately.

Four independent signals, each toggleable:

| Signal | Default | How |
|---|---|---|
| Mic in use | on | CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`. No permissions. Stays true through a software mute, so it covers a muted Zoom call. |
| Camera in use | on | CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere`. No permissions. |
| Meet/Zoom tab in Chrome | off | AppleScript reads the *active* tab URL of each window. Needs one-time Automation permission. |
| Calendar event in progress | off | EventKit. Needs Calendar permission. |

There's a hard 90-minute cap on holds, so a wedged camera process or a forgotten meeting
tab can't suppress breaks all afternoon.

### Why more than one signal

The mic property is the conventional way to detect an in-use microphone, but
[per Apple's forums](https://developer.apple.com/forums/thread/741026) **Bluetooth
microphones often report as inactive regardless of actual use** — so an audio-only call
taken on AirPods can read as idle. Camera detection has no such bug and covers video calls
on any audio route. The Chrome tab check closes the remaining gap: audio-only, camera off,
on Bluetooth.

Only the active tab of each window counts, and bare product pages (`meet.google.com/`,
`zoom.us/pricing`) are excluded, so a stale background tab won't suppress breaks.

### Calendar caveat

EventKit reads only calendars configured in macOS (System Settings › Internet Accounts).
If `~/Library/Calendars` is empty, this toggle finds nothing regardless of what your
calendar app shows — Notion Calendar and other standalone clients aren't visible to it.

## Launch at login

```sh
cp local.lookawaylite.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.lookawaylite.plist
```

`KeepAlive` is set to restart only on abnormal exit, so **Quit** from the menu stays quit
until the next login.

## Settings

Persisted in `UserDefaults` under `local.lookawaylite`:

```sh
defaults read local.lookawaylite
```

Keys: `workMinutes`, `breakSeconds`, `skipWhenMicActive`, `skipWhenCameraActive`,
`skipDuringChromeCallTab`, `skipDuringCalendarEvents`, `compactStatusItem`, `breakSoundsEnabled`,
`breakStartSoundEnabled`, `breakEndSoundEnabled`, `breakCompletionCardEnabled`.

`LOOKAWAY_TEST_SECONDS=10` shortens the work interval to seconds for testing.

## Verification

Detection was checked empirically rather than assumed — mic and camera detectors were
confirmed to read `false` → `true` → `false` against a live audio capture and Photo Booth
respectively, the URL matcher passes 9 cases, and the hold-then-fire path was exercised
against a real Google Meet call.

## License

MIT
