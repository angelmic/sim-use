// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Optional app target for tvOS commands and cross-platform physical Apple
/// device verbs. Supplying a bundle id lets Appium restore the intended
/// foreground app after a cold WebDriverAgent launch; without one, the
/// command attaches to whatever app is already foreground.
public struct TVOSTargetOptions: ParsableArguments {
    @Option(
        name: .customLong("bundle-id"),
        help: "Activate this app after WebDriverAgent starts. Optional — tvOS defaults to SIM_USE_TVOS_BUNDLE_ID, then the current foreground app."
    )
    public var bundleId: String?

    public init() {}
}
