import AppKit
import CryptoKit

/// Keeps Toma current without a framework: asks GitHub for the latest release about once a day,
/// and installs it in place when the user says so (menu: "Update to Toma x.y.z…").
///
/// Trust chain, because this replaces the running app: the DMG must match the SHA-256 GitHub
/// publishes for it, the app inside must pass `codesign --verify --deep --strict`, carry the same
/// Developer ID team as the running app, and be strictly newer. If any step fails, or the app's
/// folder is not writable (Toma run from a disk image, say), the release page opens instead.
/// Nothing is replaced until the new copy is fully staged beside the old one.
final class Updater {
    enum State {
        case idle
        case available(Update)
        case installing
    }

    private(set) var state: State = .idle
    let currentVersion: String

    private var checking = false
    private static let lastCheckKey = "ultimaBusquedaActualizaciones"
    private static let interval: TimeInterval = 24 * 3600

    /// A plain `swift run` has no bundle version; then there is nothing to compare, so no updates.
    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Checks shortly after launch and then whenever a day has passed. Toma can run for weeks
    /// without a restart, so this wakes hourly instead of checking once at launch.
    func startChecking() {
        guard !currentVersion.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
                if Date.now.timeIntervalSince(last) >= Self.interval { await check() }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Asks GitHub for the latest release and updates `state`. Returns false if the lookup failed.
    @discardableResult
    func check() async -> Bool {
        guard !currentVersion.isEmpty, !checking else { return false }
        if case .installing = state { return true }
        checking = true
        defer { checking = false }

        var request = URLRequest(url: UpdateFeed.latest, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Toma/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let update = UpdateFeed.parse(data) else { return false }
            UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)
            state = UpdateFeed.isNewer(update.version, than: currentVersion) ? .available(update) : .idle
            return true
        } catch {
            return false
        }
    }

    /// Downloads, verifies and swaps in the available update, then relaunches. Quits Toma on
    /// success; on any failure it falls back to the release page and stays available.
    func install() async {
        guard case .available(let update) = state else { return }
        state = .installing
        let app = Bundle.main.bundleURL
        do {
            let staged = try await Self.stage(update, over: app, current: currentVersion)
            try Self.swapAndRelaunch(staged, over: app)
            NSApp.terminate(nil)
        } catch {
            state = .available(update)
            NSWorkspace.shared.open(update.page)
        }
    }

    // MARK: staging

    nonisolated private struct Staged: Sendable {
        let app: URL
        let scratch: URL
    }

    nonisolated private enum Failure: Error {
        case notWritable, download, checksum, tool, signature, notNewer
    }

    /// Downloads the DMG and leaves the verified new app next to the old one, ready to swap.
    nonisolated private static func stage(_ update: Update, over app: URL, current: String) async throws -> Staged {
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else { throw Failure.notWritable }

        let scratch = fm.temporaryDirectory.appending(path: "Toma-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staged = folder.appending(path: ".Toma-update.app", directoryHint: .isDirectory)
        let mount = scratch.appending(path: "mount", directoryHint: .isDirectory)
        var mounted = false
        do {
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            let (download, response) = try await URLSession.shared.download(from: update.dmg)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            let dmg = scratch.appending(path: "Toma.dmg")
            try fm.moveItem(at: download, to: dmg)

            if let expected = update.sha256 {
                let digest = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
                guard digest == expected else { throw Failure.checksum }
            }

            try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                               "-mountpoint", mount.path, dmg.path])
            mounted = true
            try? fm.removeItem(at: staged)
            try await run("/usr/bin/ditto", [mount.appending(path: "Toma.app").path, staged.path])
            _ = try? await run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            mounted = false

            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            let team = UpdateFeed.teamIdentifier(in: try await run("/usr/bin/codesign", ["-dvv", staged.path]))
            let ours = UpdateFeed.teamIdentifier(in: try await run("/usr/bin/codesign", ["-dvv", app.path]))
            guard let ours, team == ours else { throw Failure.signature }

            let version = Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            guard UpdateFeed.isNewer(version, than: current) else { throw Failure.notNewer }
            return Staged(app: staged, scratch: scratch)
        } catch {
            if mounted { _ = try? await run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
            try? fm.removeItem(at: staged)
            try? fm.removeItem(at: scratch)
            throw error
        }
    }

    /// Runs a tool to completion and returns its combined output; throws on a non-zero exit.
    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.tool }
            return String(decoding: output, as: UTF8.self)
        }.value
    }

    // MARK: swap

    /// A detached shell outlives Toma: it waits for this process to exit, swaps the bundle (undoing
    /// the swap if the second move fails), and opens the result. A running app cannot replace itself.
    private static func swapAndRelaunch(_ staged: Staged, over app: URL) throws {
        let script = """
        pid=$1; app=$2; new=$3; scratch=$4
        n=0
        while kill -0 "$pid" 2>/dev/null; do
          n=$((n + 1))
          if [ "$n" -gt 100 ]; then rm -rf "$new" "$scratch"; exit 1; fi
          sleep 0.2
        done
        old="$app.old"
        rm -rf "$old"
        if mv "$app" "$old"; then
          if mv "$new" "$app"; then rm -rf "$old"; else mv "$old" "$app"; fi
        fi
        rm -rf "$new" "$scratch"
        open "$app"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             app.path, staged.app.path, staged.scratch.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
