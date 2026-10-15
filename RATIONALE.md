# Toma: rationale ("decide after you see it")

## Problem

The user wants ⇧⌘4 for video: pick a region, record it, and get an MP4 or a GIF, with nothing else on top. The shape is not obvious for four reasons. (1) ScreenCaptureKit records one display per stream, in display-local top-left points. AppKit draws in global bottom-left points. Retina needs pixel sizes, and H.264 needs even pixel sizes. Getting any of these conversions wrong gives a video that is offset by a few pixels or slightly blurry. (2) Toma's own windows (the selection veil, the recording frame, the result card) must never appear in the video. (3) Screen Recording permission (TCC) only takes effect after a relaunch, and the user must not find that out after dragging a region. (4) "MP4 or GIF" is a choice, and every choice adds UI. The design question is when to ask it so that it costs the user close to nothing. Constraints: macOS 26, Swift 6.2, SwiftPM only, no dependencies, Spanish UI.

## Usage (caller's view)

**The user's flow (the product):**

1. Press **⌥⇧⌘4** anywhere, or click the circle in the menu bar and choose **Grabar zona**. If permission is missing, an alert appears before any overlay: *"Toma necesita permiso para grabar la pantalla."* It has two buttons, **Abrir Ajustes** and **Salir**.
2. The screens dim and the cursor becomes a crosshair, as with ⇧⌘4. Drag a rectangle. A label beside the cursor shows the real output size, `1280 × 720`. The modifiers are the same as ⇧⌘4: Space moves the rectangle, ⇧ locks an axis, ⌥ grows from the center. Esc, a right-click, or a tiny drag cancels.
3. On release, recording starts at once. There is no countdown and no toolbar. A 1-pt hairline sits just outside the region, and the menu bar shows **■ 0:07**.
4. Stop with **⌥⇧⌘4** again, or by clicking **■ 0:07**. These are the same two actions that started the recording.
5. A thumbnail slides in at the bottom right, where screenshot thumbnails appear, and plays the clip in a loop. Under it are two words, **MP4 · GIF**. The format you used last time is highlighted.
   - Click a word: the file is saved in that format.
   - Ignore the card for 5 s, or swipe it away: the file is saved in the highlighted format.
   - Esc or ×: the recording is discarded.
6. The file goes to the same folder as your screenshots (Escritorio by default) with Apple's naming: `Grabación de pantalla 2026-10-15 a las 21.03.12.mp4`.

There are no preferences window, no format setting and no countdown. Audio, trimming and an editor are also left out.

**Internal call sites:**

```swift
// App.swift — the whole wiring
let toma = Toma()
hotkey = Hotkey(.optionShiftCommand4) { toma.toggle() }

// Toma.session() — one capture as one linear story
guard Recording.ensureAccess(), let region = await Overlay.select() else { return }
let recording = try await Recording.start(region)
let frame = Overlay.frame(around: region)
phase = .recording(recording, since: .now)
let clip = try await recording.clip            // after stop() or if the system ended the stream
frame.close(); phase = .reviewing
switch await ResultCard.present(clip, suggesting: Library.preferredFormat) {
case .save(let format): try await Library.save(clip, as: format)
case .discard:          clip.discard()
}

// toggle() while recording
recording.stop()                               // idempotent
```

## Shape

Eight files, one target (`Sources/Toma/`). Default isolation is `MainActor`, and the off-main types are marked `nonisolated`.

| File | Owns | Public surface |
|---|---|---|
| `App.swift` | wiring, the Carbon hotkey | `Hotkey(.optionShiftCommand4) { }` |
| `Toma.swift` | **the only state** (`Phase`), the session story, error presentation | `toggle()`, `phase` (read-only) |
| `Region.swift` | all coordinate knowledge | `ScreenRegion(dragged:on:)`, `sourceRect`, `pixelSize` |
| `Overlay.swift` | selection veil and recording frame | `select() async -> ScreenRegion?`, `frame(around:)` |
| `Recording.swift` | everything about ScreenCaptureKit and TCC | `ensureAccess()`, `start(_:)`, `stop()`, `clip` |
| `ResultCard.swift` | the after-recording card | `present(_:suggesting:) async -> Choice` |
| `Library.swift` | destination, naming, remembered format, GIF policy and encoder | `save(_:as:)`, `preferredFormat` |
| `StatusItem.swift` | menu bar rendering | `render(phase)`, `onPress` |

**Data first.** There are four domain types: `ScreenRegion` (where), `Recording` (live), `Clip` (finished, unsaved), and `Format` (what). Each step of the flow takes one of them and returns the next. You can follow the data from input to output by reading `Toma.session()`.

**Load-bearing decisions:**

- **`ScreenRegion` can only be built in a capturable state.** Its only initializer clamps the rectangle to one display, snaps it to the pixel grid, makes the pixel dimensions even, and rejects slivers. It stores AppKit global coordinates once and computes `sourceRect` and `pixelSize` from them. No second copy exists that could drift. Every Retina, multi-display and odd-size bug has one home (per encode-lessons-in-structure, single source of truth).
- **The format is a property of the save, not of the recording.** The recording always produces one MP4 master: H.264, native pixels, up to 60 fps, sRGB. Saving as MP4 is an atomic move, with no re-encode and no quality loss. GIF is derived from the master. This is why the choice can come *after* recording. It also means one recording path, one temp file and no format branching in capture.
- **One way to choose a format.** The card is the only format UI. `preferredFormat` has a single writer, `Library.save` (it is the last format actually saved), so no setting is needed: a GIF-heavy user does nothing and gets GIFs (per single-owner state).
- **Self-exclusion is done by the capture filter.** `SCContentFilter(display:excludingApplications:[Toma])` keeps the veil, the frame and the card out of the video. Window flags are not used for this, because `sharingType = .none` is not reliable with ScreenCaptureKit on recent macOS. The frame is also drawn *outside* the region as a second safeguard.
- **`Recording.clip` resolves however the recording ends.** It resolves after `stop()`, after the system's own stop control, or when a display is unplugged, and in each case it returns the finalized file recorded so far. `stop()` is idempotent and non-blocking (per make-operations-idempotent). The controller needs no separate stop signal, which leaves one path rather than two.
- **Permission is checked before the overlay appears**, so the user never draws a region that cannot be recorded.
- **Crash halfway:** masters live in `$TMPDIR/Toma`, and `removeStaleMasters()` runs at launch. A crash can lose a recording, but it never leaves junk where the user can see it.

**Interface depth.** `Recording` hides SCShareableContent lookup, display matching, self-exclusion, stream configuration, the recording output, delegate-to-async bridging, system-initiated stops and TCC. It does this behind four members, and it exposes no ScreenCaptureKit type. `Library.save` hides the destination folder lookup, Apple-style naming, collision suffixes, the remembered format and a GIF encoder (frame pacing, downscaling, dedup of identical frames, loop metadata) behind one call. `Overlay.select()` is a single `await` that returns a region or `nil`. The widest surface is `Toma.Phase`, and only StatusItem reads it.

**What it does not do:** audio, window-mode capture, countdown, trimming, an editor, clipboard copy, custom shortcuts, quality settings, cloud upload, or a Dock icon. The GIF policy (20 fps, longest edge 960 px, infinite loop) is fixed on purpose. 20 fps gives an exact 5/100 s GIF delay, whereas 30 fps would judder.

**Typecheck:** `swiftc -typecheck -default-isolation MainActor -swift-version 6 -target arm64-apple-macos26.0 -sdk $(xcrun --show-sdk-path) Sources/Toma/*.swift` passes with no warnings, and `swift build` links. `build.sh` wraps the binary into `Toma.app` (with an LSUIElement Info.plist and `NSScreenCaptureUsageDescription`) and signs it ad hoc.

## Synthesis decision

Two runners (Opus, Sonnet; a Fable runner was stopped for cost). They converged on the same core shape: one state owner with one verb, a validated region type, SCRecordingOutput writing one MP4 master, the app excluding itself through the capture filter, and the format chosen *after* recording on a screenshot-style thumbnail. That agreement is strong evidence for the shape.

**Base: candidate 1 (Opus).** It had the deeper modules (`Recording.clip` resolves however the stream ends, and `stop()` is idempotent), ⇧⌘4's exact modifiers, a GIF policy argued from first principles (20 fps = an exact 5/100 s delay), and a single save path where MP4 is a move.

**Grafts from candidate 2 (Sonnet):**
- Drag-out of the thumbnail (an `NSFilePromiseProvider` that writes in the suggested format). Candidate 1 had listed it as an open question.
- Visible GIF progress, folded in as a `Toma.Phase.saving(Double)` that the menu bar renders as a ring, so state keeps one owner.

**Rejected from candidate 2:** saving the MP4 before asking. It writes a file the user may not want and turns GIF into "a second file next to the first".

**Resolved open questions during implementation:** SCRecordingOutput honours `sourceRect` at native Retina pixels on macOS 26 (verified: 802×502 output for a 401×251 pt region, pixel-identical to `screencapture -R`). Signing with the Apple Development identity keeps the TCC grant across rebuilds. The hotkey pressed while the card is up saves in the suggested format and opens a new selection. If GIF encoding fails, the master is saved as MP4 instead of being lost.

## Revision 1.1

Requested: choose the folder, more export options, lighter files, better GIFs, faster, more polish.

- **Choices live in the menu, not a window.** `Preferences` is the single owner of folder, GIF size and sound. The menu writes them; Library and Recording read them. The suggested format stays a by-product of saving.
- **Formats: MP4 (H.264) · HEVC (MOV) · GIF, plus copy.** The master stays a high-bitrate SCRecordingOutput MP4. MP4 and HEVC are quality-targeted re-encodes (`AVVideoQualityKey` 0.6 / 0.55), measured at 5.5× and 10× lighter with text unchanged to the eye. All audio tracks are mixed into one AAC track. `Library.prepare` starts encoding the suggested format while the card is up, so the common choice saves in about 0 s. A mismatched or discarded prepare is cancelled and cleaned up.
- **A custom GIF encoder** (`GIF.swift`) replaces ImageIO:
  - a sequential `Differ` that compares against what the viewer sees, with noise tolerance and edge-aware redraw;
  - parallel per-frame encoding: changed-rectangle frames with transparency, exact palettes for ≤ 255 colours, dominant colours mapped without dither, median cut plus ¾ Floyd–Steinberg for the rest.
  - Results: about 2× faster than ImageIO, mean error 1.3/255 against the source, and no ImageIO speckles. Sizes are similar to ImageIO on worst-case content (full-frame scrolling over a gradient) and smaller on typical UI. "Ligero" (640 px, 15 fps) is the size lever.
- **Recording got cheaper.** The placeholder stream output was removed. A 4 s capture at 60 fps uses 0.13 s of CPU.
- **Bug found and fixed:** the result card never slid on-screen, because `animator().setFrameOrigin` does not animate on NSWindow. `setFrame(_:display:)` is used now. Windows no longer use `sharingType = .none`: the capture filter already excludes Toma, and that flag also hid the card from screenshots and from Zoom.

## Tradeoffs accepted

- We accept one extra step after every recording (the card) in exchange for never asking anything before recording, and for choosing the format after seeing the clip. Doing nothing still saves the file, so the extra step costs no action.
- We accept H.264 over HEVC (larger files) in exchange for MP4s that play everywhere: Slack, the web, Windows, old iPhones.
- We accept that a region cannot span two displays in exchange for one stream, one clock and no compositing. The drag is clamped to the display where it began.
- We accept GIF numbers that the user cannot change in exchange for a default that is always right and no settings UI.
- We accept the Carbon `RegisterEventHotKey` API (old, but supported) in exchange for a global shortcut that needs no Accessibility permission and does not leak the keystroke.
- We accept that a crash mid-recording loses that recording in exchange for not writing partial files where the user can see them.
- We accept a non-configurable shortcut, ⌥⇧⌘4. Leaving out a settings window is deliberate, not an oversight.

## Alternatives considered

- **Choose the format before recording (a persisted menu setting, or a modifier when releasing the drag).** It is simpler to build: there is no card, and the file appears the moment you stop. But it moves the choice to the moment the user knows least, and it hides it in a menu or a modifier nobody discovers. GIF users would need a settings trip, and switching per clip would be awkward. Its interface is shallower for the user but more expensive to use, so it lost.
- **A capture pipeline with SCStreamOutput and AVAssetWriter, plus a live GIF encoder per format.** This gives full control over frames, but it puts frame handling, timing and two encoders on the capture path, and the recording would branch by format. SCRecordingOutput plus one derived export hides more behind less. It loses unless SCRecordingOutput proves unable to honour `sourceRect` and scale (see risks).
- **A floating control bar like ⇧⌘5 (record and stop buttons, format and options next to the region).** It is familiar, but it is a second interface for what the hotkey and the menu bar already do, and it is exactly the clutter the request rules out. It was rejected on the "solo haga eso" principle.
- **Separate modules for each stage (Selector → Capturer → Encoder → Saver → Notifier).** This is temporal decomposition: the region and file representations would cross four boundaries. Grouping by knowledge (coordinates, ScreenCaptureKit, the library) gives fewer and deeper modules.

## Open questions and risks

- Does **SCRecordingOutput** honour `sourceRect` together with an explicit `width`/`height` at native Retina pixels on macOS 26? This needs a first spike. If it does not, Recording switches internally to AVAssetWriter, and its public surface stays the same.
- Does an **ad-hoc signature** keep the Screen Recording grant across rebuilds? TCC matches the code signature. If every `build.sh` run re-prompts, should we sign with a stable self-signed identity?
- Is **⌥⇧⌘4** free on the user's machine? Some apps (for example CleanShot) take nearby chords. If registration fails, should Toma say so in the menu or stay quiet?
- Should the card support **drag-out** (drag the thumbnail into Slack or Mail, like screenshots)? It is the most-loved part of the screenshot thumbnail. It needs an `NSFilePromiseProvider` that runs `Library.save` in the highlighted format. It is cut for now; the user should decide.
- Should a hotkey press **while the card is up** save with the suggested format and start a new selection at once? Right now that press is ignored for up to 5 s.
- **Long GIFs** (a 2-minute GIF at 960 px is huge). Should we warn, cap the length, or lower the fps above N seconds? Or is "the user chose GIF" enough?
- Should the recording include **cursor clicks** (`showsMouseClicks`, macOS 15+)? It is cheap and helps tutorials, but it is one more decision.

## Next implementation step

Implement `ScreenRegion(dragged:on:)` and `Recording.start/stop/clip` as a spike that records a hard-coded rectangle on a Retina display to MP4. This proves `sourceRect`, pixel sizing and self-exclusion with SCRecordingOutput before any UI is built on top.
