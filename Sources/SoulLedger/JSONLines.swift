import Foundation

public let soulLedgerMaxLineBytes: Int = 32 * 1024 * 1024
public let soulLedgerWarnLineBytes: Int = 5 * 1024 * 1024

public struct JSONLineStats: Codable, Hashable, Sendable {
    public var warnedCount: Int
    public var skippedCount: Int
    public var largestLineBytes: Int

    public init(warnedCount: Int = 0, skippedCount: Int = 0, largestLineBytes: Int = 0) {
        self.warnedCount = warnedCount
        self.skippedCount = skippedCount
        self.largestLineBytes = largestLineBytes
    }
}

@discardableResult
public func enumerateJSONLines(atPath path: String, _ body: (Data) -> Void) -> JSONLineStats {
    var stats = JSONLineStats()
    guard let handle = FileHandle(forReadingAtPath: path) else { return stats }
    defer { try? handle.close() }

    let chunkSize = 1 << 20
    var buffer = Data()
    buffer.reserveCapacity(chunkSize)
    var skipUntilNewline = false

    while true {
        let chunk: Data
        do {
            guard let next = try handle.read(upToCount: chunkSize), !next.isEmpty else { break }
            chunk = next
        } catch {
            break
        }

        var start = chunk.startIndex
        while let newline = chunk[start..<chunk.endIndex].firstIndex(of: 0x0A) {
            if skipUntilNewline {
                skipUntilNewline = false
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(chunk[start..<newline])
                emitLine(buffer, into: &stats, body)
                buffer.removeAll(keepingCapacity: true)
            }
            start = chunk.index(after: newline)
        }

        guard start < chunk.endIndex else { continue }
        if skipUntilNewline { continue }
        let remaining = chunk[start..<chunk.endIndex]
        if buffer.count + remaining.count > soulLedgerMaxLineBytes {
            let oversize = buffer.count + remaining.count
            stats.skippedCount += 1
            stats.largestLineBytes = max(stats.largestLineBytes, oversize)
            buffer.removeAll(keepingCapacity: true)
            skipUntilNewline = true
        } else {
            buffer.append(remaining)
        }
    }

    if !skipUntilNewline, !buffer.isEmpty, buffer.count <= soulLedgerMaxLineBytes {
        emitLine(buffer, into: &stats, body)
    }

    return stats
}

private func emitLine(_ data: Data, into stats: inout JSONLineStats, _ body: (Data) -> Void) {
    let lineBytes = data.count
    stats.largestLineBytes = max(stats.largestLineBytes, lineBytes)
    if lineBytes > soulLedgerWarnLineBytes {
        stats.warnedCount += 1
    }
    if !data.isEmpty {
        body(data)
    }
}
