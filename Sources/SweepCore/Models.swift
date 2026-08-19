import Foundation

public enum FileStatus: String, Codable, Sendable {
    case used                                   // this project's Live Set uses it
    case usedElsewhere = "used-elsewhere"       // a different project's Set uses it
    case backupOnly = "backup-only"             // only Backup/ sets point at it
    case orphan                                 // nothing points at it
    case strayASD = "stray-asd"                 // analysis file, its sample is gone

    public var explanation: String {
        switch self {
        case .used: return "In use by this project"
        case .usedElsewhere: return "Used by a different project"
        case .backupOnly: return "Only used by a backup of this set"
        case .orphan: return "Nothing refers to it"
        case .strayASD: return "Analysis file, its sample is gone"
        }
    }
}

/// Where in the project a file sits. This drives the default keep decision as
/// much as the reference check does.
public enum Bucket: Equatable, Codable, Sendable {
    case liveManaged(String)   // Samples/Recorded, Samples/Processed/Freeze, ...
    case looseInSamples        // dropped straight into Samples/ by a human
    case unmanaged             // outside Samples/ entirely: bounces, masters

    public var label: String {
        switch self {
        case .liveManaged(let s): return s
        case .looseInSamples: return "Samples (loose)"
        case .unmanaged: return "Outside Samples"
        }
    }
}

public struct SweepFile: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let relativePath: String
    public let size: Int64
    public let status: FileStatus
    public let bucket: Bucket
    /// Proposed for moving. The UI can still let the user override per file.
    public var reclaimable: Bool
}

public struct SweepProject: Identifiable, Sendable {
    public var id: String { directory }
    public let directory: String
    public let displayName: String
    public let sets: [String]
    public let backups: [String]
    public var files: [SweepFile]

    public var reclaimableFiles: [SweepFile] { files.filter(\.reclaimable) }
    public var reclaimableBytes: Int64 { reclaimableFiles.reduce(0) { $0 + $1.size } }
}

public struct SweepOptions: Sendable {
    /// Count unreferenced audio living outside Samples/ (bounces, masters).
    public var includeUnmanaged = false
    /// Count unreferenced audio dropped directly into Samples/ by hand.
    /// Live never writes there, so these are usually deliberate imports.
    public var includeLooseInSamples = false
    /// Treat samples only referenced by Backup/ sets as orphans.
    public var ignoreBackups = false
    /// Also search third-party plugin state for sample names.
    public var deep = false

    public init() {}
}

public struct SweepStats: Sendable {
    public var projectCount = 0
    public var liveSetCount = 0
    public var backupCount = 0
    public var byStatus: [FileStatus: (files: Int, bytes: Int64)] = [:]
    public var reclaimableByBucket: [String: (files: Int, bytes: Int64)] = [:]
    public var reclaimableFiles = 0
    public var reclaimableBytes: Int64 = 0
    public var heldBackFiles = 0
    public var heldBackBytes: Int64 = 0
    public var seconds: Double = 0

    public init() {}
}

public struct SweepResult: Sendable {
    public let root: String
    public var projects: [SweepProject]
    public var stats: SweepStats
}

public func humanBytes(_ n: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(n), i = 0
    while abs(value) >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[i])
}
