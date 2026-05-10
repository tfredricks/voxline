import ServiceManagement

@MainActor
protocol LoginItemBackend {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct DefaultLoginItemBackend: LoginItemBackend {
    private let service = SMAppService.mainApp
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

@MainActor
final class LoginItemService {
    enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unsupported
    }

    private let backend: LoginItemBackend

    convenience init() {
        self.init(backend: DefaultLoginItemBackend())
    }

    init(backend: LoginItemBackend) {
        self.backend = backend
    }

    var status: Status {
        switch backend.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .notFound: return .disabled
        case .requiresApproval: return .requiresApproval
        @unknown default: return .unsupported
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try backend.register()
        } else {
            try backend.unregister()
        }
    }
}
