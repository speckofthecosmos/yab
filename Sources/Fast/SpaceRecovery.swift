import Foundation

/// A damaged index must not hide every healthy row beside it. Recovery only
/// runs when the index is missing or cannot decode, never over a valid list.
/// Unknown sign-in ownership stays isolated rather than borrowing another
/// space's cookies. The untouched damaged index is kept before any repair.
enum SpaceRecovery {
    static func read(at file: URL, excluding: Set<UUID> = []) -> [Space]? {
        let manager = FileManager.default
        let data: Data?
        do { data = try Data(contentsOf: file) }
        catch {
            // An unreadable existing file is not evidence of a missing index.
            guard !manager.fileExists(atPath: file.path) else { return nil }
            data = nil
        }
        if let data, let saved = decode(data) { return saved }

        var recovered: [Space] = []
        if let data, let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for row in rows {
                guard let bytes = try? JSONSerialization.data(withJSONObject: row) else { continue }
                if let space = try? JSONDecoder().decode(Space.self, from: bytes) {
                    recovered.append(space)
                    continue
                }
                // A malformed look or a new optional field must not discard
                // the space's identity, name and known sign-in ownership,
                // nor its privacy.
                let core = row.filter { ["id", "name", "icon", "ownSignIns", "origin", "brought", "signedInAs", "signInWith", "privacy"].contains($0.key) }
                if let bytes = try? JSONSerialization.data(withJSONObject: core),
                   let space = try? JSONDecoder().decode(Space.self, from: bytes) { recovered.append(space) }
            }
        }
        var known = Set<UUID>()
        recovered = recovered.filter { !excluding.contains($0.id) && known.insert($0.id).inserted }
        let folder = file.deletingLastPathComponent()
        let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for row in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = row.lastPathComponent
            let id: UUID?
            if name == "session.json" { id = Space.firstID }
            else if name.hasPrefix("session-"), name.hasSuffix(".json") {
                id = UUID(uuidString: String(name.dropFirst(8).dropLast(5)))
            } else { id = nil }
            guard let id, !excluding.contains(id), !known.contains(id),
                  let bytes = try? Data(contentsOf: row),
                  let shape = try? JSONDecoder().decode(Session.Shape.self, from: bytes),
                  shape.tabs.contains(where: { URL(string: $0.url).map(Session.writes) == true }) else { continue }
            known.insert(id)
            recovered.append(Space(id: id, name: id == Space.firstID ? "Personal" : "Recovered Space " + String(id.uuidString.suffix(6)),
                                   icon: id == Space.firstID ? "🏠" : "📁", ownSignIns: id != Space.firstID))
        }
        guard !recovered.isEmpty else {
            // Still preserve an index that cannot be reconstructed before
            // the ordinary empty-profile fallback can be saved over it.
            if data != nil { _ = preserveInvalid(at: file) }
            return nil
        }
        guard preserveInvalid(at: file), let bytes = try? JSONEncoder().encode(recovered),
              (try? bytes.write(to: file, options: .atomic)) != nil else { return recovered }
        return recovered
    }

    /// Before writing a list, keep any undecodable original under a unique
    /// name. If that copy fails, callers must leave the original alone.
    static func preserveInvalid(at file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return true }
        guard let data = try? Data(contentsOf: file) else { return false }
        guard decode(data) == nil else { return true }
        let aside = file.deletingLastPathComponent().appendingPathComponent("spaces.unreadable-\(UUID().uuidString).json")
        do { try data.write(to: aside, options: .atomic); return true }
        catch { return false }
    }

    private static func decode(_ data: Data) -> [Space]? {
        guard let spaces = try? JSONDecoder().decode([Space].self, from: data),
              Set(spaces.map(\.id)).count == spaces.count else { return nil }
        return spaces
    }
}
