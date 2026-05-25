import Foundation
import SoulACP

/// Per-thread instrumentation for the cost of `ThreadController.apply(_:)`.
/// Buckets each invocation by `SessionUpdate` kind, accumulating total time,
/// invocation count, and slowest single call. Auto-flushes a snapshot to
/// `~/Library/Logs/Soul-Desktop/acp-protocol.jsonl` (method `apply_timing`)
/// every `flushEveryN` records to keep disk pressure bounded.
///
/// Pulled out of `ThreadController` so the controller doesn't carry the
/// diagnostic plumbing in its public surface. The probe is a plain value
/// type — caller holds it as `@ObservationIgnored` because nothing in the
/// SwiftUI graph needs to react to the counters.
///
/// SOUL-SOUL_DESKTOP-063 diagnostic origin.
struct ApplyTimingProbe {
    private var totalNs: [String: UInt64] = [:]
    private var count: [String: Int] = [:]
    private var slowestNs: [String: UInt64] = [:]
    private var updatesSinceFlush: Int = 0
    private let flushEveryN: Int = 100

    /// Accumulate one `apply(_:)` invocation. Caller passes a context
    /// snapshot (provider / sessionId / items count) so the auto-flush
    /// can write a self-contained log entry without the probe needing a
    /// back-pointer to the controller.
    mutating func record(
        kind: String,
        elapsedNs: UInt64,
        provider: Provider,
        sessionId: String?,
        itemsCount: Int
    ) {
        totalNs[kind, default: 0] &+= elapsedNs
        count[kind, default: 0] += 1
        if elapsedNs > slowestNs[kind, default: 0] {
            slowestNs[kind] = elapsedNs
        }
        updatesSinceFlush += 1
        if updatesSinceFlush >= flushEveryN {
            updatesSinceFlush = 0
            flush(provider: provider, sessionId: sessionId, itemsCount: itemsCount)
        }
    }

    private func flush(provider: Provider, sessionId: String?, itemsCount: Int) {
        var perKind: [String: JSONValue] = [:]
        for (kind, total) in totalNs {
            let c = count[kind] ?? 0
            let s = slowestNs[kind] ?? 0
            perKind[kind] = .object([
                "count": .double(Double(c)),
                "total_ms": .double(Double(total) / 1_000_000.0),
                "avg_ms": .double(c > 0 ? Double(total) / Double(c) / 1_000_000.0 : 0),
                "max_ms": .double(Double(s) / 1_000_000.0),
                "items_at_snapshot": .double(Double(itemsCount)),
            ])
        }
        ACPProtocolLog.record(
            direction: "internal",
            method: "apply_timing",
            params: .object([
                "provider": .string(provider.rawValue),
                "sessionId": sessionId.map(JSONValue.string) ?? .null,
                "items_count": .double(Double(itemsCount)),
                "per_kind": .object(perKind),
            ])
        )
    }
}
