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
/// SOUL-SOUL_DESKTOP-* (P1 beachball investigation): wired around the
/// suspect load-path entry points so the next reproduction is diagnosable
/// in Instruments instead of guess-driven.
enum SoulSignposts {
    static let log = OSLog(subsystem: "com.soul.desktop", category: .pointsOfInterest)
    static let signposter = OSSignposter(logHandle: log)

    @discardableResult
    static func interval<T>(_ name: StaticString, id: String? = nil, _ body: () throws -> T) rethrows -> T {
        let sid = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: sid, "\(id ?? "")")
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    static func beginInterval(_ name: StaticString, id: String? = nil) -> OSSignpostIntervalState {
        let sid = signposter.makeSignpostID()
        return signposter.beginInterval(name, id: sid, "\(id ?? "")")
    }

    static func endInterval(_ name: StaticString, state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString, _ message: String = "") {
        signposter.emitEvent(name, "\(message)")
    }
}
