import PiniBackendKit

extension IREmitter: PiniBackend {
    public static var identifier: String { "llvm" }
    public static var capabilities: BackendCapabilities { .full }
    public func setProgramBase(_ path: String) { programBase = path }
}
