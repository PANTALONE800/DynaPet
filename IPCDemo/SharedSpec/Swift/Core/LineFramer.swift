import Foundation

/// Incremental byte framing preserves UTF-8 sequences across read boundaries.
/// Oversized lines are discarded through their next LF, using bounded memory.
public struct LineFramer {
    public enum Fault { case oversized, incompleteAtEOF }
    private let maximumBytes: Int
    private var bytes = Data()
    private var dropping = false
    public init(maximumBytes: Int = Message.maximumBytes) { self.maximumBytes = maximumBytes }
    public mutating func consume(_ chunk: Data, line: (Data) -> Void, fault: (Fault) -> Void) {
        for byte in chunk {
            if byte == 10 {
                if !dropping {
                    if bytes.last == 13 { bytes.removeLast() }
                    line(bytes)
                }
                bytes.removeAll(keepingCapacity: true); dropping = false
            } else if !dropping {
                bytes.append(byte)
                // A final CR may precede LF without counting against JSON size.
                if bytes.count > maximumBytes && !(bytes.count == maximumBytes + 1 && byte == 13) {
                    bytes.removeAll(keepingCapacity: true); dropping = true; fault(.oversized)
                }
            }
        }
    }
    public mutating func finish(fault: (Fault) -> Void) {
        if !bytes.isEmpty && !dropping { fault(.incompleteAtEOF) }
        bytes.removeAll(); dropping = false
    }
}
