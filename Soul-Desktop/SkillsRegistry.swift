import Foundation

enum SkillsRegistry {
    static func builtInCommands() -> [SlashCommand] {
        let fm = FileManager.default
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/skills")
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        let commands: [SlashCommand] = entries.compactMap { name in
            let skillPath = "\(dir)/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: skillPath, isDirectory: &isDir), isDir.boolValue else { return nil }

            let manifest = "\(skillPath)/SKILL.md"
            let description = parseFrontmatterDescription(at: manifest)
            return SlashCommand(name: name, description: description, inputHint: nil)
        }
        return commands.sorted { $0.name < $1.name }
    }

    /// Returns the SKILL.md body (everything past the closing `---` of the
    /// frontmatter) for a given command name. Used by the composer to expand
    /// `/pulse` and friends into provider-agnostic instructions before they
    /// ship. Returns nil if the skill doesn't exist or has no body.
    static func instructions(forCommand name: String) -> String? {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/skills/\(name)/SKILL.md")
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\n")
        // Walk past the opening `---`, then capture everything until next `---`.
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var inFront = true
        var body: [String] = []
        for line in lines.dropFirst() {
            if inFront {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    inFront = false
                }
                continue
            }
            body.append(line)
        }
        let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func parseFrontmatterDescription(at path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if let range = trimmed.range(of: "description:"), range.lowerBound == trimmed.startIndex {
                let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let stripped = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return stripped.isEmpty ? nil : stripped
            }
        }
        return nil
    }
}
