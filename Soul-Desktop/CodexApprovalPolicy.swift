import Foundation
import SoulACP

enum CodexApprovalPolicy {
    static func responseResult(params: JSONValue?, permissionMode: PermissionMode) -> JSONValue {
        let value = decision(params: params, permissionMode: permissionMode) ?? .string("decline")
        return .object(["decision": value])
    }

    static func decision(params: JSONValue?, permissionMode: PermissionMode) -> JSONValue? {
        let command = params?["command"]?.stringValue ?? ""
        let action = commandActionName(params: params)

        switch permissionMode {
        case .fullAccess:
            return preferredAllowDecision(params: params) ?? .string("accept")
        case .autoReview:
            if PermissionMode.isReadOnlyTool(action) || PermissionMode.isReadOnlyTool(command) {
                return preferredAllowDecision(params: params) ?? .string("accept")
            }
            return .string("cancel")
        case .defaultAsk:
            return .string("cancel")
        }
    }

    static func preferredAllowDecision(params: JSONValue?) -> JSONValue? {
        guard case .array(let decisions)? = params?["availableDecisions"] else { return nil }
        if let amended = decisions.first(where: { decision in
            if case .object(let obj) = decision {
                return obj["acceptWithExecpolicyAmendment"] != nil
                    || obj["applyNetworkPolicyAmendment"] != nil
            }
            return false
        }) {
            return amended
        }
        if decisions.contains(where: { if case .string("accept") = $0 { return true }; return false }) {
            return .string("accept")
        }
        return decisions.first
    }

    static func commandActionName(params: JSONValue?) -> String {
        guard case .array(let actions)? = params?["commandActions"] else { return "" }
        return actions.compactMap { action -> String? in
            guard case .object(let obj) = action else { return nil }
            return obj["type"]?.stringValue ?? obj["command"]?.stringValue
        }.joined(separator: " ")
    }
}
