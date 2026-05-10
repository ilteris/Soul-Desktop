import Foundation

struct SoulProject: Identifiable, Hashable {
    var id: String                 // project key, e.g. "soul", "bifrost"
    var name: String
    var path: String               // expanded absolute path
    var pillar: String?
    var tier: Int?
    var status: String?
    var primaryHost: String?
}

struct SoulSession: Identifiable, Hashable {
    var id: String                 // session_id
    var project: String
    var timestamp: Date
    var intent: String?
    var summary: String?
    var source: String?            // "claude" | "gemini" | "pi-native"
    var status: String?
}

enum SoulRegistry {
    static var soulPath: String { NSHomeDirectory() + "/dotfiles/soul" }
    static var registryPath: String { NSHomeDirectory() + "/soul_registry" }

    // MARK: - Projects

    static func projects() -> [SoulProject] {
        let url = URL(fileURLWithPath: "\(soulPath)/config/PROJECTS.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = json["projects"] as? [String: [String: Any]]
        else { return [] }

        let mapped = dict.map { (key, val) in
            SoulProject(
                id: key,
                name: val["name"] as? String ?? key,
                path: expand(val["path"] as? String ?? ""),
                pillar: val["pillar"] as? String,
                tier: val["tier"] as? Int,
                status: val["status"] as? String,
                primaryHost: val["primary_host"] as? String
            )
        }

        // Sort by recent activity: mtime of the sessions dir wins, then project path mtime.
        // Falls back alphabetic when both are missing (fresh project, no sessions yet).
        return mapped.sorted { lhs, rhs in
            let la = lastActivity(for: lhs)
            let ra = lastActivity(for: rhs)
            if la != ra { return la > ra }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func lastActivity(for p: SoulProject) -> Date {
        let sessionsDir = "\(registryPath)/sessions/\(p.id)"
        if let m = (try? FileManager.default.attributesOfItem(atPath: sessionsDir)[.modificationDate]) as? Date {
            return m
        }
        if !p.path.isEmpty,
           let m = (try? FileManager.default.attributesOfItem(atPath: p.path)[.modificationDate]) as? Date {
            return m
        }
        return Date.distantPast
    }

    static func activeProjects() -> [SoulProject] {
        projects().filter { ($0.status ?? "active") == "active" }
    }

    // MARK: - Sessions

    static func sessions(forProject key: String, limit: Int = 50) -> [SoulSession] {
        let dir = "\(registryPath)/sessions/\(key)"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        let files = entries.filter { $0.hasSuffix(".json") }
        let parsed: [SoulSession] = files.compactMap { name in
            let path = "\(dir)/\(name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            let id = obj["session_id"] as? String ?? name.replacingOccurrences(of: ".json", with: "")
            let ts = parseTimestamp(obj["timestamp"] as? String) ?? mtime(path)
            return SoulSession(
                id: id,
                project: key,
                timestamp: ts,
                intent: stringOrNil(obj["intent"]),
                summary: stringOrNil(obj["summary"]),
                source: obj["source"] as? String,
                status: obj["status"] as? String
            )
        }
        // Only resumable sessions: id must be a real UUID. Non-UUID rows are
        // legacy/Pi-native ledgers that ACP agents never accept on session/load,
        // and the read-only history fallback also keys on UUIDs.
        let resumable = parsed.filter { UUID(uuidString: $0.id) != nil }

        var deduped: [String: SoulSession] = [:]
        for s in resumable {
            if let existing = deduped[s.id], existing.timestamp >= s.timestamp { continue }
            deduped[s.id] = s
        }
        return deduped.values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - helpers

    private static func expand(_ p: String) -> String {
        guard p.hasPrefix("~") else { return p }
        return NSString(string: p).expandingTildeInPath
    }

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        let f3 = DateFormatter()
        f3.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f3.locale = Locale(identifier: "en_US_POSIX")
        f3.timeZone = TimeZone(identifier: "UTC")
        return f3.date(from: s)
    }

    private static func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    }

    private static func stringOrNil(_ v: Any?) -> String? {
        guard let s = v as? String, s != "None", !s.isEmpty else { return nil }
        return s
    }
}
