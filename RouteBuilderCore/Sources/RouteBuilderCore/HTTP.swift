import Foundation

/// The seam between the providers and the network.
///
/// Every provider talks through this rather than touching `URLSession`
/// directly, which is what lets the elevation resolver, the router and
/// Discover be tested offline with canned responses. The web app had no
/// equivalent — its logic and its `fetch` calls were the same lines — and that
/// is the main reason its provider behaviour was never covered by a test.
public protocol HTTPFetching: Sendable {
    func data(for request: URLRequest) async throws -> Data
}

extension HTTPFetching {
    public func data(from url: URL) async throws -> Data {
        try await data(for: URLRequest(url: url))
    }
}

public struct HTTPError: Error, Equatable, Sendable {
    public var statusCode: Int
    public var source: String

    public init(statusCode: Int, source: String) {
        self.statusCode = statusCode
        self.source = source
    }
}

public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(statusCode: http.statusCode,
                            source: request.url?.host ?? "unknown")
        }
        return data
    }
}
