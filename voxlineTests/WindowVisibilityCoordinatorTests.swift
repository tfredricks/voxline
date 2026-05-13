import Testing
import AppKit
@testable import voxline

@Suite @MainActor struct WindowVisibilityCoordinatorTests {

    @Test func tagged_window_made_visible_flips_to_regular() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter, windowsProvider: { [] })
        coord.start()

        let w = makeStubWindow(dockworthy: true)
        center.post(name: NSWindow.didBecomeKeyNotification, object: w)
        #expect(setter.policies == [.regular])
        #expect(setter.activateCount == 1)
    }

    @Test func untagged_window_made_visible_does_nothing() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter, windowsProvider: { [] })
        coord.start()

        let w = makeStubWindow(dockworthy: false)
        center.post(name: NSWindow.didBecomeKeyNotification, object: w)
        #expect(setter.policies.isEmpty)
        #expect(setter.activateCount == 0)
    }

    @Test func closing_last_tagged_window_returns_to_accessory() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter, windowsProvider: { [] })
        coord.start()

        let w = makeStubWindow(dockworthy: true)
        center.post(name: NSWindow.didBecomeKeyNotification, object: w)
        center.post(name: NSWindow.willCloseNotification, object: w)
        #expect(setter.policies == [.regular, .accessory])
    }

    @Test func two_tagged_windows_only_flip_once_per_direction() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter, windowsProvider: { [] })
        coord.start()

        let a = makeStubWindow(dockworthy: true)
        let b = makeStubWindow(dockworthy: true)
        center.post(name: NSWindow.didBecomeKeyNotification, object: a)
        center.post(name: NSWindow.didBecomeKeyNotification, object: b)
        center.post(name: NSWindow.willCloseNotification, object: a)
        #expect(setter.policies == [.regular])  // not yet back to accessory
        center.post(name: NSWindow.willCloseNotification, object: b)
        #expect(setter.policies == [.regular, .accessory])
    }

    @Test func same_window_visible_twice_only_increments_once() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter, windowsProvider: { [] })
        coord.start()

        let w = makeStubWindow(dockworthy: true)
        center.post(name: NSWindow.didBecomeKeyNotification, object: w)
        center.post(name: NSWindow.didBecomeKeyNotification, object: w)
        center.post(name: NSWindow.willCloseNotification, object: w)
        #expect(setter.policies == [.regular, .accessory])
    }

    private func makeStubWindow(dockworthy: Bool) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        if dockworthy {
            w.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
        }
        return w
    }
}

@MainActor
final class StubActivationSetter: ActivationPolicySetter {
    var policies: [NSApplication.ActivationPolicy] = []
    var activateCount = 0
    func setPolicy(_ p: NSApplication.ActivationPolicy) { policies.append(p) }
    func activate() { activateCount += 1 }
}
