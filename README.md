<h1 align="center">
  <img src="https://raw.githubusercontent.com/felipebasurto/toma/main/docs/assets/toma-hero.svg" alt="Toma: ⇧⌘4, but for video. Record a region of your Mac screen. MP4, HEVC or GIF." width="100%">
</h1>

<div align="center">

**⇧⌘4, but for video.**
Record a region of your Mac screen and save it as MP4, HEVC or GIF. Nothing else.

[![Version](https://img.shields.io/github/v/release/felipebasurto/toma?label=version&color=2383E2)](https://github.com/felipebasurto/toma/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15.3%2B-37352F)](https://github.com/felipebasurto/toma/releases/latest)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138)](https://swift.org)
[![License](https://img.shields.io/github/license/felipebasurto/toma?label=license&color=787774)](LICENSE)

[Web](https://toma.felipebasurto.com) ·
[Download](https://github.com/felipebasurto/toma/releases/latest/download/Toma.dmg) ·
[Architecture](docs/arquitectura.md) ·
[Changelog](CHANGELOG.md)

</div>

Toma lives in the menu bar. You press a shortcut, draw a rectangle, and it records. There is
no settings window, no account and no editor. It records a region of your screen and saves it well.

## Install

1. Download **[Toma.dmg](https://github.com/felipebasurto/toma/releases/latest/download/Toma.dmg)** and drag Toma to Applications.
2. Open it. Toma is signed and notarized by Apple, so it opens without warnings.
3. Grant the **Screen Recording** permission, then reopen Toma.

Requires macOS 15.3 or later (Sequoia 15.3 through the current release). It is universal (Apple silicon and Intel) and the download is about 1 MB. The interface is in English and Spanish, following your system language. Toma checks GitHub for new versions once a day and updates itself from the menu (**Update to Toma…**).

## Usage

<p align="center">
  <img src="docs/assets/tarjeta.png" alt="The Toma thumbnail after recording: the looping clip, its duration, and the MP4, HEVC and GIF formats, with a copy button." width="380">
</p>

| | |
|---|---|
| <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>4</kbd> | Start: drag a region. Recording begins as soon as you let go. |
| <kbd>Space</kbd> while dragging | Move the region. |
| <kbd>⇧</kbd> while dragging | Lock an axis. |
| <kbd>⌥</kbd> while dragging | Grow from the centre. |
| <kbd>Esc</kbd> | Cancel the selection. |
| <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>4</kbd> again, or **■ 0:07** in the bar | Stop recording. |

When it ends, a thumbnail appears at the bottom right, like screenshots do:

- **Click it**: the clip opens big, with sound and a scrubber, so you can check it before keeping it. **Discard** (⌘⌫), **Copy** (⌘C) or **MP4 · HEVC · GIF** (Return saves the usual one). The 6 s countdown waits while it is open; Esc takes you back to the thumbnail.
- **MP4 · HEVC · GIF**: press one to save in that format.
- **Copy**: puts the file on the clipboard, ready to paste into Slack, Mail or WhatsApp.
- **Drag**: drop the thumbnail into any app or folder.
- **Do nothing**: after 6 s it saves in the last format you used.
- **×**: discards the recording.

If you press the shortcut while the thumbnail is on screen, Toma saves the recording and starts another.

## Formats

| | What for | 10 s of editor and UI, 1280 × 720 | Saving takes |
|---|---|---|---|
| **MP4** | H.264, works everywhere | 0.81 MB | instant |
| **HEVC** | Smaller, ideal on Apple devices and modern browsers | 0.64 MB | instant (large areas: ~0.5 s per second) |
| **GIF** | Animation without a player, for READMEs, chats and docs | 3.5 MB (sharp) | ~0.4 s |

Toma encodes while it records: the Mac's hardware encoders write the MP4 and the HEVC as the
frames arrive, so when you stop they are already finished. It adapts to your Mac: on large areas,
or when the video engine falls behind (an older chip, a video call), it records only the MP4 live
and makes the HEVC and GIF when you save, and if needed it records a steady 30 fps rather than a
choppy 60. Areas larger than 4096 px are recorded at 4096, the most the H.264 hardware encoder takes. One compression pass instead of two,
tuned for quality rather than a fixed size: text stays sharp, and a still screen barely weighs
anything. Colours are kept exactly as they were on screen (sRGB), so the video looks the same in
QuickTime, Chrome, Slack or a GIF.

The GIF uses a custom encoder built for screens. Each frame only stores what changed, and interface
colours stay exact. Gradients are smoothed out without banding. If GIF is what you usually pick,
it starts encoding while you look at the thumbnail.

## Options

In the menu bar, each one shows its current value:

- **Save to**: a folder of your choice, or the same one screenshots use (default).
- **GIF size**: *Sharp* (full resolution, 20 fps) or *Light* (640 px, 15 fps).
- **Sound**: no sound, the Mac's sound, or the Mac's sound and your microphone.
- **Confirm Area Before Recording** (off by default): after you drag a region, Toma shows a still of exactly what will be recorded, outlines it in red on screen, shows where the file will be saved (you can change it there), and asks **Record**, **Redraw** or **Cancel**. Nothing is recorded until you press Record.

Both options, the folder and the confirmation, are also in the welcome window that opens the first time (and whenever you open Toma from Applications).
- **Open at login**.

## Privacy

Everything happens on your Mac. Toma does not connect to the internet, has no analytics and does not
store anything outside the folder you choose. Clipboard copies are deleted after a day. Toma's own
windows never appear in its recordings.

## Build from source

You need Xcode 26 (Swift 6.2). There are no dependencies.

```bash
git clone https://github.com/felipebasurto/toma.git
cd toma
./build.sh        # → Toma.app
./build.sh dmg    # → Toma.app and Toma.dmg
```

If you have a development certificate, `build.sh` signs with it, so the Screen Recording permission
survives rebuilds. With a Developer ID certificate and a notarytool profile, `./build.sh dmg` also
notarizes and staples the disk image.

## How it's built

About 2,500 lines of Swift in a single module, organised by what each part knows:

| File | What it knows |
|---|---|
| `Toma.swift` | The state (a state machine with one verb: `toggle()`) and the history of a recording. |
| `Region.swift` | Coordinates: a region can only exist if it can be recorded exactly as drawn. |
| `Recording.swift` | ScreenCaptureKit, permissions, and encoding while recording. |
| `Library.swift` | Folders, names, formats and saving. |
| `GIF.swift` | The GIF encoder. |
| `Overlay.swift`, `ResultCard.swift`, `StatusItem.swift` | The interface. |

The reasoning behind each decision is in [docs/arquitectura.md](docs/arquitectura.md).

## License

[MIT](LICENSE). Made by [Felipe Basurto](https://felipebasurto.com).
