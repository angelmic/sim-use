// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import Foundation
import SimUseCore
import XCTest
@testable import DeviceBackend

/// Drives each iOS device verb through a scripted transport and asserts the
/// exact WebDriver request sequence and W3C payloads — the observable
/// contract the real WebDriverAgent sees.
final class AppleDeviceControllerTests: XCTestCase {
    private let iPhoneUDID = "00008110-001234567890001E"
    private let tvUDID = "0123456789abcdef0123456789abcdef01234567"
    private var homesToClean: [URL] = []

    private let source = """
    <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Example App" label="Example App" bundleId="com.example.app" x="0" y="0" width="393" height="852">
      <XCUIElementTypeSearchField type="XCUIElementTypeSearchField" name="searchField" label="Search" value="" enabled="true" visible="true" x="20" y="80" width="353" height="36"/>
    </XCUIElementTypeApplication>
    """

    override func tearDown() {
        for home in homesToClean { try? FileManager.default.removeItem(at: home) }
        homesToClean = []
        super.tearDown()
    }

    private func iPhone(state: String = "connected") -> Device {
        Device(udid: iPhoneUDID, name: "Test iPhone", platform: .ios, kind: .physical, state: state, runtime: "iOS 18.7.8")
    }

    private func makeController(
        _ responses: [Result<AppiumResponse, Error>],
        device: Device,
        config: DeviceCapabilityConfig = DeviceCapabilityConfig(),
        wdaCache: WDADeviceCache = .disabled(),
        configResolver: AppleDeviceController.ConfigResolver? = nil,
        activationSettler: @escaping @Sendable () async throws -> Void = {},
        actionSleeper: @escaping @Sendable (Double) async throws -> Void = { _ in }
    ) -> (AppleDeviceController, MockTransport) {
        let transport = MockTransport(responses: responses)
        let base = URL(string: "http://127.0.0.1:4788")!
        let home = makeTempHome()
        homesToClean.append(home)
        let controller = AppleDeviceController(
            client: AppiumClient(baseURL: base, transport: transport),
            preflight: DevicePreflight(
                baseURL: base,
                statusTransport: transport,
                infoResolver: DeviceInfoResolver(provider: { [device] })
            ),
            config: config,
            cacheHome: home,
            wdaCache: wdaCache,
            configResolver: configResolver,
            activationSettler: activationSettler,
            actionSleeper: actionSleeper
        )
        return (controller, transport)
    }

    // MARK: - tap

    func testTapPointSendsW3CActionsAndDeletesSession() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone()
        )
        let point = try await controller.tap(udid: iPhoneUDID, target: .point(x: 120, y: 340))
        XCTAssertEqual(point.x, 120)
        XCTAssertEqual(point.y, 340)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "POST", "DELETE"])
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/actions", "/session/session-1",
        ])

        let actions = try decodeActions(requests[2])
        let source = try XCTUnwrap(actions.actions.first)
        XCTAssertEqual(source.type, "pointer")
        XCTAssertEqual(source.parameters["pointerType"], "touch")
        XCTAssertEqual(source.actions.map(\.type), ["pointerMove", "pointerDown", "pointerUp"])
        XCTAssertEqual(source.actions[0].x, 120)
        XCTAssertEqual(source.actions[0].y, 340)
        XCTAssertEqual(source.actions[1].button, 0)
    }

    func testTapWithHoldInsertsPause() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone()
        )
        _ = try await controller.tap(udid: iPhoneUDID, target: .point(x: 10, y: 20), holdMs: 50)
        let requests = await transport.recordedRequests()
        let actions = try decodeActions(requests[2])
        let items = try XCTUnwrap(actions.actions.first?.actions)
        XCTAssertEqual(items.map(\.type), ["pointerMove", "pointerDown", "pause", "pointerUp"])
        XCTAssertEqual(items[2].duration, 50)
    }

    func testTapHonorsPreAndPostDelay() async throws {
        let probe = ActionSleepProbe()
        let (controller, _) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone(),
            actionSleeper: { await probe.record($0) }
        )

        _ = try await controller.tap(
            udid: iPhoneUDID,
            target: .point(x: 10, y: 20),
            preDelay: 0.1,
            postDelay: 0.2
        )

        let values = await probe.values
        XCTAssertEqual(values, [0.1, 0.2])
    }

    func testTapSelectorResolvesFreshSourceThenTapsCenter() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(source), emptyOK(), emptyOK()],
            device: iPhone()
        )
        let point = try await controller.tap(
            udid: iPhoneUDID,
            target: .selector(DeviceSelector(id: "searchField"))
        )
        // Center of (20,80 353x36) = (196.5, 98) → rounded on the wire.
        XCTAssertEqual(point.x, 196.5, accuracy: 0.001)
        XCTAssertEqual(point.y, 98, accuracy: 0.001)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/source", "/session/session-1/actions", "/session/session-1",
        ])
        let actions = try decodeActions(requests[3])
        XCTAssertEqual(actions.actions.first?.actions.first?.x, 197) // 196.5 rounds to 197
        XCTAssertEqual(actions.actions.first?.actions.first?.y, 98)
    }

    func testTapSelectorPollsAfterNoMatchWhenWaitTimeoutIsActive() async throws {
        let probe = ActionSleepProbe()
        let emptySource = """
        <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Example App" label="Example App" bundleId="com.example.app" x="0" y="0" width="393" height="852"/>
        """
        let (controller, transport) = makeController(
            [
                statusOK(), sessionResponse(),
                valueResponse(emptySource), valueResponse(source),
                emptyOK(), emptyOK(),
            ],
            device: iPhone(),
            actionSleeper: { await probe.record($0) }
        )

        _ = try await controller.tap(
            udid: iPhoneUDID,
            target: .selector(DeviceSelector(id: "searchField")),
            waitTimeout: 0.2,
            pollInterval: 0.1
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map { $0.url.path }.filter { $0.hasSuffix("/source") }.count,
            2
        )
        let values = await probe.values
        XCTAssertEqual(values, [0.1])
    }

    func testTapForwardsBundleIdAndActivatesApp() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK(), emptyOK()],
            device: iPhone()
        )
        _ = try await controller.tap(udid: iPhoneUDID, target: .point(x: 1, y: 2), bundleId: "com.example.app")
        let requests = await transport.recordedRequests()
        // Session POST (index 1): attach + activate semantics, not launch.
        let caps = try JSONDecoder().decode(SessionCapsProbe.self, from: try XCTUnwrap(requests[1].body))
        XCTAssertEqual(caps.capabilities.alwaysMatch.bundleId, "com.example.app")
        XCTAssertEqual(caps.capabilities.alwaysMatch.autoLaunch, false)
        XCTAssertEqual(caps.capabilities.alwaysMatch.noReset, true)
        XCTAssertEqual(caps.capabilities.alwaysMatch.shouldTerminateApp, false)
        // The app is foregrounded via mobile: activateApp before the tap.
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/execute/sync",
            "/session/session-1/actions", "/session/session-1",
        ])
        let activate = try JSONDecoder().decode(ExecuteProbe.self, from: try XCTUnwrap(requests[2].body))
        XCTAssertEqual(activate.script, "mobile: activateApp")
        XCTAssertEqual(activate.args.first?["bundleId"], "com.example.app")
    }

    // MARK: - swipe

    func testSwipeSendsMoveDownMoveUp() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone()
        )
        try await controller.swipe(
            udid: iPhoneUDID,
            from: (x: 10, y: 20), to: (x: 30, y: 400), durationMs: 250
        )
        let requests = await transport.recordedRequests()
        let actions = try decodeActions(requests[2])
        let items = try XCTUnwrap(actions.actions.first?.actions)
        XCTAssertEqual(items.map(\.type), ["pointerMove", "pointerDown", "pointerMove", "pointerUp"])
        XCTAssertEqual(items[0].x, 10)
        XCTAssertEqual(items[2].x, 30)
        XCTAssertEqual(items[2].y, 400)
        XCTAssertEqual(items[2].duration, 250)
    }

    func testSwipeHonorsPreAndPostDelay() async throws {
        let probe = ActionSleepProbe()
        let (controller, _) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone(),
            actionSleeper: { await probe.record($0) }
        )

        try await controller.swipe(
            udid: iPhoneUDID,
            from: (x: 10, y: 20),
            to: (x: 30, y: 400),
            durationMs: 250,
            preDelay: 0.3,
            postDelay: 0.4
        )

        let values = await probe.values
        XCTAssertEqual(values, [0.3, 0.4])
    }

    // MARK: - describe-ui

    func testDescribeUIRendersAndWritesAliasCache() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(source), emptyOK()],
            device: iPhone()
        )
        let result = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)
        XCTAssertEqual(result.platform, .ios)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.uniqueId, "searchField")

        // The cache write lets `tap @1` resolve later without a live tree.
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/source", "/session/session-1",
        ])
    }

    // MARK: - type / paste

    func testTypeSendsKeysToActiveElement() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), elementResponse(id: "field-9"), emptyOK(), emptyOK()],
            device: iPhone()
        )
        try await controller.type(udid: iPhoneUDID, text: "Inception")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/element/active",
            "/session/session-1/element/field-9/value", "/session/session-1",
        ])
        let body = try JSONDecoder().decode(SendKeysProbe.self, from: try XCTUnwrap(requests[3].body))
        XCTAssertEqual(body.text, "Inception")
    }

    func testPasteSetsPhysicalClipboardThenSendsKeys() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), elementResponse(id: "field-9"), emptyOK(), emptyOK()],
            device: iPhone()
        )
        try await controller.paste(udid: iPhoneUDID, text: "hi")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/execute/sync",
            "/session/session-1/element/active", "/session/session-1/element/field-9/value", "/session/session-1",
        ])
        let execute = try JSONDecoder().decode(ExecuteProbe.self, from: try XCTUnwrap(requests[2].body))
        XCTAssertEqual(execute.script, "mobile: setClipboard")
        XCTAssertEqual(execute.args.first?["contentType"], "plaintext")
        XCTAssertEqual(execute.args.first?["content"], Data("hi".utf8).base64EncodedString())
    }

    func testPasteReplaceClearsActiveElementBeforeSendingKeys() async throws {
        let (controller, transport) = makeController(
            [
                statusOK(), sessionResponse(), emptyOK(),
                elementResponse(id: "field-9"), emptyOK(), emptyOK(), emptyOK(),
            ],
            device: iPhone()
        )

        try await controller.paste(udid: iPhoneUDID, text: "replacement", replace: true)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/execute/sync",
            "/session/session-1/element/active",
            "/session/session-1/element/field-9/clear",
            "/session/session-1/element/field-9/value",
            "/session/session-1",
        ])
    }

    // MARK: - screenshot

    func testScreenshotDecodesBase64PNG() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(png.base64EncodedString()), emptyOK()],
            device: iPhone()
        )
        let data = try await controller.screenshot(udid: iPhoneUDID)
        XCTAssertEqual(data, png)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/screenshot", "/session/session-1",
        ])
    }

    func testTargetedScreenshotSettlesActivationBeforeCapture() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let probe = ActivationSettleProbe()
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), valueResponse(png.base64EncodedString()), emptyOK()],
            device: iPhone(),
            activationSettler: { await probe.record() }
        )

        _ = try await controller.screenshot(udid: iPhoneUDID, bundleId: "com.example.app")

        let settleCount = await probe.count
        XCTAssertEqual(settleCount, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/execute/sync",
            "/session/session-1/screenshot", "/session/session-1",
        ])
    }

    // MARK: - Per-device WDA signing/build recovery

    func testControllerResolvesSigningConfigAfterPreflightIdentifiesUDID() async throws {
        let (cache, plan) = makeIOSCache()
        try FileManager.default.createDirectory(
            at: plan.runnerAppPath,
            withIntermediateDirectories: true
        )
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(source), emptyOK()],
            device: iPhone(),
            config: DeviceCapabilityConfig(),
            wdaCache: cache,
            configResolver: { [iPhoneUDID] info in
                XCTAssertEqual(info.udid, iPhoneUDID)
                return DeviceCapabilityConfig(
                    iosWDABundleId: "com.example.WebDriverAgentRunner",
                    xcodeOrgId: "ZYXWV98765",
                    xcodeSigningId: "Apple Development"
                )
            }
        )

        _ = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)

        let requests = await transport.recordedRequests()
        let session = try decodeSessionCaps(try XCTUnwrap(
            requests.first { $0.method == "POST" && $0.url.path == "/session" }
        ))
        XCTAssertEqual(session.capabilities.alwaysMatch.derivedDataPath, plan.derivedDataPath.path)
        XCTAssertEqual(session.capabilities.alwaysMatch.xcodeOrgId, "ZYXWV98765")
        XCTAssertEqual(
            session.capabilities.alwaysMatch.updatedWDABundleId,
            "com.example.WebDriverAgentRunner"
        )
    }

    func testControllerRefreshesSigningConfigAfterTakingRepairLock() async throws {
        let (cache, _) = makeIOSCache()
        let sequence = SynchronousConfigSequence([
            DeviceCapabilityConfig(
                iosWDABundleId: "com.example.StaleRunner",
                xcodeOrgId: "STALETEAM1",
                xcodeSigningId: "Stale Identity"
            ),
            iosSigningConfig(),
        ])
        let refreshedPlan = cache.plan(for: PhysicalDeviceInfo(
            udid: iPhoneUDID,
            family: .ios,
            osMajorVersion: 18,
            tunnelState: "connected",
            osVersion: "18.7.8"
        ), config: iosSigningConfig())
        try FileManager.default.createDirectory(
            at: refreshedPlan.runnerAppPath,
            withIntermediateDirectories: true
        )
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(source), emptyOK()],
            device: iPhone(),
            config: DeviceCapabilityConfig(),
            wdaCache: cache,
            configResolver: { _ in sequence.next() }
        )

        _ = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)

        let requests = await transport.recordedRequests()
        let session = try decodeSessionCaps(try XCTUnwrap(
            requests.first { $0.method == "POST" && $0.url.path == "/session" }
        ))
        XCTAssertEqual(session.capabilities.alwaysMatch.xcodeOrgId, "ZYXWV98765")
        XCTAssertEqual(
            session.capabilities.alwaysMatch.updatedWDABundleId,
            "com.example.WebDriverAgentRunner"
        )
        XCTAssertEqual(sequence.callCount, 2)
        let persisted = cache.resolvedConfig(
            for: PhysicalDeviceInfo(
                udid: iPhoneUDID,
                family: .ios,
                osMajorVersion: 18,
                tunnelState: "connected",
                osVersion: "18.7.8"
            ),
            environment: [:]
        )
        XCTAssertEqual(persisted.xcodeOrgId, "ZYXWV98765")
        XCTAssertEqual(
            persisted.iosWDABundleId,
            "com.example.WebDriverAgentRunner"
        )
    }

    func testIOSCacheMissForcesFreshIncrementalBuildInsteadOfReusingRunningWDA() async throws {
        let (cache, plan) = makeIOSCache()
        // Model the artifact Appium's repair build leaves in the stable
        // per-device DerivedData directory, so the successful session can
        // persist a verified signing record.
        try FileManager.default.createDirectory(at: plan.runnerAppPath, withIntermediateDirectories: true)
        let config = iosSigningConfig()
        let (controller, transport) = makeController(
            [
                statusOK(),
                sessionResponse(id: "repair-session"),
                valueResponse(source),
                emptyOK(),
            ],
            device: iPhone(),
            config: config,
            wdaCache: cache
        )

        _ = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)

        let requests = await transport.recordedRequests()
        let sessionRequests = requests.filter { $0.method == "POST" && $0.url.path == "/session" }
        XCTAssertEqual(sessionRequests.count, 1, "a known cache miss must go straight to one incremental repair")
        let repair = try decodeSessionCaps(sessionRequests[0])
        XCTAssertNil(repair.capabilities.alwaysMatch.usePreinstalledWDA)
        XCTAssertNil(repair.capabilities.alwaysMatch.usePrebuiltWDA)
        XCTAssertEqual(
            repair.capabilities.alwaysMatch.useNewWDA,
            true,
            "a cache miss must not reuse a still-running WDA with a stale local signature"
        )
        XCTAssertEqual(repair.capabilities.alwaysMatch.derivedDataPath, plan.derivedDataPath.path)
        XCTAssertEqual(repair.capabilities.alwaysMatch.xcodeOrgId, "ZYXWV98765")
        XCTAssertEqual(repair.capabilities.alwaysMatch.xcodeSigningId, "Apple Development")
        XCTAssertEqual(repair.capabilities.alwaysMatch.updatedWDABundleId, "com.example.WebDriverAgentRunner")
        XCTAssertNoThrow(try cache.readRecord(for: iPhoneUDID))
    }

    func testUnavailableHostMetadataStillBuildsWithoutPreinstalledTimeout() async throws {
        let home = makeTempHome()
        homesToClean.append(home)
        let cache = WDADeviceCache(
            home: home,
            metadataProvider: {
                throw WDADeviceCache.ArtifactValidationError.metadataMissing("xcode build")
            },
            artifactInspector: { throw WDADeviceCache.ArtifactValidationError.missing($0.path) }
        )
        let (controller, transport) = makeController(
            [
                statusOK(),
                sessionResponse(id: "metadata-repair-session"),
                valueResponse(source),
                emptyOK(),
            ],
            device: iPhone(),
            config: iosSigningConfig(),
            wdaCache: cache
        )

        _ = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)

        let requests = await transport.recordedRequests()
        let sessionRequests = requests.filter { $0.method == "POST" && $0.url.path == "/session" }
        XCTAssertEqual(sessionRequests.count, 1)
        let repair = try decodeSessionCaps(try XCTUnwrap(sessionRequests.first))
        XCTAssertNil(repair.capabilities.alwaysMatch.usePreinstalledWDA)
        XCTAssertNil(repair.capabilities.alwaysMatch.usePrebuiltWDA)
        XCTAssertEqual(repair.capabilities.alwaysMatch.useNewWDA, true)
        XCTAssertEqual(
            repair.capabilities.alwaysMatch.derivedDataPath,
            cache.derivedDataPath(for: iPhoneUDID).path
        )
        XCTAssertEqual(repair.capabilities.alwaysMatch.xcodeOrgId, "ZYXWV98765")
        let nextRun = cache.resolvedConfig(
            for: PhysicalDeviceInfo(
                udid: iPhoneUDID,
                family: .ios,
                osMajorVersion: 18,
                tunnelState: "connected",
                osVersion: "18.7.8"
            ),
            environment: [:]
        )
        XCTAssertEqual(nextRun.iosWDABundleId, "com.example.WebDriverAgentRunner")
        XCTAssertEqual(
            nextRun.xcodeOrgId,
            "ZYXWV98765",
            "a successful repair must persist signing inputs even when host fingerprint metadata is unavailable"
        )
    }

    func testValidIOSSigningCacheUsesPrebuiltArtifactWithoutWaitingForPreinstalledTimeout() async throws {
        let (cache, plan) = makeIOSCache()
        try FileManager.default.createDirectory(at: plan.runnerAppPath, withIntermediateDirectories: true)
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        let (controller, transport) = makeController(
            [
                statusOK(),
                sessionResponse(id: "prebuilt-session"),
                valueResponse(source),
                emptyOK(),
            ],
            device: iPhone(),
            config: iosSigningConfig(),
            wdaCache: cache
        )

        _ = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)

        let requests = await transport.recordedRequests()
        let sessionRequests = requests.filter { $0.method == "POST" && $0.url.path == "/session" }
        XCTAssertEqual(sessionRequests.count, 1)
        let cached = try decodeSessionCaps(sessionRequests[0])
        XCTAssertEqual(cached.capabilities.alwaysMatch.usePrebuiltWDA, true)
        XCTAssertNil(cached.capabilities.alwaysMatch.useNewWDA)
        XCTAssertNil(cached.capabilities.alwaysMatch.usePreinstalledWDA)
        XCTAssertEqual(cached.capabilities.alwaysMatch.derivedDataPath, plan.derivedDataPath.path)
    }

    func testRejectedIOSPrebuiltArtifactFallsBackToOneIncrementalBuild() async throws {
        let (cache, plan) = makeIOSCache()
        try FileManager.default.createDirectory(at: plan.runnerAppPath, withIntermediateDirectories: true)
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        let (controller, transport) = makeController(
            [
                statusOK(),
                webdriverError("test-without-building failed for prebuilt WDA"),
                sessionResponse(id: "rebuilt-session"),
                valueResponse(source),
                emptyOK(),
            ],
            device: iPhone(),
            config: iosSigningConfig(),
            wdaCache: cache
        )

        _ = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)

        let requests = await transport.recordedRequests()
        let sessionRequests = requests.filter { $0.method == "POST" && $0.url.path == "/session" }
        XCTAssertEqual(sessionRequests.count, 2, "prebuilt, then one full incremental build")
        let prebuilt = try decodeSessionCaps(sessionRequests[0])
        let rebuild = try decodeSessionCaps(sessionRequests[1])
        XCTAssertEqual(prebuilt.capabilities.alwaysMatch.usePrebuiltWDA, true)
        XCTAssertNil(prebuilt.capabilities.alwaysMatch.useNewWDA)
        XCTAssertNil(rebuild.capabilities.alwaysMatch.usePrebuiltWDA)
        XCTAssertEqual(rebuild.capabilities.alwaysMatch.useNewWDA, true)
        XCTAssertNil(rebuild.capabilities.alwaysMatch.usePreinstalledWDA)
        XCTAssertEqual(rebuild.capabilities.alwaysMatch.derivedDataPath, plan.derivedDataPath.path)
        XCTAssertNoThrow(try cache.readRecord(for: iPhoneUDID))
    }

    func testRejectedLegacyPrebuiltKeepsSigningInputsWhenRepairFails() async {
        let (cache, plan) = makeIOSCache()
        try? FileManager.default.createDirectory(
            at: plan.runnerAppPath,
            withIntermediateDirectories: true
        )
        _ = try? cache.recordSuccessfulLaunch(plan)
        let (controller, _) = makeController(
            [
                statusOK(),
                webdriverError("test-without-building rejected prebuilt WDA"),
                webdriverError("xcodebuild repair failed"),
            ],
            device: iPhone(),
            config: iosSigningConfig(),
            wdaCache: cache
        )

        do {
            _ = try await controller.describeUI(
                udid: iPhoneUDID,
                includeRaw: false
            )
            XCTFail("expected the one repair attempt to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("xcodebuild repair failed"))
        }

        let info = PhysicalDeviceInfo(
            udid: iPhoneUDID,
            family: .ios,
            osMajorVersion: 18,
            tunnelState: "connected",
            osVersion: "18.7.8"
        )
        let persisted = cache.resolvedConfig(for: info, environment: [:])
        XCTAssertEqual(persisted.iosWDABundleId, "com.example.WebDriverAgentRunner")
        XCTAssertEqual(persisted.xcodeOrgId, "ZYXWV98765")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cache.recordFile(for: iPhoneUDID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cache.signingConfigFile(for: iPhoneUDID).path
        ))
    }

    func testIOSWithoutSigningConfigKeepsPreinstalledFastPathWithoutMetadataInspection() async throws {
        let probe = SynchronousCountProbe()
        let cache = WDADeviceCache(
            metadataProvider: {
                probe.increment()
                throw WDADeviceCache.ArtifactValidationError.metadataMissing("unexpected inspection")
            },
            artifactInspector: { throw WDADeviceCache.ArtifactValidationError.missing($0.path) }
        )
        let (controller, _) = makeController(
            [statusOK(), sessionResponse(), valueResponse(source), emptyOK()],
            device: iPhone(),
            config: DeviceCapabilityConfig(),
            wdaCache: cache
        )

        _ = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)

        XCTAssertEqual(probe.value, 0, "without signing config the installed-WDA path must remain zero-overhead")
    }

    func testIOSOperationFailureAfterSessionCreationNeverTriggersSigningRepair() async {
        let (cache, plan) = makeIOSCache()
        try? FileManager.default.createDirectory(at: plan.runnerAppPath, withIntermediateDirectories: true)
        _ = try? cache.recordSuccessfulLaunch(plan)
        let (controller, transport) = makeController(
            [
                statusOK(),
                sessionResponse(),
                webdriverError("WebDriverAgent source failed after the WDA session was already created"),
                emptyOK(),
            ],
            device: iPhone(),
            config: iosSigningConfig(),
            wdaCache: cache
        )

        do {
            _ = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)
            XCTFail("expected source failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("WebDriverAgent source failed"))
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { $0.method == "POST" && $0.url.path == "/session" }.count,
            1,
            "an operation must never be replayed after session creation"
        )
    }

    // MARK: - tvOS family guard

    func testCoordinateVerbsRejectTVOSDeviceBeforeSession() async {
        let tv = Device(udid: tvUDID, name: "TV", platform: .tvos, kind: .physical, state: "connected", runtime: "tvOS 26.5")
        let (controller, transport) = makeController([statusOK()], device: tv)
        do {
            _ = try await controller.tap(udid: tvUDID, target: .point(x: 1, y: 2))
            XCTFail("expected TVOSCapabilityError")
        } catch is TVOSCapabilityError {
            // The reject happens after preflight but before any session POST.
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.map(\.method), ["GET"]) // /status only
        } catch {
            XCTFail("expected TVOSCapabilityError, got \(error)")
        }
    }

    // MARK: - Probes

    private func decodeActions(_ request: AppiumRequest) throws -> ActionsProbe {
        try JSONDecoder().decode(ActionsProbe.self, from: try XCTUnwrap(request.body))
    }

    private func decodeSessionCaps(_ request: AppiumRequest) throws -> SigningCapsProbe {
        try JSONDecoder().decode(SigningCapsProbe.self, from: try XCTUnwrap(request.body))
    }

    private func iosSigningConfig() -> DeviceCapabilityConfig {
        DeviceCapabilityConfig(
            iosWDABundleId: "com.example.WebDriverAgentRunner",
            xcodeOrgId: "ZYXWV98765",
            xcodeSigningId: "Apple Development"
        )
    }

    private func makeIOSCache() -> (WDADeviceCache, WDADeviceCache.Plan) {
        let home = makeTempHome()
        homesToClean.append(home)
        let cache = WDADeviceCache(
            home: home,
            metadataProvider: {
                .init(xcodeBuild: "17C529", wdaSourceSHA256: "fixture-wda-source")
            },
            artifactInspector: { _ in
                .init(
                    bundleIdentifier: "com.example.WebDriverAgentRunner.xctrunner",
                    teamIdentifier: "ZYXWV98765",
                    signedAt: Date(timeIntervalSince1970: 1_774_837_800),
                    provisioningExpiresAt: Date(timeIntervalSince1970: 1_806_373_800)
                )
            },
            now: { Date(timeIntervalSince1970: 1_774_924_200) }
        )
        let info = PhysicalDeviceInfo(
            udid: iPhoneUDID,
            family: .ios,
            osMajorVersion: 18,
            tunnelState: "connected",
            osVersion: "18.7.8"
        )
        return (cache, cache.plan(for: info, config: iosSigningConfig()))
    }

    private struct ActionsProbe: Decodable {
        struct Source: Decodable {
            let type: String
            let id: String
            let parameters: [String: String]
            let actions: [Item]
        }
        struct Item: Decodable {
            let type: String
            let duration: Int?
            let x: Int?
            let y: Int?
            let button: Int?
        }
        let actions: [Source]
    }

    private struct SessionCapsProbe: Decodable {
        struct Caps: Decodable {
            struct AlwaysMatch: Decodable {
                let bundleId: String?
                let autoLaunch: Bool?
                let noReset: Bool?
                let shouldTerminateApp: Bool?
                enum CodingKeys: String, CodingKey {
                    case bundleId = "appium:bundleId"
                    case autoLaunch = "appium:autoLaunch"
                    case noReset = "appium:noReset"
                    case shouldTerminateApp = "appium:shouldTerminateApp"
                }
            }
            let alwaysMatch: AlwaysMatch
        }
        let capabilities: Caps
    }

    private struct SigningCapsProbe: Decodable {
        struct Caps: Decodable {
            struct AlwaysMatch: Decodable {
                let usePreinstalledWDA: Bool?
                let usePrebuiltWDA: Bool?
                let useNewWDA: Bool?
                let derivedDataPath: String?
                let xcodeOrgId: String?
                let xcodeSigningId: String?
                let updatedWDABundleId: String?
                enum CodingKeys: String, CodingKey {
                    case usePreinstalledWDA = "appium:usePreinstalledWDA"
                    case usePrebuiltWDA = "appium:usePrebuiltWDA"
                    case useNewWDA = "appium:useNewWDA"
                    case derivedDataPath = "appium:derivedDataPath"
                    case xcodeOrgId = "appium:xcodeOrgId"
                    case xcodeSigningId = "appium:xcodeSigningId"
                    case updatedWDABundleId = "appium:updatedWDABundleId"
                }
            }
            let alwaysMatch: AlwaysMatch
        }
        let capabilities: Caps
    }

    private struct SendKeysProbe: Decodable { let text: String }
    private struct ExecuteProbe: Decodable {
        let script: String
        let args: [[String: String]]
    }
}

private actor ActivationSettleProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor ActionSleepProbe {
    private(set) var values: [Double] = []

    func record(_ value: Double) {
        values.append(value)
    }
}

private final class SynchronousCountProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class SynchronousConfigSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let configs: [DeviceCapabilityConfig]
    private var index = 0

    init(_ configs: [DeviceCapabilityConfig]) {
        precondition(!configs.isEmpty)
        self.configs = configs
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func next() -> DeviceCapabilityConfig {
        lock.lock()
        defer {
            index += 1
            lock.unlock()
        }
        return configs[min(index, configs.count - 1)]
    }
}
