import AppKit
import Combine
import XCTest
@testable import DrivePulseApp

@MainActor
final class SettingsWindowActivatorTests: XCTestCase {
    func testFirstOpenRaisesNewSettingsWindow() async {
        let application = TestSettingsApplication()
        let window = TestSettingsWindow()
        let activator = makeActivator(application: application)
        var requestCount = 0
        let observation = activator.openRequests.sink {
            requestCount += 1
            window.isVisible = true
            application.windows = [window]
        }
        defer { observation.cancel() }

        activator.open()
        await waitUntil { window.raiseCount == 1 }

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(window.raiseCount, 1)
        XCTAssertEqual(window.windowIdentifier, SettingsWindowActivator.settingsWindowID)
        XCTAssertEqual(application.activationPolicies.last, .regular)
    }

    func testCloseThenReopenRaisesSameSettingsWindowInstance() {
        let application = TestSettingsApplication()
        let window = TestSettingsWindow(isVisible: true)
        let activator = makeActivator(application: application)
        activator.registerSettingsWindow(window)

        activator.settingsWindowDidClose(window)
        window.isVisible = false
        activator.open()

        XCTAssertEqual(window.raiseCount, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(application.activationPolicies, [.accessory, .regular])
    }

    func testKnownHiddenWindowIsRaisedWithoutSendingOpenRequest() {
        let application = TestSettingsApplication()
        let window = TestSettingsWindow(isVisible: false)
        let activator = makeActivator(application: application)
        activator.registerSettingsWindow(window)
        var requestCount = 0
        let observation = activator.openRequests.sink { requestCount += 1 }
        defer { observation.cancel() }

        activator.open()

        XCTAssertEqual(window.raiseCount, 1)
        XCTAssertEqual(requestCount, 0)
    }

    func testOpenTimeoutRestoresAccessoryPolicy() async {
        let application = TestSettingsApplication()
        let activator = makeActivator(application: application, maxPollAttempts: 1)

        activator.open()
        await waitUntil { application.activationPolicies.last == .accessory }

        XCTAssertEqual(application.activationPolicies, [.regular, .accessory])
    }

    func testRapidConsecutiveOpenOnlySendsLatestRequest() async {
        let application = TestSettingsApplication()
        let window = TestSettingsWindow()
        let activator = makeActivator(application: application)
        var requestCount = 0
        let observation = activator.openRequests.sink {
            requestCount += 1
            window.isVisible = true
            application.windows = [window]
        }
        defer { observation.cancel() }

        activator.open()
        activator.open()
        await waitUntil { window.raiseCount == 1 }

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(window.raiseCount, 1)
    }

    func testHiddenHostWindowIsNeverRecognizedAsSettings() async {
        let application = TestSettingsApplication()
        let hostWindow = TestSettingsWindow(
            windowIdentifier: SettingsWindowActivator.hiddenHostWindowID,
            isVisible: true
        )
        application.windows = [hostWindow]
        let activator = makeActivator(application: application, maxPollAttempts: 1)

        activator.open()
        await waitUntil { application.activationPolicies.last == .accessory }

        XCTAssertEqual(hostWindow.raiseCount, 0)
    }

    func testCancelledOldOpenCannotRevertLatestActivationPolicy() async {
        let application = TestSettingsApplication()
        let window = TestSettingsWindow()
        let waiter = ControlledSettingsWaiter()
        let activator = SettingsWindowActivator(
            application: application,
            initialDelay: .zero,
            pollInterval: .zero,
            maxPollAttempts: 1,
            wait: waiter.wait
        )
        var requestCount = 0
        let observation = activator.openRequests.sink {
            requestCount += 1
            if requestCount == 2 {
                window.isVisible = true
                application.windows = [window]
            }
        }
        defer { observation.cancel() }

        activator.open()
        await waitUntil { waiter.pendingCount == 1 }
        waiter.resume(at: 0)
        await waitUntil { requestCount == 1 && waiter.pendingCount == 1 }

        activator.open()
        await waitUntil { waiter.pendingCount == 2 }
        waiter.resume(at: 1)
        await waitUntil { window.raiseCount == 1 }
        waiter.resume(at: 0)
        await Task.yield()

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(application.activationPolicies.last, .regular)
    }

    func testExistingHiddenWindowCanBeDiscoveredWhenItBecomesVisible() async {
        let application = TestSettingsApplication()
        let window = TestSettingsWindow(isVisible: false)
        application.windows = [window]
        let activator = makeActivator(application: application)
        let observation = activator.openRequests.sink {
            window.isVisible = true
        }
        defer { observation.cancel() }

        activator.open()
        await waitUntil { window.raiseCount == 1 }

        XCTAssertEqual(window.raiseCount, 1)
    }

    private func makeActivator(
        application: TestSettingsApplication,
        initialDelay: Duration = .zero,
        maxPollAttempts: Int = 3
    ) -> SettingsWindowActivator {
        SettingsWindowActivator(
            application: application,
            initialDelay: initialDelay,
            pollInterval: .zero,
            maxPollAttempts: maxPollAttempts
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        iterations: Int = 100
    ) async {
        for _ in 0..<iterations where condition() == false {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class TestSettingsApplication: SettingsApplicationProviding {
    var windows: [any SettingsWindowRepresenting] = []
    private(set) var activationPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCount = 0

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        activationPolicies.append(policy)
    }

    func activate() {
        activationCount += 1
    }
}

@MainActor
private final class TestSettingsWindow: SettingsWindowRepresenting {
    var windowIdentifier: String?
    var isVisible: Bool
    private(set) var raiseCount = 0

    init(windowIdentifier: String? = nil, isVisible: Bool = false) {
        self.windowIdentifier = windowIdentifier
        self.isVisible = isVisible
    }

    func makeKeyAndOrderFront() {
        isVisible = true
        raiseCount += 1
    }
}

@MainActor
private final class ControlledSettingsWaiter {
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    var pendingCount: Int {
        continuations.count
    }

    func wait(for _: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(at index: Int) {
        continuations.remove(at: index).resume(returning: true)
    }
}
