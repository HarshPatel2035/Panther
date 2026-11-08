import Foundation
import PantherCore

public enum PantherService {
    /// Mach service name registered by the LaunchDaemon plist.
    public static let machName = "com.panther.daemon"
    public static let protocolVersion = 1
}

/// What clients know that the root daemon can't: whether an external display is in use
/// (that needs a login session's WindowServer connection).
public struct ClientContext: Codable, Equatable, Sendable {
    public let externalDisplay: Bool?

    public init(externalDisplay: Bool?) {
        self.externalDisplay = externalDisplay
    }
}

public enum DaemonCommand: Codable, Equatable, Sendable {
    case start(HoldRequest)
    case extend(id: UUID?, by: TimeInterval)
    case end(id: UUID?)
    case status
}

public struct DaemonRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let command: DaemonCommand
    public let context: ClientContext

    public init(_ command: DaemonCommand, context: ClientContext) {
        self.version = PantherService.protocolVersion
        self.command = command
        self.context = context
    }
}

/// Every reply carries the fresh status, so one round trip is enough for any client.
public struct DaemonReply: Codable, Equatable, Sendable {
    public let hold: Hold?
    public let error: PantherError?
    public let status: DaemonStatus?

    public init(hold: Hold? = nil, error: PantherError? = nil, status: DaemonStatus?) {
        self.hold = hold
        self.error = error
        self.status = status
    }
}

/// JSON over XPC: one `Data` in, one `Data` out. Keeps the XPC surface to a single method.
public enum MessageCodec {
    public static func encode<T: Encodable>(_ value: T) throws(PantherError) -> Data {
        do { return try JSONEncoder().encode(value) } catch {
            throw .invalidRequest("encode failed: \(error.localizedDescription)")
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(PantherError) -> T {
        guard data.count <= maxMessageBytes else { throw .invalidRequest("message too large") }
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw .invalidRequest("malformed message: \(error.localizedDescription)")
        }
    }

    /// Requests are tiny; refuse anything big before parsing it.
    public static let maxMessageBytes = 64 * 1024
}
