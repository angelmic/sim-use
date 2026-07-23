// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One WebDriver request at the Appium process boundary. Keeping the transport
/// this small makes a backend's public observe/action contract testable
/// without launching WebDriverAgent in unit tests.
public struct AppiumRequest: Sendable {
    public let method: String
    public let url: URL
    public let body: Data?

    public init(method: String, url: URL, body: Data? = nil) {
        self.method = method
        self.url = url
        self.body = body
    }
}

public struct AppiumResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol AppiumTransport: Sendable {
    func send(_ request: AppiumRequest) async throws -> AppiumResponse
}

public final class URLSessionAppiumTransport: AppiumTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // A first session may build WebDriverAgent. Subsequent
            // sessions reuse it and complete in a few seconds.
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 240
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: AppiumRequest) async throws -> AppiumResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AppiumError.invalidResponse("Appium returned a non-HTTP response.")
        }
        return AppiumResponse(statusCode: http.statusCode, body: data)
    }
}
