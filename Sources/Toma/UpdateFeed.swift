import Foundation

/// A release newer than the running app, as GitHub describes it.
nonisolated struct Update: Sendable {
    let version: String
    let dmg: URL
    /// Lowercase hex SHA-256 of the DMG, when GitHub publishes one.
    let sha256: String?
    /// The release page: the manual fallback when installing in place is not possible.
    let page: URL
}

/// Everything Toma knows about where releases live and how to read them. Pure: no UI, no network,
/// so the version rules and the parsing are testable on their own.
nonisolated enum UpdateFeed {
    static let latest = URL(string: "https://api.github.com/repos/felipebasurto/toma/releases/latest")!
    static let assetName = "Toma.dmg"

    nonisolated private struct Payload: Decodable {
        let tag_name: String
        let html_url: URL
        let assets: [Asset]

        nonisolated struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
    }

    /// The release described by GitHub's `releases/latest` response, or nil if it is malformed or
    /// carries no `Toma.dmg`. Says nothing about whether it is newer; see `isNewer`.
    static func parse(_ data: Data) -> Update? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let asset = payload.assets.first(where: { $0.name == assetName }) else { return nil }
        let prefix = "sha256:"
        let sha = asset.digest.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)).lowercased() : nil }
        return Update(version: version(fromTag: payload.tag_name), dmg: asset.browser_download_url,
                      sha256: sha, page: payload.html_url)
    }

    /// "v1.3.0" → "1.3.0".
    static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Dotted-number comparison: "1.10" is newer than "1.9", and "1.2" equals "1.2.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// The `TeamIdentifier=` line of `codesign -dvv` output. Nil for ad hoc signatures
    /// (`TeamIdentifier=not set`), which cannot vouch for an update.
    static func teamIdentifier(in codesignOutput: String) -> String? {
        for line in codesignOutput.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "not set" ? nil : value
        }
        return nil
    }
}
