import AppKit

/// The whole product as one state machine with one verb.
///
/// `toggle()` is the only input (hotkey and menu-bar click both call it). `phase` is the only
/// state, owned here and nowhere else; StatusItem renders it, nothing else writes it.
/// A session is one linear async story — select, record, review, save — so the order of
/// events is readable top to bottom in `session()` instead of scattered across callbacks.
final class Toma {
    enum Phase {
        case idle
        /// Permission check, overlay up, or stream starting. Input is ignored: the overlay
        /// owns Esc/mouse, and a second press must not start a second session.
        case busy
        /// The stream is live. `since` drives the elapsed-time readout in the menu bar.
        case recording(Recording, since: ContinuousClock.Instant)
        /// The result card is on screen; it resolves itself (button, drag or timeout).
        case reviewing(ResultCard)
        /// The chosen file is being written; 0…1.
        case saving(Double)
    }

    private(set) var phase: Phase = .idle {
        didSet { statusItem.render(phase) }
    }
    private let statusItem: StatusItem
    /// The hotkey was pressed while the card was up: save it and go straight to a new selection.
    private var againAfterSaving = false

    init() {
        statusItem = StatusItem()
        statusItem.onPress = { [unowned self] in toggle() }
        statusItem.render(phase)
    }

    /// idle → start a session; recording → stop it; card up → keep it and start another.
    /// Idempotent per phase: pressing twice while recording stops once (Recording.stop is idempotent).
    func toggle() {
        switch phase {
        case .idle:
            phase = .busy
            Task {
                await session()
                phase = .idle
                if againAfterSaving {
                    againAfterSaving = false
                    toggle()
                }
            }
        case .recording(let recording, _):
            recording.stop()
        case .reviewing(let card):
            againAfterSaving = true
            card.commit()
        case .busy, .saving:
            break
        }
    }

    /// One capture, start to finish. Every exit path returns to `.idle` (set by `toggle`).
    private func session() async {
        guard Recording.ensureAccess() else { return }
        guard let region = await Overlay.select() else { return }    // Esc / tiny drag = nothing happened

        let recording: Recording
        do { recording = try await Recording.start(region) } catch { return present(error) }
        let frame = Overlay.frame(around: region)
        phase = .recording(recording, since: .now)

        // Resolves after stop() *or* if the system/display ended the stream.
        let clip: Clip
        do { clip = try await recording.clip } catch { frame.close(); return present(error) }
        frame.close()

        let suggested = Library.preferredFormat
        Library.prepare(clip, as: suggested)                     // likely choice encodes while the card is up
        let card = ResultCard(clip, suggesting: suggested)
        phase = .reviewing(card)
        let choice = await card.choice()

        phase = .saving(0)
        let progress: @Sendable (Double) -> Void = { value in
            Task { @MainActor [weak self] in
                if case .saving = self?.phase { self?.phase = .saving(value) }
            }
        }
        do {
            switch choice {
            case .discard: Library.discard(clip)
            case .delivered: break
            case .save(let format): try await Library.save(clip, as: format, progress: progress)
            case .copy(let format):
                try await Library.copy(clip, as: format, progress: progress)
                statusItem.flash()
            }
        } catch {
            // Never lose a recording: if an export fails, the master still is a valid MP4.
            if (try? await Library.save(clip, as: .mp4)) != nil { return }
            present(error)
        }
    }

    /// The single place errors become UI: one Spanish NSAlert, one sentence, one button.
    private func present(_ error: any Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = (error as? TomaError)?.message ?? "No se pudo grabar."
        alert.runModal()
    }
}

/// Every failure the user can see. Messages are final Spanish copy, short, no jargon.
nonisolated enum TomaError: Error, Sendable {
    case permissionDenied
    case displayUnavailable
    case streamFailed(underlying: String)
    case exportFailed(underlying: String)

    var message: String {
        switch self {
        case .permissionDenied:   "Toma necesita permiso para grabar la pantalla."
        case .displayUnavailable: "La pantalla ya no está disponible."
        case .streamFailed:       "La grabación se interrumpió."
        case .exportFailed:       "No se pudo guardar la grabación."
        }
    }
}
