public enum SoulAuthorityEnvironment {
    public static func applyingFinalizePromotion(_ environment: [String: String]) -> [String: String] {
        guard shouldPromoteFinalize(environment) else { return environment }
        guard environment["SOUL_FINALIZE_PROMOTE_AUTHORITY"]?.isEmpty ?? true else { return environment }
        var env = environment
        env["SOUL_FINALIZE_PROMOTE_AUTHORITY"] = "1"
        return env
    }

    public static func shouldPromoteFinalize(_ environment: [String: String]) -> Bool {
        let mode = environment["SOUL_REGISTRY_AUTHORITY"]?.lowercased()
        guard mode == "required" else { return false }
        guard let rawURL = environment["SOUL_REGISTRY_AUTHORITY_URL"]?.lowercased() else { return false }
        return rawURL.hasPrefix("tcp://")
    }
}
