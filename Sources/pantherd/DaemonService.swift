import Foundation
import PantherCore
import PantherIPC
import PantherSystem

/// The XPC front door. Only callers matching the pinned code requirement get this far
/// (NSXPCListener enforces it before `shouldAcceptNewConnection`).
final class DaemonService: NSObject, NSXPCListenerDelegate, PantherDaemonXPC, @unchecked Sendable {
    private let controller: HoldController

    @MainActor
    init(controller: HoldController) {
        self.controller = controller
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = PantherXPCInterface.make()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func handle(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        // Only valid on the XPC callback thread, so capture it before hopping to main.
        let callerUID = NSXPCConnection.current()?.effectiveUserIdentifier
        DispatchQueue.main.async {
            let data = MainActor.assumeIsolated { self.respond(to: request, callerUID: callerUID) }
            reply(data)
        }
    }

    /// A client may only tie a session to its own processes, not someone else's (or launchd's).
    @MainActor
    private func authorize(_ command: DaemonCommand, callerUID: uid_t?) throws(PantherError) {
        guard let callerUID else { throw .invalidRequest("unknown caller") }
        guard case .start(.untilExit(let pid, _, _)) = command else { return }
        guard let owner = DarwinProcessInspector.ownerUID(of: pid) else { throw .processNotFound(pid) }
        guard callerUID == 0 || owner == callerUID else {
            throw .invalidRequest("process \(pid) belongs to another user")
        }
    }

    @MainActor
    private func respond(to raw: Data, callerUID: uid_t?) -> Data {
        let reply: DaemonReply
        do {
            let request = try MessageCodec.decode(DaemonRequest.self, from: raw)
            guard request.version == PantherService.protocolVersion else {
                throw PantherError.invalidRequest("client speaks protocol \(request.version), daemon \(PantherService.protocolVersion); reinstall Panther")
            }
            try authorize(request.command, callerUID: callerUID)
            // Applied only after validation; the controller expires it (see reportExternalDisplay).
            if let display = request.context.externalDisplay { controller.reportExternalDisplay(display) }
            reply = try execute(request.command, caller: callerUID)
        } catch let error as PantherError {
            reply = DaemonReply(error: error, status: controller.status())
        } catch {
            reply = DaemonReply(error: .invalidRequest("\(error)"), status: controller.status())
        }
        return (try? MessageCodec.encode(reply)) ?? Data()
    }

    @MainActor
    private func execute(_ command: DaemonCommand, caller: uid_t?) throws(PantherError) -> DaemonReply {
        switch command {
        case .start(let request):
            let hold = try controller.start(request, owner: caller)
            return DaemonReply(hold: hold, status: controller.status())
        case let .extend(id, seconds):
            let hold = try controller.extend(id: id, by: seconds, caller: caller)
            return DaemonReply(hold: hold, status: controller.status())
        case .end(let id):
            try controller.end(id: id, caller: caller)
            return DaemonReply(status: controller.status())
        case .status:
            return DaemonReply(status: controller.status())
        }
    }
}
