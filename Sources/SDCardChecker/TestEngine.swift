import Foundation
import Darwin

enum EngineError: Error, LocalizedError {
    case cancelled
    case setup(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Cancelled"
        case .setup(let m): m
        }
    }
}

struct EngineOptions: Sendable {
    var quickTestBytes: Int64
    var deleteTestFiles: Bool
}

private func posixMessage(_ e: Int32) -> String { String(cString: strerror(e)) }

@inline(__always) private func mix64(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// Every 8-byte word depends on its absolute position in the test area, so data that
/// lands at the wrong address (typical of fake-capacity cards) is detected, not just lost data.
private func fillPattern(_ buf: UnsafeMutableRawPointer, count: Int, globalOffset: Int64, seed: UInt64) {
    let words = (count + 7) / 8
    let p = buf.assumingMemoryBound(to: UInt64.self)
    let base = UInt64(globalOffset) / 8
    for i in 0..<words { p[i] = mix64((base &+ UInt64(i)) ^ seed) }
}

/// Runs one test synchronously on a background thread. Not thread-safe; one instance per run.
final class TestEngine {
    static let testFolderName = "SDCardChecker-Test"
    private static let MB: Int64 = 1_048_576

    private let volumePath: String
    private let volumeName: String
    private let volumeID: String
    private let wholeDiskBSD: String?
    private let options: EngineOptions
    private let cancel: CancelFlag
    private let onProgress: (ProgressUpdate) -> Void
    private let onSample: (SpeedSample) -> Void

    private let chunk = 4 << 20
    private let seed = UInt64.random(in: 1...UInt64.max)
    private let writeBuf: UnsafeMutableRawPointer
    private let readBuf: UnsafeMutableRawPointer
    private let expectBuf: UnsafeMutableRawPointer

    // Progress bookkeeping
    private var testStart = Date()
    private var phase = ""
    private var series: String?
    private var totalWork: Int64 = 1
    private var doneWork: Int64 = 0
    private var phaseBase: Int64 = 0
    private var phaseTotal: Int64 = 0
    private var detailOverride: String?
    private var lastEmit = Date.distantPast
    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private var currentSpeed: Double?
    private var surface: [UInt8]?

    private var testDir: String { (volumePath as NSString).appendingPathComponent(Self.testFolderName) }

    init(volume: CardVolume, options: EngineOptions, cancel: CancelFlag,
         onProgress: @escaping (ProgressUpdate) -> Void, onSample: @escaping (SpeedSample) -> Void) {
        volumePath = volume.url.path
        volumeName = volume.name
        volumeID = volume.id
        wholeDiskBSD = volume.wholeDiskBSD
        self.options = options
        self.cancel = cancel
        self.onProgress = onProgress
        self.onSample = onSample
        func alloc() -> UnsafeMutableRawPointer {
            let p = UnsafeMutableRawPointer.allocate(byteCount: 4 << 20, alignment: 4096)
            p.bindMemory(to: UInt64.self, capacity: (4 << 20) / 8)
            return p
        }
        writeBuf = alloc(); readBuf = alloc(); expectBuf = alloc()
    }

    deinit {
        writeBuf.deallocate(); readBuf.deallocate(); expectBuf.deallocate()
    }

    func run(_ kind: TestKind) -> TestResult {
        testStart = Date()
        do {
            switch kind {
            case .quickSpeed: return try runSpeedTest()
            case .fullIntegrity: return try runFullTest()
            case .surfaceScan: return try runSurfaceScan()
            case .readScan: return try runReadScan()
            }
        } catch EngineError.cancelled {
            if kind.writesToCard { removeTestDir() }
            return result(kind, .cancelled, "Test cancelled",
                          notes: kind.writesToCard ? ["Temporary test files were removed from the card."] : [])
        } catch {
            if kind.writesToCard { removeTestDir() }
            return result(kind, .error, "The test could not run", notes: [error.localizedDescription])
        }
    }

    // MARK: - Speed test

    private func runSpeedTest() throws -> TestResult {
        try prepareTestDir()
        defer { removeTestDir() }

        let free = freeBytes()
        let size = min(options.quickTestBytes, free - 64 * Self.MB) / Self.MB * Self.MB
        guard size >= 32 * Self.MB else {
            throw EngineError.setup("Not enough free space. The speed test needs about 100 MB free; \(Fmt.bytes(free)) is available.")
        }
        let path = testDir + "/speedtest.sdtest"
        let randomSeconds = 5.0
        let randomWeight = size / 5
        totalWork = size * 2 + randomWeight * 2

        beginPhase("Writing test data", series: "Write", total: size)
        let t0 = Date()
        let (written, stop) = try writePattern(path: path, size: size, globalBase: 0)
        let writeTime = Date().timeIntervalSince(t0)
        if let stop {
            return result(.quickSpeed, .fail, "Writing to the card failed", notes: [stopMessage(stop)])
        }
        let writeMBps = Double(written) / writeTime / 1e6

        beginPhase("Reading back & verifying", series: "Read", total: written)
        var stats = VerifyStats()
        let t1 = Date()
        try verifyPattern(path: path, size: written, globalBase: 0, stats: &stats)
        let readMBps = Double(written) / Date().timeIntervalSince(t1) / 1e6

        beginPhase("Random 4K reads", series: nil, total: randomWeight)
        let readIOPS = try randomIO(path: path, fileSize: written, write: false, seconds: randomSeconds, weight: randomWeight)
        beginPhase("Random 4K writes", series: nil, total: randomWeight)
        let writeIOPS = try randomIO(path: path, fileSize: written, write: true, seconds: randomSeconds, weight: randomWeight)

        let metrics = [
            Metric(label: "Sequential write", value: Fmt.speed(writeMBps)),
            Metric(label: "Sequential read", value: Fmt.speed(readMBps)),
            Metric(label: "Random 4K read", value: String(format: "%.0f IOPS (%.1f MB/s)", readIOPS, readIOPS * 4096 / 1e6)),
            Metric(label: "Random 4K write", value: String(format: "%.0f IOPS (%.1f MB/s)", writeIOPS, writeIOPS * 4096 / 1e6)),
            Metric(label: "Speed class (est.)", value: Fmt.speedClass(writeMBps: writeMBps)),
            Metric(label: "App class (est.)", value: Fmt.appClass(readIOPS: readIOPS, writeIOPS: writeIOPS)),
            Metric(label: "Data verified", value: stats.isClean ? "\(Fmt.bytes(written)), no errors" : "\(stats.badSectors) bad sectors"),
            Metric(label: "Test size", value: Fmt.bytes(written)),
        ]
        var notes = [
            "Speeds can be limited by the card reader, USB port or hub, not just the card.",
            "Class ratings are estimates. Official ratings are based on the minimum sustained write speed, so run the full test for a better measure.",
        ]
        let verdict: Verdict
        let headline: String
        if !stats.isClean {
            verdict = .fail
            headline = "Data read back from the card did not match what was written"
            notes.insert("\(stats.badSectors) sectors were corrupted and \(stats.readErrors) read errors occurred. This card is unreliable.", at: 0)
        } else if writeMBps < 2 {
            verdict = .warning
            headline = "Data is intact, but the card is very slow (\(Fmt.speed(writeMBps)) write)"
        } else {
            verdict = .pass
            headline = "Data verified. Write \(Fmt.speed(writeMBps)), read \(Fmt.speed(readMBps))"
        }
        return result(.quickSpeed, verdict, headline, metrics: metrics, notes: notes)
    }

    private func randomIO(path: String, fileSize: Int64, write: Bool, seconds: Double, weight: Int64) throws -> Double {
        let fd = open(path, write ? O_WRONLY : O_RDONLY)
        guard fd >= 0 else { advance(weight, measured: false); return 0 }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let blocks = max(1, fileSize / 4096)
        let start = Date()
        var ops = 0
        var credited: Int64 = 0
        while true {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= seconds { break }
            try checkCancel()
            let offset = off_t(Int64.random(in: 0..<blocks) * 4096)
            let r = write ? pwrite(fd, writeBuf, 4096, offset) : pread(fd, readBuf, 4096, offset)
            if r != 4096 { break }
            ops += 1
            if ops % 32 == 0, elapsed > 0 {
                detailOverride = String(format: "%.0f IOPS", Double(ops) / elapsed)
                let target = Int64(Double(weight) * min(1, elapsed / seconds))
                advance(target - credited, measured: false)
                credited = target
            }
        }
        if write, fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
        let total = Date().timeIntervalSince(start)
        advance(weight - credited, measured: false)
        return total > 0 ? Double(ops) / total : 0
    }

    // MARK: - Full capacity & integrity test

    private func runFullTest() throws -> TestResult {
        try prepareTestDir()
        let free = freeBytes()
        let target = (free - 16 * Self.MB) / Self.MB * Self.MB
        guard target >= 64 * Self.MB else {
            throw EngineError.setup("Not enough free space to test (\(Fmt.bytes(free)) available). Free up some space and try again.")
        }
        let fileSize = 1024 * Self.MB   // stays under FAT32's 4 GB file limit
        totalWork = target * 2

        var files: [(path: String, size: Int64, base: Int64)] = []
        var stopReason: Stop?

        beginPhase("Filling free space with test data", series: "Write", total: target)
        let t0 = Date()
        var remaining = target
        var index = 0
        while remaining > 0 {
            let size = min(fileSize, remaining)
            let path = testDir + String(format: "/%04d.sdtest", index + 1)
            let base = Int64(index) * fileSize
            let (w, stop) = try writePattern(path: path, size: size, globalBase: base)
            if w > 0 { files.append((path, w, base)) }
            if let stop { stopReason = stop; break }
            remaining -= size
            index += 1
        }
        let writeTime = Date().timeIntervalSince(t0)
        let written = files.reduce(0) { $0 + $1.size }

        totalWork = doneWork + written
        beginPhase("Verifying test data", series: "Read", total: written)
        var stats = VerifyStats()
        let t1 = Date()
        for f in files {
            try verifyPattern(path: f.path, size: f.size, globalBase: f.base, stats: &stats)
        }
        let readTime = Date().timeIntervalSince(t1)
        if options.deleteTestFiles { removeTestDir() }

        let writeMBps = writeTime > 0 ? Double(written) / writeTime / 1e6 : 0
        let readMBps = readTime > 0 ? Double(written) / readTime / 1e6 : 0
        let badBytes = stats.badSectors * 512 + stats.missing
        let goodBytes = max(0, written - badBytes)

        var metrics = [
            Metric(label: "Free space tested", value: Fmt.bytes(written)),
            Metric(label: "Verified OK", value: Fmt.bytes(goodBytes)),
            Metric(label: "Corrupted", value: badBytes == 0 ? "None" : "\(Fmt.bytes(badBytes)) (\(stats.badSectors) sectors)"),
            Metric(label: "Read errors", value: "\(stats.readErrors)"),
            Metric(label: "Avg write speed", value: Fmt.speed(writeMBps)),
            Metric(label: "Avg read speed", value: Fmt.speed(readMBps)),
            Metric(label: "Speed class (est.)", value: Fmt.speedClass(writeMBps: writeMBps)),
            Metric(label: "Duration", value: Fmt.duration(Date().timeIntervalSince(testStart))),
        ]
        var notes: [String] = []
        var verdict: Verdict = .pass
        var headline = "No errors. All \(Fmt.bytes(written)) of free space stores data correctly."

        if let stopReason {
            switch stopReason {
            case .diskFull:
                if Double(written) < Double(target) * 0.98 {
                    verdict = .fail
                    headline = "The card filled up early. It may hold less than it reports."
                    notes.append("The card reported \(Fmt.bytes(free)) free but accepted only \(Fmt.bytes(written)).")
                }
            case .ioError(let msg):
                verdict = .fail
                headline = "The card returned a write error"
                notes.append(msg)
            }
        }
        if !stats.isClean {
            verdict = .fail
            headline = "Data corruption detected: \(Fmt.bytes(badBytes)) failed verification"
            if let first = stats.firstBad {
                let used = Int64(max(0, (try? URL(fileURLWithPath: volumePath)
                    .resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity) ?? 0)) - free
                metrics.insert(Metric(label: "First error at", value: "\(Fmt.bytes(first)) into free space"), at: 3)
                notes.append("Data written before the first error was stored correctly.")
                if Double(badBytes) / Double(max(written, 1)) > 0.05, let last = stats.lastBad, last > written * 9 / 10 {
                    notes.append("Errors run from \(Fmt.bytes(first)) to the end of the card. This pattern is typical of a counterfeit card whose real capacity is about \(Fmt.bytes(max(0, used) + first)).")
                } else {
                    notes.append("Scattered errors like these usually mean the flash memory is wearing out. Back up your data and replace the card.")
                }
            }
        }
        if stats.readErrors > 0 {
            notes.append("\(stats.readErrors) read operations failed with an I/O error.")
        }
        notes.append(options.deleteTestFiles
            ? "Test files were removed. Your existing files were not touched."
            : "Test files were kept in the \(Self.testFolderName) folder on the card.")
        notes.append("To catch cards that cache data, eject and reinsert the card, then run the test again.")
        return result(.fullIntegrity, verdict, headline, metrics: metrics, notes: notes)
    }

    // MARK: - Surface scan

    private func runSurfaceScan() throws -> TestResult {
        guard let bsd = wholeDiskBSD else { throw EngineError.setup("Couldn't identify the card's device.") }
        let devicePath = "/dev/r" + bsd
        beginPhase("Waiting for administrator approval…", series: nil, total: 0)
        let fd = try RawDevice.openReadOnly(devicePath)
        defer { close(fd) }
        guard let (blockSize, total) = RawDevice.geometry(fd) else {
            throw EngineError.setup("Couldn't read the size of \(devicePath).")
        }
        try checkCancel()

        let sectorsTotal = total / blockSize
        var map = [UInt8](repeating: SurfaceCell.unread, count: SurfaceCell.count)
        func mark(_ offset: Int64, _ length: Int64, _ state: UInt8) {
            let first = Int(offset * Int64(SurfaceCell.count) / total)
            let last = Int((offset + length - 1) * Int64(SurfaceCell.count) / total)
            for i in first...min(last, SurfaceCell.count - 1) where map[i] < state { map[i] = state }
            surface = map
        }

        totalWork = total
        doneWork = 0
        surface = map
        beginPhase("Reading every sector", series: "Read", total: total)

        let pinpointLimit: Int64 = 2000      // past this, stop retrying sector by sector (a dying card can take seconds per sector)
        var badSectors: [Int64] = []         // LBAs, capped for the report
        var badCount: Int64 = 0
        var slowRegions = 0
        var slowBytes: Int64 = 0
        var typicalSpeed: Double?
        var goodChunks = 0
        var slowest = Double.infinity
        let t0 = Date()
        var pos: Int64 = 0

        while pos < total {
            try checkCancel()
            let n = Int(min(Int64(chunk), total - pos))
            let started = Date()
            let (got, err) = preadFully(fd, readBuf, n, pos)
            let dt = Date().timeIntervalSince(started)

            if err != 0 || got < n {
                var found: [Int64]
                if badCount < pinpointLimit {
                    detailOverride = "Read error near \(Fmt.bytes(pos)), checking sector by sector…"
                    emit(force: true)
                    found = try pinpointBadSectors(fd, from: pos, length: n, blockSize: blockSize)
                    detailOverride = nil
                } else {
                    found = stride(from: pos / blockSize, to: (pos + Int64(n)) / blockSize, by: 1).map { $0 }
                }
                badCount += Int64(found.count)
                if badSectors.count < 500 { badSectors += found.prefix(500 - badSectors.count) }
                mark(pos, Int64(n), found.isEmpty ? SurfaceCell.slow : SurfaceCell.ok)
                for lba in found { mark(lba * blockSize, blockSize, SurfaceCell.bad) }
                if found.isEmpty { slowRegions += 1; slowBytes += Int64(n) }  // failed once, then read fine on retry
            } else {
                let speed = Double(n) / max(dt, 1e-6) / 1e6
                goodChunks += 1
                if let typical = typicalSpeed, goodChunks > 8, speed < typical * 0.25, dt > 0.3 {
                    slowRegions += 1
                    slowBytes += Int64(n)
                    mark(pos, Int64(n), SurfaceCell.slow)
                } else {
                    typicalSpeed = typicalSpeed.map { $0 * 0.9 + speed * 0.1 } ?? speed
                    mark(pos, Int64(n), SurfaceCell.ok)
                }
                if goodChunks > 2 { slowest = min(slowest, speed) }
            }
            pos += Int64(n)
            advance(Int64(n))
        }

        let elapsed = Date().timeIntervalSince(t0)
        var metrics = [
            Metric(label: "Device", value: "/dev/\(bsd) · \(Fmt.bytes(total))"),
            Metric(label: "Sectors scanned", value: "\(sectorsTotal.formatted()) × \(blockSize) bytes"),
            Metric(label: "Unreadable sectors", value: badCount == 0 ? "None" : "\(badCount.formatted()) (\(Fmt.bytes(badCount * blockSize)))"),
            Metric(label: "Slow areas", value: slowRegions == 0 ? "None" : "\(slowRegions) (\(Fmt.bytes(slowBytes)))"),
            Metric(label: "Avg read speed", value: Fmt.speed(Double(total) / max(elapsed, 1e-6) / 1e6)),
            Metric(label: "Duration", value: Fmt.duration(Date().timeIntervalSince(testStart))),
        ]
        if slowest.isFinite { metrics.insert(Metric(label: "Slowest read", value: Fmt.speed(slowest)), at: 5) }

        var notes: [String] = []
        let verdict: Verdict
        let headline: String
        if badCount > 0 {
            verdict = .fail
            headline = "\(badCount.formatted()) unreadable \(badCount == 1 ? "sector" : "sectors") found"
            // Group consecutive LBAs into ranges.
            var ranges: [(Int64, Int64)] = []
            for lba in badSectors {
                if let last = ranges.last, lba == last.1 + 1 { ranges[ranges.count - 1].1 = lba } else { ranges.append((lba, lba)) }
            }
            for (a, b) in ranges.prefix(12) {
                notes.append(a == b
                    ? "Bad sector \(a.formatted()) (at \(Fmt.bytes(a * blockSize)))"
                    : "Bad sectors \(a.formatted())–\(b.formatted()) (\(Fmt.bytes((b - a + 1) * blockSize)) at \(Fmt.bytes(a * blockSize)))")
            }
            if ranges.count > 12 || badCount > Int64(badSectors.count) { notes.append("…plus more bad sectors elsewhere on the card.") }
            if badCount >= pinpointLimit { notes.append("Errors were so frequent that the scan stopped checking each sector one at a time. Counts after that point are by 4 MB region.") }
            notes.append("The card's controller has run out of spare blocks to swap in. Copy off anything important now and stop using this card. Run the Read Scan to see which files are affected.")
        } else if slowRegions > 0 && Double(slowBytes) / Double(total) > 0.01 {
            verdict = .warning
            headline = "Every sector is readable, but \(slowRegions) areas were unusually slow"
            notes.append("Slow areas often mean weak flash that the card is struggling to read. Keep a backup, and rescan later to see if it gets worse.")
        } else {
            verdict = .pass
            headline = "All \(sectorsTotal.formatted()) sectors (\(Fmt.bytes(total))) are readable"
        }
        notes.append("Read-only scan. Nothing on the card was changed.")
        notes.append("A readable sector can still hold wrong data. Run the full capacity test to check the card stores data correctly.")
        var r = result(.surfaceScan, verdict, headline, metrics: metrics, notes: notes)
        r.surfaceMap = map
        return r
    }

    /// Re-reads a failed region in 64 KB pieces, then sector by sector inside any piece that fails.
    private func pinpointBadSectors(_ fd: Int32, from start: Int64, length: Int, blockSize: Int64) throws -> [Int64] {
        var bad: [Int64] = []
        let piece = 64 * 1024
        let bs = Int(blockSize)
        var off = 0
        while off < length {
            try checkCancel()
            let n = min(piece, length - off)
            let (got, err) = preadFully(fd, readBuf, n, start + Int64(off))
            if err != 0 || got < n {
                var s = 0
                while s < n {
                    try checkCancel()
                    let (g, e) = preadFully(fd, readBuf, bs, start + Int64(off + s))
                    if e != 0 || g < bs { bad.append((start + Int64(off + s)) / blockSize) }
                    s += bs
                }
            }
            off += n
        }
        return bad
    }

    // MARK: - Read scan

    private func runReadScan() throws -> TestResult {
        beginPhase("Finding files", series: nil, total: 0)
        let root = URL(fileURLWithPath: volumePath)
        let skip: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100", Self.testFolderName]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationErrors = 0
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in enumerationErrors += 1; return true })
        else { throw EngineError.setup("Couldn't list the files on the card.") }

        var files: [(url: URL, size: Int64)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            try checkCancel()
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let size = Int64(v.fileSize ?? 0)
            files.append((url, size))
            total += size
            if files.count % 200 == 0 { detailOverride = "\(files.count) files found"; emit(force: false) }
        }

        totalWork = max(total, 1)
        doneWork = 0
        beginPhase("Reading files", series: "Read", total: total)
        var ioFailures: [String] = []
        var accessFailures: [String] = []
        let t0 = Date()
        for f in files {
            try checkCancel()
            let rel = String(f.url.path.dropFirst(volumePath.count))
            switch try readEntireFile(path: f.url.path, size: f.size) {
            case nil: break
            case .some(let e) where e == EACCES || e == EPERM: accessFailures.append(rel)
            case .some(let e): ioFailures.append("\(rel) — \(posixMessage(e))")
            }
        }
        let elapsed = Date().timeIntervalSince(t0)

        var metrics = [
            Metric(label: "Files scanned", value: "\(files.count)"),
            Metric(label: "Data read", value: Fmt.bytes(total)),
            Metric(label: "Unreadable files", value: "\(ioFailures.count)"),
            Metric(label: "Avg read speed", value: elapsed > 0 && total >= 10_000_000 ? Fmt.speed(Double(total) / elapsed / 1e6) : "—"),
            Metric(label: "Duration", value: Fmt.duration(Date().timeIntervalSince(testStart))),
        ]
        if !accessFailures.isEmpty { metrics.append(Metric(label: "Permission denied", value: "\(accessFailures.count) files")) }

        var notes: [String] = []
        let verdict: Verdict
        let headline: String
        if !ioFailures.isEmpty {
            verdict = .fail
            headline = "\(ioFailures.count) files could not be read because of I/O errors"
            notes += ioFailures.prefix(15).map { "Unreadable: \($0)" }
            if ioFailures.count > 15 { notes.append("…and \(ioFailures.count - 15) more.") }
            notes.append("Copy what you can off the card now and replace it.")
        } else if !accessFailures.isEmpty || enumerationErrors > 0 {
            verdict = .warning
            headline = "No read errors, but some files or folders couldn't be opened"
            notes.append("Usually a permissions issue, not a card fault. Allow access in System Settings › Privacy & Security › Files & Folders.")
        } else if files.isEmpty {
            verdict = .pass
            headline = "The card has no files to scan"
        } else {
            verdict = .pass
            headline = "All \(files.count) \(files.count == 1 ? "file" : "files") (\(Fmt.bytes(total))) read without errors"
        }
        notes.append("This scan finds unreadable areas. It can't detect files that were silently corrupted earlier.")
        return result(.readScan, verdict, headline, metrics: metrics, notes: notes)
    }

    /// Returns nil on success, otherwise the errno that stopped the read.
    private func readEntireFile(path: String, size: Int64) throws -> Int32? {
        let fd = open(path, O_RDONLY)
        if fd < 0 { let e = errno; advance(size, measured: false); return e }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var pos: Int64 = 0
        while pos < size {
            try checkCancel()
            let n = Int(min(Int64(chunk), size - pos))
            let (got, err) = preadFully(fd, readBuf, n, pos)
            if err != 0 { advance(size - pos, measured: false); return err }
            pos += Int64(n)
            advance(Int64(n))
            if got < n { advance(size - pos, measured: false); break }   // file shrank while reading
        }
        return nil
    }

    // MARK: - Pattern I/O

    private enum Stop: Equatable { case diskFull, ioError(String) }

    private func stopMessage(_ s: Stop) -> String {
        switch s {
        case .diskFull: "The card ran out of space."
        case .ioError(let m): m
        }
    }

    private func writePattern(path: String, size: Int64, globalBase: Int64) throws -> (Int64, Stop?) {
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        if fd < 0 {
            let e = errno
            return (0, e == ENOSPC ? .diskFull : .ioError("Couldn't create a test file: \(posixMessage(e))"))
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var written: Int64 = 0
        while written < size {
            try checkCancel()
            let n = Int(min(Int64(chunk), size - written))
            fillPattern(writeBuf, count: n, globalOffset: globalBase + written, seed: seed)
            var off = 0
            while off < n {
                let r = Darwin.write(fd, writeBuf + off, n - off)
                if r < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    written += Int64(off)
                    _ = fcntl(fd, F_FULLFSYNC)
                    return (written, e == ENOSPC ? .diskFull
                            : .ioError("Write error at \(Fmt.bytes(globalBase + written)): \(posixMessage(e))"))
                }
                off += r
            }
            written += Int64(n)
            advance(Int64(n))
        }
        if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
        return (written, nil)
    }

    private struct VerifyStats {
        var badSectors: Int64 = 0
        var firstBad: Int64?
        var lastBad: Int64?
        var readErrors = 0
        var missing: Int64 = 0
        var isClean: Bool { badSectors == 0 && readErrors == 0 && missing == 0 }

        mutating func markBad(_ offset: Int64) {
            badSectors += 1
            if firstBad == nil { firstBad = offset }
            lastBad = offset
        }
    }

    private func verifyPattern(path: String, size: Int64, globalBase: Int64, stats: inout VerifyStats) throws {
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            stats.readErrors += 1
            stats.missing += size
            advance(size, measured: false)
            return
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var pos: Int64 = 0
        while pos < size {
            try checkCancel()
            let n = Int(min(Int64(chunk), size - pos))
            let (got, err) = preadFully(fd, readBuf, n, pos)
            fillPattern(expectBuf, count: n, globalOffset: globalBase + pos, seed: seed)
            if got > 0, memcmp(readBuf, expectBuf, got) != 0 {
                var s = 0
                while s < got {
                    if memcmp(readBuf + s, expectBuf + s, min(512, got - s)) != 0 { stats.markBad(globalBase + pos + Int64(s)) }
                    s += 512
                }
            }
            if err != 0 {
                // Unreadable region: count the rest of this chunk as bad and carry on.
                stats.readErrors += 1
                var s = got
                while s < n { stats.markBad(globalBase + pos + Int64(s)); s += 512 }
            } else if got < n {
                let missing = size - pos - Int64(got)
                stats.missing += missing
                advance(size - pos, measured: false)
                return
            }
            pos += Int64(n)
            advance(Int64(n))
        }
    }

    private func preadFully(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int, _ offset: Int64) -> (Int, Int32) {
        var got = 0
        while got < n {
            let r = pread(fd, buf + got, n - got, off_t(offset) + off_t(got))
            if r < 0 {
                let e = errno
                if e == EINTR { continue }
                return (got, e)
            }
            if r == 0 { break }
            got += r
        }
        return (got, 0)
    }

    // MARK: - Helpers

    private func prepareTestDir() throws {
        if mkdir(testDir, 0o755) != 0 && errno != EEXIST {
            let e = errno
            let hint = (e == EROFS || e == EACCES || e == EPERM) ? " The card may be write-protected, or the app needs permission to access removable volumes." : ""
            throw EngineError.setup("Couldn't write to the card: \(posixMessage(e)).\(hint)")
        }
    }

    private func removeTestDir() {
        try? FileManager.default.removeItem(atPath: testDir)
    }

    private func freeBytes() -> Int64 {
        var s = statfs()
        guard statfs(volumePath, &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }

    private func checkCancel() throws {
        if cancel.isCancelled { throw EngineError.cancelled }
    }

    private func result(_ kind: TestKind, _ verdict: Verdict, _ headline: String,
                        metrics: [Metric] = [], notes: [String] = []) -> TestResult {
        TestResult(kind: kind, volumeID: volumeID, volumeName: volumeName, verdict: verdict,
                   headline: headline, metrics: metrics, notes: notes)
    }

    private func beginPhase(_ name: String, series: String?, total: Int64) {
        phase = name
        self.series = series
        phaseBase = doneWork
        phaseTotal = total
        detailOverride = nil
        windowStart = Date()
        windowBytes = 0
        currentSpeed = nil
        emit(force: true)
    }

    private func advance(_ bytes: Int64, measured: Bool = true) {
        guard bytes > 0 else { return }
        doneWork += bytes
        let now = Date()
        if measured {
            windowBytes += bytes
            let dt = now.timeIntervalSince(windowStart)
            if dt >= 0.5 {
                let mbps = Double(windowBytes) / dt / 1e6
                currentSpeed = mbps
                if let series { onSample(SpeedSample(time: now.timeIntervalSince(testStart), mbps: mbps, series: series)) }
                windowStart = now
                windowBytes = 0
            }
        }
        emit(force: false)
    }

    private func emit(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= 0.2 else { return }
        lastEmit = now
        let fraction = totalWork > 0 ? min(1, Double(doneWork) / Double(totalWork)) : 0
        let elapsed = now.timeIntervalSince(testStart)
        let eta: TimeInterval? = (fraction > 0.01 && elapsed > 3) ? elapsed * (1 - fraction) / fraction : nil
        let detail = detailOverride ?? (phaseTotal > 0 ? "\(Fmt.bytes(doneWork - phaseBase)) of \(Fmt.bytes(phaseTotal))" : "")
        onProgress(ProgressUpdate(phase: phase, detail: detail, fraction: fraction, speedMBps: currentSpeed, eta: eta, surface: surface))
    }
}
