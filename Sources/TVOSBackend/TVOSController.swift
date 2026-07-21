// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

public enum TVOSRemoteButton: String, Codable, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
    case select
    case menu
    case playPause = "play-pause"
    case home

    var appiumName: String {
        switch self {
        case .playPause: return "playpause"
        default: return rawValue
        }
    }
}

public struct TVOSRemoteResult: Codable, Equatable, Sendable {
    public let button: TVOSRemoteButton
    public let before: Outline.Entry?
    public let after: Outline.Entry?

    public init(button: TVOSRemoteButton, before: Outline.Entry?, after: Outline.Entry?) {
        self.button = button
        self.before = before
        self.after = after
    }
}

/// High-level tvOS observe/action API shared by CLI commands and tests.
/// Every operation owns exactly one Appium session so failures cannot leave a
/// device claimed and block the next agent action.
public struct TVOSController: Sendable {
    private let client: TVOSAppiumClient

    public init(client: TVOSAppiumClient) {
        self.client = client
    }

    public static func live() throws -> TVOSController {
        TVOSController(client: try .live())
    }

    public func describeUI(
        udid: String,
        includeRaw: Bool,
        bundleId: String? = nil
    ) async throws -> DescribeUIResult {
        try await client.withSession(udid: udid, bundleId: bundleId) { session in
            let source = try await session.source()
            return try TVOSOutlineRenderer.render(source: source, includeRaw: includeRaw)
        }
    }

    public func pressRemote(
        _ button: TVOSRemoteButton,
        udid: String,
        bundleId: String? = nil
    ) async throws -> TVOSRemoteResult {
        try await client.withSession(udid: udid, bundleId: bundleId) { session in
            let beforeSource = try await session.source()
            let before = try TVOSOutlineRenderer
                .render(source: beforeSource, includeRaw: false)
                .entries.first(where: { $0.states.contains("focused") })
            try await session.pressRemote(button)
            let afterSource = try await session.source()
            let after = try TVOSOutlineRenderer
                .render(source: afterSource, includeRaw: false)
                .entries.first(where: { $0.states.contains("focused") })
            return TVOSRemoteResult(button: button, before: before, after: after)
        }
    }

    public func screenshot(udid: String, bundleId: String? = nil) async throws -> Data {
        try await client.withSession(udid: udid, bundleId: bundleId) { session in
            try await session.screenshot()
        }
    }
}
