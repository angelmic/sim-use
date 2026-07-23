// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

public enum AppiumError: Error, LocalizedError, HintProviding, Equatable {
    case invalidEndpoint(String)
    case connectionFailed(endpoint: String, message: String)
    case webdriver(status: Int, message: String)
    case invalidResponse(String)
    case invalidScreenshot

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return "Invalid Appium endpoint: \(value)"
        case .connectionFailed(let endpoint, let message):
            return "Cannot reach Appium at \(endpoint): \(message)"
        case .webdriver(let status, let message):
            return "Appium WebDriver request failed (HTTP \(status)): \(message)"
        case .invalidResponse(let message):
            return "Appium returned an invalid WebDriver response: \(message)"
        case .invalidScreenshot:
            return "Appium returned screenshot data that was not valid base64."
        }
    }

    public var hint: String? {
        switch self {
        case .connectionFailed(let endpoint, _):
            let port = URL(string: endpoint)?.port ?? 4723
            return "Start Appium with `appium --port \(port)` and ensure the XCUITest driver is installed (`appium driver install xcuitest`)."
        case .webdriver:
            return "Run `appium driver doctor xcuitest`, then retry with the tvOS Simulator booted."
        case .invalidEndpoint, .invalidResponse, .invalidScreenshot:
            return nil
        }
    }
}
