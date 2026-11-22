import Foundation

enum TestKind: String, CaseIterable, Identifiable, Sendable {
    case quickSpeed, fullIntegrity, surfaceScan, readScan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickSpeed: "Speed Test"
        case .fullIntegrity: "Full Capacity & Integrity Test"
        case .surfaceScan: "Surface Scan (Every Sector)"
        case .readScan: "Read Scan of Existing Files"
        }
    }

    var symbol: String {
        switch self {
        case .quickSpeed: "speedometer"
        case .fullIntegrity: "checkmark.shield"
        case .surfaceScan: "square.grid.3x3.fill"
        case .readScan: "doc.text.magnifyingglass"
        }
    }

    var summary: String {
        switch self {
        case .quickSpeed:
            "Writes a temporary file, reads it back to verify it, then measures random 4K performance. Estimates the card's speed class (Class 10, U3, V30…) and app class (A1/A2)."
        case .fullIntegrity:
            "Fills all free space with a unique verifiable pattern, then reads every byte back. Detects counterfeit (fake-capacity) cards and failing flash. Your existing files are not touched."
        case .surfaceScan:
            "Reads every sector of the whole card at the device level, including your files, the file system and the partition table. Maps any unreadable or unusually slow sectors. Read-only. Asks for your administrator password."
        case .readScan:
            "Reads every existing file on the card to find unreadable areas. Writes nothing, so it also works on write-protected cards."
        }
    }

    var writesToCard: Bool { self == .quickSpeed || self == .fullIntegrity }
}

enum Verdict: Sendable {
    case pass, warning, fail, cancelled, error

    var label: String {
        switch self {
        case .pass: "Passed"
        case .warning: "Warning"
        case .fail: "Failed"
        case .cancelled: "Cancelled"
        case .error: "Couldn't Run"
        }
    }

    var symbol: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }
}

struct Metric: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let value: String
}

struct TestResult: Identifiable, Sendable {
    let id = UUID()
    let kind: TestKind
    let volumeID: String
    let volumeName: String
    let date = Date()
    let verdict: Verdict
    let headline: String
    var metrics: [Metric] = []
    var notes: [String] = []
    var surfaceMap: [UInt8]?

    var reportText: String {
        var lines = [
            "SD Card Checker report",
            "Card: \(volumeName)",
            "Test: \(kind.title)",
            "Date: \(date.formatted(date: .abbreviated, time: .shortened))",
            "Result: \(verdict.label) — \(headline)",
            "",
        ]
        lines += metrics.map { "\($0.label): \($0.value)" }
        if !notes.isEmpty { lines.append(""); lines += notes.map { "• \($0)" } }
        return lines.joined(separator: "\n")
    }
}

struct ProgressUpdate: Sendable {
    var phase: String
    var detail: String
    var fraction: Double
    var speedMBps: Double?
    var eta: TimeInterval?
    var surface: [UInt8]?
}

/// Cell states for the surface map.
enum SurfaceCell {
    static let unread: UInt8 = 0, ok: UInt8 = 1, slow: UInt8 = 2, bad: UInt8 = 3
    static let count = 600
}

struct SpeedSample: Identifiable, Sendable {
    let id = UUID()
    let time: Double
    let mbps: Double
    let series: String
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func speed(_ mbps: Double) -> String {
        mbps >= 100 ? String(format: "%.0f MB/s", mbps) : String(format: "%.1f MB/s", mbps)
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : (t >= 60 ? [.minute, .second] : [.second])
        return f.string(from: max(t, 1)) ?? "—"
    }

    /// Speed class implied by a sustained sequential write speed (MB/s, decimal).
    static func speedClass(writeMBps w: Double) -> String {
        switch w {
        case 90...: "V90"
        case 60..<90: "V60"
        case 30..<60: "U3 / V30"
        case 10..<30: "Class 10 / U1 / V10"
        case 6..<10: "Class 6 / V6"
        case 4..<6: "Class 4"
        case 2..<4: "Class 2"
        default: "Below Class 2"
        }
    }

    /// Application performance class from random 4K IOPS.
    static func appClass(readIOPS r: Double, writeIOPS w: Double) -> String {
        if r >= 4000 && w >= 2000 { return "A2" }
        if r >= 1500 && w >= 500 { return "A1" }
        return "Below A1"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
