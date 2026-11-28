// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Reader for the `AKIC` binary icon pack format shared by both the offline
// bundled fallback (`SiteIcons.bin`) and k-anonymous static CDN buckets
// (`<14-bit-sha256-prefix>.bin`).

import Foundation

public final class AKICPack: Sendable {
    private struct Entry: Sendable {
        let offset: Int
        let length: Int
    }

    private let backingData: Data
    private let dataStart: Int
    private let index: [String: Entry]

    public var count: Int { index.count }

    public convenience init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        self.init(data: data)
    }

    public init?(data: Data) {
        guard data.count >= 12 else { return nil }
        let parsed: (start: Int, index: [String: Entry])? = data.withUnsafeBytes { raw in
            guard raw.count >= 12,
                  raw[0] == 0x41, raw[1] == 0x4B, raw[2] == 0x49, raw[3] == 0x43 // "AKIC"
            else {
                return nil
            }
            let count = Int(Self.readUInt32(raw, at: 4))
            let indexLen = Int(Self.readUInt32(raw, at: 8))
            let start = 12 + indexLen
            // Every index record needs at least 2 bytes (domLen) + 8 bytes (offset + length).
            guard start >= 12, start <= raw.count, count <= indexLen / 10 else { return nil }

            var map: [String: Entry] = [:]
            map.reserveCapacity(count)
            var pos = 12
            for _ in 0..<count {
                guard pos + 2 <= start else { return nil }
                let domLen = Int(Self.readUInt16(raw, at: pos))
                pos += 2
                guard pos + domLen + 8 <= start else { return nil }
                guard let base = raw.baseAddress else { return nil }
                let slice = UnsafeBufferPointer(
                    start: base.assumingMemoryBound(to: UInt8.self).advanced(by: pos),
                    count: domLen
                )
                let domain = String(decoding: slice, as: UTF8.self)
                pos += domLen
                let offset = Int(Self.readUInt32(raw, at: pos))
                let length = Int(Self.readUInt32(raw, at: pos + 4))
                pos += 8
                guard offset >= 0, length >= 0, start + offset + length <= raw.count else { return nil }
                map[domain] = Entry(offset: offset, length: length)
            }
            guard pos == start else { return nil }
            return (start, map)
        }

        guard let parsed else { return nil }
        self.backingData = data
        self.dataStart = parsed.start
        self.index = parsed.index
    }

    public func contains(_ domain: String) -> Bool {
        index[domain] != nil
    }

    public func iconData(for domain: String) -> Data? {
        guard let entry = index[domain] else { return nil }
        let start = dataStart + entry.offset
        let end = start + entry.length
        guard start >= dataStart, end <= backingData.count else { return nil }
        return backingData.subdata(in: start..<end)
    }

    private static func readUInt16(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    private static func readUInt32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(raw[offset])
            | (UInt32(raw[offset + 1]) << 8)
            | (UInt32(raw[offset + 2]) << 16)
            | (UInt32(raw[offset + 3]) << 24)
    }
}
