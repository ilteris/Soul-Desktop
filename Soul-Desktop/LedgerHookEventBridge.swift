import Foundation
import SoulLedger

extension LedgerHookEvent {
    var hookDictionary: [String: Any] {
        var event: [String: Any] = ["event": name]
        for (key, value) in fields {
            event[key] = value.hookValue
        }
        return event
    }
}

private extension LedgerHookValue {
    var hookValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .bool(let value): value
        case .double(let value): value
        }
    }
}
