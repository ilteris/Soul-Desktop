import Foundation
import Testing
@testable import Soul_Desktop

@Suite("Web preview routing")
struct WebPreviewRoutingTests {
    @Test func localhostHTTPRoutesIntoSoul() throws {
        let url = try #require(URL(string: "http://localhost:4321/index.html"))

        #expect(WebPreviewRouting.shouldOpenInSoul(url))
        #expect(!WebPreviewRouting.isExternal(url))
    }

    @Test func loopbackAddressRoutesIntoSoul() throws {
        let url = try #require(URL(string: "https://127.0.0.1:5173/preview"))

        #expect(WebPreviewRouting.shouldOpenInSoul(url))
        #expect(!WebPreviewRouting.isExternal(url))
    }

    @Test func ipv6LoopbackRoutesIntoSoul() throws {
        let url = try #require(URL(string: "http://[::1]:8080/preview"))

        #expect(WebPreviewRouting.shouldOpenInSoul(url))
        #expect(!WebPreviewRouting.isExternal(url))
    }

    @Test func externalHTTPSStaysExternal() throws {
        let url = try #require(URL(string: "https://example.com/page"))

        #expect(!WebPreviewRouting.shouldOpenInSoul(url))
        #expect(WebPreviewRouting.isExternal(url))
    }

    @Test func fileURLsStayInsideWebViewPolicy() throws {
        let url = URL(fileURLWithPath: "/tmp/resume.html")

        #expect(!WebPreviewRouting.shouldOpenInSoul(url))
        #expect(!WebPreviewRouting.isExternal(url))
    }

    @Test func nonFileNonLocalhostSchemesOpenExternally() throws {
        let url = try #require(URL(string: "mailto:hello@example.com"))

        #expect(!WebPreviewRouting.shouldOpenInSoul(url))
        #expect(WebPreviewRouting.isExternal(url))
    }
}
