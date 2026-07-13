import Testing
@testable import SoulCore

@Suite("Soul authority environment")
struct SoulAuthorityEnvironmentTests {
    @Test("required TCP authority enables finalize promotion")
    func requiredTCPAuthorityPromotesFinalize() {
        let env = SoulAuthorityEnvironment.applyingFinalizePromotion([
            "SOUL_REGISTRY_AUTHORITY": "required",
            "SOUL_REGISTRY_AUTHORITY_URL": "tcp://100.123.210.64:4720",
        ])

        #expect(env["SOUL_FINALIZE_PROMOTE_AUTHORITY"] == "1")
    }

    @Test("explicit finalize promotion value is preserved")
    func explicitPromotionValueIsPreserved() {
        let env = SoulAuthorityEnvironment.applyingFinalizePromotion([
            "SOUL_REGISTRY_AUTHORITY": "required",
            "SOUL_REGISTRY_AUTHORITY_URL": "tcp://100.123.210.64:4720",
            "SOUL_FINALIZE_PROMOTE_AUTHORITY": "0",
        ])

        #expect(env["SOUL_FINALIZE_PROMOTE_AUTHORITY"] == "0")
    }

    @Test("auto and local authority do not promote finalize")
    func nonRequiredAuthorityDoesNotPromoteFinalize() {
        let auto = SoulAuthorityEnvironment.applyingFinalizePromotion([
            "SOUL_REGISTRY_AUTHORITY": "auto",
            "SOUL_REGISTRY_AUTHORITY_URL": "tcp://100.123.210.64:4720",
        ])
        let unix = SoulAuthorityEnvironment.applyingFinalizePromotion([
            "SOUL_REGISTRY_AUTHORITY": "required",
            "SOUL_REGISTRY_AUTHORITY_URL": "unix:///tmp/app-server.sock",
        ])

        #expect(auto["SOUL_FINALIZE_PROMOTE_AUTHORITY"] == nil)
        #expect(unix["SOUL_FINALIZE_PROMOTE_AUTHORITY"] == nil)
    }
}
