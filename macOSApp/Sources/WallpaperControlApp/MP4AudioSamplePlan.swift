import Foundation

/// Locates audio chunks from the original MP4 sample tables. The remote probe
/// downloads six small audio chunks at most, without downloading the video.
/// Table layout: https://developer.apple.com/documentation/quicktime-file-format/sample_atoms
struct MP4AudioSamplePlan {
    struct Chunk { let offset: Int64; let size: Int; let time: Range<Double> }
    let chunks: [Chunk]
    let windows: [Range<Double>]
    let complete: Bool
    static let maximumAudioBytes = 256 * 1024

    init?(movie: Data) {
        let bytes = [UInt8](movie)
        guard let root = Self.atoms(bytes, in: 0..<bytes.count)?.first, root.type == "moov",
              let tracks = Self.atoms(bytes, in: root.payload..<root.end) else { return nil }
        let audioMedia = tracks.filter { $0.type == "trak" }.compactMap { track -> Atom? in
            guard let media = Self.child("mdia", of: track, bytes: bytes),
                  let handler = Self.child("hdlr", of: media, bytes: bytes), handler.end - handler.payload >= 12,
                  String(bytes: bytes[(handler.payload + 8)..<(handler.payload + 12)], encoding: .ascii) == "soun" else { return nil }
            return media
        }
        // Multi-track files need every track checked before a silence verdict.
        guard audioMedia.count == 1, let media = audioMedia.first,
              let header = Self.child("mdhd", of: media, bytes: bytes), header.end - header.payload >= 24,
              let info = Self.child("minf", of: media, bytes: bytes),
              let table = Self.child("stbl", of: info, bytes: bytes),
              let sizes = Self.child("stsz", of: table, bytes: bytes), sizes.end - sizes.payload >= 12,
              let mapping = Self.child("stsc", of: table, bytes: bytes),
              let timing = Self.child("stts", of: table, bytes: bytes),
              let offsets = Self.child("stco", of: table, bytes: bytes) ?? Self.child("co64", of: table, bytes: bytes) else { return nil }
        let version = bytes[header.payload]
        guard version <= 1, header.end - header.payload >= (version == 1 ? 32 : 24) else { return nil }
        let timescale = Self.number(bytes, header.payload + (version == 1 ? 20 : 12), 4)
        guard timescale > 0 else { return nil }
        let sampleSize = Self.number(bytes, sizes.payload + 4, 4)
        let sampleCount = Self.number(bytes, sizes.payload + 8, 4)
        guard sampleCount > 0,
              sampleSize > 0 || sampleCount <= UInt64((sizes.end - sizes.payload - 12) / 4),
              let mapRows = Self.rows(mapping, bytes: bytes, stride: 12),
              let timeRows = Self.rows(timing, bytes: bytes, stride: 8),
              let offsetRows = Self.rows(offsets, bytes: bytes, stride: offsets.type == "co64" ? 8 : 4),
              mapRows.count > 0, timeRows.count > 0, offsetRows.count > 0 else { return nil }
        let maps = mapRows.map { (first: Self.number(bytes, $0, 4), count: Self.number(bytes, $0 + 4, 4)) }
        let times = timeRows.map { (count: Self.number(bytes, $0, 4), ticks: Self.number(bytes, $0 + 4, 4)) }
        guard maps.first?.first == 1, maps.allSatisfy({ $0.count > 0 }), times.allSatisfy({ $0.count > 0 && $0.ticks > 0 }),
              zip(maps, maps.dropFirst()).allSatisfy({ pair in pair.0.first < pair.1.first }) else { return nil }
        var all: [Chunk] = []
        var sample: UInt64 = 0, ticks: UInt64 = 0, timeRemaining = times[0].count
        var mapIndex = 0, timeIndex = 0
        for (chunkIndex, row) in offsetRows.enumerated() {
            while mapIndex + 1 < maps.count, maps[mapIndex + 1].first <= UInt64(chunkIndex + 1) { mapIndex += 1 }
            let count = maps[mapIndex].count
            guard sample <= sampleCount, count <= sampleCount - sample else { return nil }
            var size: UInt64 = 0
            if sampleSize > 0 { size = sampleSize * count } else {
                for index in sample..<(sample + count) { size += Self.number(bytes, sizes.payload + 12 + Int(index) * 4, 4) }
            }
            let start = Double(ticks) / Double(timescale)
            var remaining = count
            while remaining > 0 {
                guard timeIndex < times.count else { return nil }
                let used = min(remaining, timeRemaining)
                let (delta, multiplyOverflow) = used.multipliedReportingOverflow(by: times[timeIndex].ticks)
                let (next, addOverflow) = ticks.addingReportingOverflow(delta)
                guard !multiplyOverflow, !addOverflow else { return nil }
                ticks = next; remaining -= used; timeRemaining -= used
                if timeRemaining == 0 {
                    timeIndex += 1
                    if timeIndex < times.count { timeRemaining = times[timeIndex].count }
                }
            }
            let offset = Self.number(bytes, row, offsets.type == "co64" ? 8 : 4)
            guard offset <= UInt64(Int64.max), size > 0, size <= UInt64(Int.max), offset <= UInt64(Int64.max) - size else { return nil }
            all.append(Chunk(offset: Int64(offset), size: Int(size), time: start..<(Double(ticks) / Double(timescale))))
            sample += count
        }
        guard sample == sampleCount else { return nil }
        let groups: [Range<Int>] = all.count <= 6 ? [0..<all.count] : [0..<2, (all.count / 2 - 1)..<(all.count / 2 + 1), (all.count - 2)..<all.count]
        let selected = groups.flatMap { all[$0] }
        guard selected.allSatisfy({ $0.size <= Self.maximumAudioBytes }),
              selected.reduce(0, { $0 + $1.size }) <= Self.maximumAudioBytes else { return nil }
        chunks = selected
        windows = groups.map { all[$0.lowerBound].time.lowerBound..<all[$0.upperBound - 1].time.upperBound }
        complete = selected.count == all.count
    }

    private struct Atom { let type: String; let payload: Int; let end: Int }
    private static func child(_ type: String, of parent: Atom, bytes: [UInt8]) -> Atom? {
        atoms(bytes, in: parent.payload..<parent.end)?.first { $0.type == type }
    }
    private static func atoms(_ bytes: [UInt8], in range: Range<Int>) -> [Atom]? {
        var position = range.lowerBound
        var result: [Atom] = []
        while position < range.upperBound {
            guard range.upperBound - position >= 8 else { return nil }
            let small = number(bytes, position, 4)
            let header = small == 1 ? 16 : 8
            guard range.upperBound - position >= header else { return nil }
            let size = small == 1 ? number(bytes, position + 8, 8) : (small == 0 ? UInt64(range.upperBound - position) : small)
            guard size >= header, size <= UInt64(range.upperBound - position),
                  let type = String(bytes: bytes[(position + 4)..<(position + 8)], encoding: .ascii) else { return nil }
            let end = position + Int(size)
            result.append(Atom(type: type, payload: position + header, end: end))
            position = end
        }
        return result
    }
    private static func rows(_ atom: Atom, bytes: [UInt8], stride: Int) -> [Int]? {
        guard atom.end - atom.payload >= 8 else { return nil }
        let count = number(bytes, atom.payload + 4, 4)
        guard count > 0, count <= UInt64((atom.end - atom.payload - 8) / stride) else { return nil }
        return (0..<Int(count)).map { atom.payload + 8 + $0 * stride }
    }
    private static func number(_ bytes: [UInt8], _ start: Int, _ size: Int) -> UInt64 {
        bytes[start..<(start + size)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
