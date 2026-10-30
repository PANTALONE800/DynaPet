import Foundation
import IPCProtocol

private func fail(_ message: String = "Unexpected failure") -> Never { preconditionFailure(message) }
private func expectEqual<T: Equatable>(_ actual: T, _ expected: T) { precondition(actual == expected, "Expected \(expected), received \(actual)") }
private func expectFailure<T>(_ operation: @autoclosure () throws -> T) {
    do { _ = try operation(); fail("Expected an error") } catch {}
}

final class FramingChecks {
    let valid = "{\"version\":1,\"id\":\"r-1\",\"type\":\"request\",\"body\":{\"method\":\"echo\",\"params\":{\"text\":\"你好\"}}}"
    func testEveryByteCanBeSplitIncludingUTF8() throws {
        var framer = LineFramer(); var lines: [Data] = []
        for byte in Data((valid + "\n").utf8) {
            framer.consume(Data([byte]), line: { lines.append($0) }, fault: { _ in fail() })
        }
        expectEqual(lines.count, 1)
        expectEqual(try Message.decode(lines[0]).body["params"]?.object?["text"], .string("你好"))
    }
    func testMultipleLinesInOneRead() {
        var framer = LineFramer(); var lines: [Data] = []
        framer.consume(Data("a\nb\r\nc\n".utf8), line: { lines.append($0) }, fault: { _ in fail() })
        expectEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["a", "b", "c"])
    }
    func testOversizedLineRecoversAtNextLF() {
        var framer = LineFramer(maximumBytes: 4); var lines: [Data] = []; var faults = 0
        for chunk in ["12345", "6789\nok\n"] {
            framer.consume(Data(chunk.utf8), line: { lines.append($0) }, fault: { _ in faults += 1 })
        }
        expectEqual(faults, 1); expectEqual(lines, [Data("ok".utf8)])
    }
    func testUnterminatedLineIsNotDispatched() {
        var framer = LineFramer(); var faults = 0
        framer.consume(Data(valid.utf8), line: { _ in fail() }, fault: { _ in fail() })
        framer.finish(fault: { _ in faults += 1 })
        expectEqual(faults, 1)
    }
    func testCRLFAtExactLimit() {
        var framer = LineFramer(maximumBytes: 4); var lines: [Data] = []
        framer.consume(Data("1234\r\n".utf8), line: { lines.append($0) }, fault: { _ in fail() })
        expectEqual(lines, [Data("1234".utf8)])
    }
    func testInvalidEnvelopeAndBodyAreRejected() {
        for invalid in [valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
                        valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                        valid.replacingOccurrences(of: "\"id\":\"r-1\"", with: "\"id\":\"\""),
                        valid.replacingOccurrences(of: "\"params\":{\"text\":\"你好\"}", with: "\"params\":[]"),
                        valid.replacingOccurrences(of: "\"version\":1", with: "\"extra\":1,\"version\":1")] {
            expectFailure(try Message.decode(Data(invalid.utf8)))
        }
    }
    func testBadLineDoesNotPoisonFollowingLine() {
        var framer = LineFramer(); var accepted = 0, rejected = 0
        framer.consume(Data(("{broken\n" + valid + "\n").utf8), line: { data in
            do { _ = try Message.decode(data); accepted += 1 } catch { rejected += 1 }
        }, fault: { _ in fail() })
        expectEqual(accepted, 1); expectEqual(rejected, 1)
    }
    func testResponseAndEventRoundTrip() throws {
        let messages = [
            Message(id: "r-1", type: .response, body: ["ok": .bool(true), "result": .object([:])]),
            Message(id: "r-2", type: .response, body: ["ok": .bool(false), "error": .object(["code": .string("INVALID_PARAMS"), "message": .string("参数无效")])]),
            Message(id: "e-1", type: .event, body: ["name": .string("core.ready"), "seq": .number(1), "data": .object([:])])
        ]
        for message in messages {
            let wire = try message.encodedLine()
            let decoded = try Message.decode(wire.dropLast())
            expectEqual(decoded.type, message.type); expectEqual(decoded.body, message.body)
        }
    }
}
