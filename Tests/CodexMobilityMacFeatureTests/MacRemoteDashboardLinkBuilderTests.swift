@testable import CodexMobilityMacFeature
import Testing

@Suite("Mac remote dashboard access links")
struct MacRemoteDashboardLinkBuilderTests {
    @Test
    func publicURLRequiresHTTPSAndDropsQueryOrFragment() {
        #expect(
            MacRemoteDashboardLinkBuilder.normalizedPublicURL(
                "https://gateway.example.com/app/codex-watch-pet?old=1#token=stale"
            ) == "https://gateway.example.com/app/codex-watch-pet/"
        )
        #expect(
            MacRemoteDashboardLinkBuilder.normalizedPublicURL(
                "http://gateway.example.com/app/codex-watch-pet/"
            ) == nil
        )
    }

    @Test
    func tokenLivesOnlyInTheURLFragment() {
        let link = MacRemoteDashboardLinkBuilder.tokenized(
            baseURL: "http://127.0.0.1:8788/",
            token: "safe-token"
        )
        let requestURL = String((link ?? "").split(separator: "#").first ?? "")

        #expect(link == "http://127.0.0.1:8788/#token=safe-token")
        #expect(!requestURL.contains("safe-token"))
    }

    @Test
    func hubHealthUsesTheGatewayOriginWithoutTheAppPath() {
        #expect(
            MacRemoteDashboardLinkBuilder.gatewayHealthURL(
                publicAppURL: "https://gateway.example.com/app/codex-watch-pet/"
            )?.absoluteString == "https://gateway.example.com/api/platform/health"
        )
    }
}
