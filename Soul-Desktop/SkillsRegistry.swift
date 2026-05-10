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
