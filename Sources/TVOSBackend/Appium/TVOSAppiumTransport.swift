// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One WebDriver request at the Appium process boundary. Keeping the transport
/// this small makes the backend's public observe/action contract testable
/// without launching WebDriverAgent in unit tests.
public struct TVOSAppiumRequest: Sendable {
    public let method: String
    public let url: URL
    public let body: Data?

    public init(method: String, url: URL, body: Data? = nil) {
        self.method = method
        self.url = url
        self.body = body
    }
}

public struct TVOSAppiumResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol TVOSAppiumTransport: Sendable {
    func send(_ request: TVOSAppiumRequest) async throws -> TVOSAppiumResponse
}

public final class URLSessionTVOSAppiumTransport: TVOSAppiumTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // A first tvOS session may build WebDriverAgent. Subsequent
            // sessions reuse it and complete in a few seconds.
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 240
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: TVOSAppiumRequest) async throws -> TVOSAppiumResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TVOSAppiumError.invalidResponse("Appium returned a non-HTTP response.")
        }
        return TVOSAppiumResponse(statusCode: http.statusCode, body: data)
    }
}
