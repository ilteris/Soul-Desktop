import Foundation
import os.signpost
import os.log

/// Shared OSSignposter for Soul-Desktop's diagnostic signposts. Use this to
/// trace session-load and first-layout cost in Instruments → Points of
/// Interest. Zero behavior change; intervals only emit when an Instruments
/// recording is attached, otherwise they're effectively free.
///
/// Usage:
///
///     let state = SoulSignposts.beginInterval("loadSession", id: sid)
///     defer { SoulSignposts.endInterval("loadSession", state: state) }
///
/// Or with a closure:
///
///     return SoulSignposts.interval("readHooks", id: sid) {
///         actuallyReadHooksOffDisk(...)
///     }
///
/// Lives in SoulCore (Foundation + os only) so the packageable ledger/runtime
/// readers keep their signposts after the SOUL-360 modularization.
public enum SoulSignposts {
    public static let log = OSLog(subsystem: "com.soul.desktop", category: .pointsOfInterest)
    public static let signposter = OSSignposter(logHandle: log)

    @discardableResult
    public static func interval<T>(_ name: StaticString, id: String? = nil, _ body: () throws -> T) rethrows -> T {
        let sid = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: sid, "\(id ?? "")")
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    public static func beginInterval(_ name: StaticString, id: String? = nil) -> OSSignpostIntervalState {
        let sid = signposter.makeSignpostID()
        return signposter.beginInterval(name, id: sid, "\(id ?? "")")
    }

    public static func endInterval(_ name: StaticString, state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    public static func event(_ name: StaticString, _ message: String = "") {
        signposter.emitEvent(name, "\(message)")
        // File companion for the Flash.* namespace (canvas-blank-on-send
        // diagnostics). Enable with:
        //   defaults write com.test.Soul-Desktop.dev soul.canvas.trace -bool true
        // Then tail ~/tmp/soul-canvas-trace.log while reproducing the bug.
        // Gated on UserDefaults + name-prefix so unrelated signposts
        // (HooksReader, MarkdownView, etc.) stay out of the log.
        let nameStr = "\(name)"
        guard nameStr.hasPrefix("Flash."),
              UserDefaults.standard.bool(forKey: "soul.canvas.trace") else { return }
        flashTraceWrite("\(nameStr) \(message)")
    }

    private static let flashTracePath = NSString(string: "~/tmp/soul-canvas-trace.log").expandingTildeInPath
    private static let flashTraceQueue = DispatchQueue(label: "soul.canvas.trace.file")

    private static func flashTraceWrite(_ line: String) {
        flashTraceQueue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let row = "\(ts) \(line)\n"
            let dir = (flashTracePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard let data = row.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: flashTracePath),
               let h = FileHandle(forWritingAtPath: flashTracePath) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: flashTracePath))
            }
        }
    }
}
