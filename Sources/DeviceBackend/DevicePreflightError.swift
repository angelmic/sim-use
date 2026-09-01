// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Fail-fast rejections raised *before* any Appium session is created, so a
/// down server or an unreachable device returns in seconds with an
/// actionable message instead of the ~90 s silent WebDriver timeout that
/// P0-C2 flagged. Every case carries a `hint` with the exact recovery
/// command.
public enum DevicePreflightError: Error, LocalizedError, HintProviding, Equatable {
    /// `GET /status` did not answer (connection refused, timed out, or a
    /// non-2xx). The user's own server on 4723 may be wedged; the backend
    /// never assumes a port.
    case appiumUnreachable(endpoint: String, detail: String)
    /// No connected physical Apple device carries this UDID — not cabled,
    /// not trusted, or a typo.
    case deviceNotFound(udid: String)
    /// The device is known but its CoreDevice tunnel is not up, so a
    /// session POST would hang. `state` is `tunnelState` verbatim.
    case tunnelNotConnected(udid: String, state: String)
    /// A classic (≤16.x) device needs an external WebDriverAgent, but
    /// `SIM_USE_WDA_URL` is unset — there is no modern `usePreinstalledWDA`
    /// path on these OSes. Carries the bundle id of the residual WDA so the
    /// hint can name the exact `idevicedebug` / `iproxy` commands.
    case classicWDAMissing(udid: String, wdaBundleId: String)
    /// A modern tvOS device builds WDA through the xcodebuild flow, which
    /// signs with an Apple Developer Team id the CLI cannot guess — and it
    /// is unset. iOS uses the preinstalled WDA and never hits this.
    case xcodeOrgIdMissing(udid: String)

    public var errorDescription: String? {
        switch self {
        case .appiumUnreachable(let endpoint, let detail):
            return "Appium is not reachable at \(endpoint) (\(detail))."
        case .deviceNotFound(let udid):
            return "No connected physical Apple device found for UDID \(udid)."
        case .tunnelNotConnected(let udid, let state):
            return "Physical device \(udid) is not reachable: CoreDevice tunnelState is \"\(state)\", not \"connected\"."
        case .classicWDAMissing(let udid, _):
            return "tvOS/iOS 16.x device \(udid) needs an external WebDriverAgent, but SIM_USE_WDA_URL is not set."
        case .xcodeOrgIdMissing(let udid):
            return "tvOS device \(udid) needs an Apple Developer Team id to build WebDriverAgent, but none is set."
        }
    }

    public var hint: String? {
        switch self {
        case .appiumUnreachable(let endpoint, _):
            let port = URL(string: endpoint)?.port ?? 4723
            return "Start a task-owned Appium server on a free port and point SIM_USE_APPIUM_URL at it, "
                + "e.g. `appium --port \(port) --base-path /` then `export SIM_USE_APPIUM_URL=\(endpoint)`. "
                + "Do not reuse a wedged 4723 server; pick a fresh port instead."
        case .deviceNotFound:
            return "Cable the device and trust this Mac, then confirm it appears in `sim-use devices` "
                + "(or `xcrun devicectl list devices`). Pass the UDID from that listing with `--device`."
        case .tunnelNotConnected(let udid, _):
            return "Bring the CoreDevice tunnel up (reconnect USB / re-trust), then verify with "
                + "`xcrun devicectl device info details --device \(udid)` showing tunnelState: connected. "
                + "See device-appium-xcuitest.md §2 for the tunnel troubleshooting path."
        case .classicWDAMissing(let udid, let wdaBundleId):
            return """
                Start the residual on-device WebDriverAgent over usbmux, then export its URL:
                  idevicedebug -u \(udid) run \(wdaBundleId).xctrunner &
                  iproxy 8104:8100 -u \(udid) &
                  curl -s http://127.0.0.1:8104/status   # expect {"value":{...}}
                  export SIM_USE_WDA_URL=http://127.0.0.1:8104
                This is the classic免-tunnel免-重簽 path (P0-C3); modern usePreinstalledWDA does not apply on ≤16.x.
                """
        case .xcodeOrgIdMissing:
            return "Set SIM_USE_XCODE_ORG_ID to your Apple Developer Team id (a 10-character alphanumeric, format like ABCDE12345). "
                + "Find it in Xcode > Settings > Accounts (your team's ID), on the developer portal, or via "
                + "`security find-identity -v -p codesigning`. Optionally set SIM_USE_XCODE_SIGNING_ID (defaults to \"Apple Development\")."
        }
    }
}
