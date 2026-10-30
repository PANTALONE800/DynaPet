import Foundation
import Dispatch
import CSystem
import IPCProtocol

public final class LineReader {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "ipc.stdin.reader")
    public init(handle: FileHandle) { self.handle = handle }
    public func start(onMessage: @escaping (Message) -> Void, onFault: @escaping (String) -> Void, onEOF: @escaping () -> Void) {
        queue.async { [handle] in
            dispatchPrecondition(condition: .notOnQueue(.main))
            var framer = LineFramer()
            func fault(_ error: LineFramer.Fault) {
                onFault(error == .oversized ? "LINE_TOO_LARGE" : "INCOMPLETE_LINE_AT_EOF")
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBufferPointer {
                    ipc_read_some(handle.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count == 0 { break }
                if count < 0 { onFault("INPUT_READ_FAILED"); break }
                framer.consume(Data(buffer.prefix(Int(count))), line: { data in
                    do { onMessage(try Message.decode(data)) }
                    catch { onFault("INVALID_JSON_OR_MESSAGE") }
                }, fault: fault)
            }
            framer.finish(fault: fault)
            onEOF()
        }
    }
}

/// Writes are ordered on a dedicated queue; callers never block on stdout.
public final class LineWriter {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "ipc.stdout.writer")
    private let lock = NSLock()
    private var buffered = 0
    private var failed = false
    public var onFault: ((String) -> Void)?
    public init(handle: FileHandle) { self.handle = handle }
    @discardableResult public func send(_ message: Message) -> Bool {
        let data: Data
        do { data = try message.encodedLine() }
        catch { onFault?("OUTPUT_MESSAGE_INVALID"); return false }
        lock.lock()
        guard !failed, buffered + data.count <= 524_288 else {
            lock.unlock(); onFault?("OUTPUT_QUEUE_FULL_OR_CLOSED"); return false
        }
        buffered += data.count
        lock.unlock()
        queue.async { [self] in
            lock.lock(); let shouldWrite = !failed; lock.unlock()
            var errorCode: String?
            if shouldWrite {
                do { try handle.write(contentsOf: data) }
                catch { lock.lock(); failed = true; lock.unlock(); errorCode = "OUTPUT_WRITE_FAILED" }
            }
            lock.lock(); buffered -= data.count; lock.unlock()
            if let errorCode { onFault?(errorCode) }
        }
        return true
    }
    /// Shutdown flush is bounded even if the peer stops consuming its pipe.
    public func flush(timeout: DispatchTimeInterval = .milliseconds(300)) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
}
