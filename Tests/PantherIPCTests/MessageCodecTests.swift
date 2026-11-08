import Foundation
import Testing
@testable import PantherCore
@testable import PantherIPC

@Suite("IPC messages")
struct MessageCodecTests {
    @Test("Every command survives a round trip", arguments: [
        DaemonCommand.start(.timed(duration: 600, label: "t")),
        DaemonCommand.start(.untilExit(pid: 42, cap: 3_600, label: "python train.py")),
        DaemonCommand.start(.untilExit(pid: 42, cap: nil, label: "job")),
        DaemonCommand.extend(id: UUID(), by: 900),
        DaemonCommand.extend(id: nil, by: 900),
        DaemonCommand.end(id: nil),
        DaemonCommand.status,
    ])
    func roundTrip(command: DaemonCommand) throws {
        let request = DaemonRequest(command, context: ClientContext(externalDisplay: true))
        let decoded = try MessageCodec.decode(DaemonRequest.self, from: MessageCodec.encode(request))
        #expect(decoded == request)
        #expect(decoded.version == PantherService.protocolVersion)
    }

    @Test("Errors cross the wire intact")
    func errorRoundTrip() throws {
        let reply = DaemonReply(error: .readBackMismatch(expected: true, actual: nil), status: nil)
        #expect(try MessageCodec.decode(DaemonReply.self, from: MessageCodec.encode(reply)) == reply)
    }

    @Test("Garbage and oversized messages are rejected before use")
    func rejectsBadInput() {
        #expect(throws: PantherError.self) { try MessageCodec.decode(DaemonRequest.self, from: Data("{".utf8)) }
        let huge = Data(repeating: 0x20, count: MessageCodec.maxMessageBytes + 1)
        #expect(throws: PantherError.invalidRequest("message too large")) {
            try MessageCodec.decode(DaemonRequest.self, from: huge)
        }
    }
}
