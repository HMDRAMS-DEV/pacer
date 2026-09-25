import Foundation

/// Incremental reader for append-only JSONL logs.
enum JSONLines {
    /// Parses complete lines added after `offset` that contain `needle`, and returns the new offset.
    ///
    /// Lines without the needle are skipped without JSON parsing, which keeps multi-gigabyte logs cheap.
    /// A trailing line without a newline is left for the next call, since the writer may still be appending it.
    static func scan(_ url: URL, from offset: UInt64, needle: String, _ body: ([String: Any]) -> Void) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        let needleBytes = Array(needle.utf8)
        var position = offset
        var pending = Data()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            pending.append(chunk)
            let consumed = pending.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var start = 0
                while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                    let end = UnsafeRawPointer(newline) - base
                    let length = end - start
                    let matches = length > 0 && needleBytes.withUnsafeBytes {
                        memmem(base + start, length, $0.baseAddress, $0.count) != nil
                    }
                    if matches,
                       let object = try? JSONSerialization.jsonObject(with: Data(bytes: base + start, count: length)) as? [String: Any] {
                        body(object)
                    }
                    start = end + 1
                }
                return start
            }
            pending.removeSubrange(0..<consumed)
            position += UInt64(consumed)
        }
        return position
    }

    /// `.jsonl` files under `root` modified at or after `date`.
    static func files(under root: URL, modifiedSince date: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= date else { continue }
            urls.append(url)
        }
        return urls
    }

    static func size(of url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
