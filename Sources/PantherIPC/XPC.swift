import Foundation
import PantherCore

@objc public protocol PantherDaemonXPC {
    func handle(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

public enum PantherXPCInterface {
    public static func make() -> NSXPCInterface { NSXPCInterface(with: PantherDaemonXPC.self) }
}

/// Synchronous client for the CLI. Each call opens a privileged Mach connection, sends one
/// request, and waits (bounded) for the reply.
public struct PantherClient: Sendable {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func send(_ command: DaemonCommand, context: ClientContext) throws(PantherError) -> DaemonReply {
        let payload = try MessageCodec.encode(DaemonRequest(command, context: context))
        let connection = NSXPCConnection(machServiceName: PantherService.machName, options: .privileged)
        connection.remoteObjectInterface = PantherXPCInterface.make()
        connection.resume()
        defer { connection.invalidate() }

        let box = ReplyBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            box.fail(error.localizedDescription)
        } as? PantherDaemonXPC
        guard let proxy else { throw .daemonUnavailable("no proxy") }
        proxy.handle(payload) { data in box.succeed(data) }

        guard box.wait(timeout: timeout) else { throw .daemonUnavailable("no reply within \(Int(timeout)) s") }
        switch box.result {
        case .success(let data)?: return try MessageCodec.decode(DaemonReply.self, from: data)
        case .failure(let message)?: throw .daemonUnavailable(message)
        case nil: throw .daemonUnavailable("no reply")
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    enum Outcome { case success(Data), failure(String) }
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: Outcome?

    func succeed(_ data: Data) { finish(.success(data)) }
    func fail(_ message: String) { finish(.failure(message)) }

    private func finish(_ value: Outcome) {
        let first: Bool = lock.withLock {
            guard outcome == nil else { return false }
            outcome = value
            return true
        }
        if first { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Bool { semaphore.wait(timeout: .now() + timeout) == .success }
    var result: Outcome? { lock.withLock { outcome } }
}
