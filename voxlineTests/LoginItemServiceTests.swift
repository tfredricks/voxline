import Testing
import Foundation
import ServiceManagement
@testable import voxline

@Suite @MainActor struct LoginItemServiceTests {

    @Test func status_maps_enabled() {
        let svc = LoginItemService(backend: StubLoginBackend(status: .enabled))
        #expect(svc.status == .enabled)
    }

    @Test func status_maps_notRegistered_to_disabled() {
        let svc = LoginItemService(backend: StubLoginBackend(status: .notRegistered))
        #expect(svc.status == .disabled)
    }

    @Test func status_maps_notFound_to_disabled() {
        let svc = LoginItemService(backend: StubLoginBackend(status: .notFound))
        #expect(svc.status == .disabled)
    }

    @Test func status_maps_requiresApproval() {
        let svc = LoginItemService(backend: StubLoginBackend(status: .requiresApproval))
        #expect(svc.status == .requiresApproval)
    }

    @Test func setEnabled_true_calls_register_and_updates_status() throws {
        let backend = StubLoginBackend(status: .notRegistered)
        let svc = LoginItemService(backend: backend)
        try svc.setEnabled(true)
        #expect(backend.registerCount == 1)
        #expect(backend.unregisterCount == 0)
        #expect(svc.status == .enabled)
    }

    @Test func setEnabled_false_calls_unregister_and_updates_status() throws {
        let backend = StubLoginBackend(status: .enabled)
        let svc = LoginItemService(backend: backend)
        try svc.setEnabled(false)
        #expect(backend.registerCount == 0)
        #expect(backend.unregisterCount == 1)
        #expect(svc.status == .disabled)
    }

    @Test func setEnabled_true_can_yield_requires_approval() throws {
        let backend = StubLoginBackend(status: .notRegistered)
        backend.registerYields = .requiresApproval
        let svc = LoginItemService(backend: backend)
        try svc.setEnabled(true)
        #expect(svc.status == .requiresApproval)
    }
}

@MainActor
final class StubLoginBackend: LoginItemBackend {
    var status: SMAppService.Status
    var registerYields: SMAppService.Status?
    var registerCount = 0
    var unregisterCount = 0

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registerCount += 1
        status = registerYields ?? .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }
}
