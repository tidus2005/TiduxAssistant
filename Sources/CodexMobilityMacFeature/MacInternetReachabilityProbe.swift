import Foundation

public protocol MacInternetReachabilityProbing: Sendable {
    func isInternetReachable() async -> Bool
}

/// Uses the current system route/proxy/VPN. Never installs a direct-route
/// override, disables TLS verification, or changes VPN/DNS/proxy settings.
public struct MacInternetReachabilityProbe: MacInternetReachabilityProbing {
    public init() {}

    public func isInternetReachable() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for address in ["https://www.apple.com/library/test/success.html",
                            "https://cp.cloudflare.com/generate_204"] {
                group.addTask { await Self.check(address) }
            }
            for await success in group where success {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    static func accepts(status: Int, body: Data, appleProbe: Bool) -> Bool {
        if !appleProbe { return status == 204 }
        return status == 200 && String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
    }

    private static func check(_ address: String) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: address)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, let http = response as? HTTPURLResponse else { return false }
            return accepts(status: http.statusCode, body: data, appleProbe: address.contains("apple.com"))
        } catch { return false }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
