import Foundation

public struct ScanProgress: Sendable {
    public let stage: String
    public let completed: Int
    public let total: Int
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

public enum Scanner {

    /// Read every Live Set under `root`, then decide which audio files in the
    /// project folders nothing refers to.
    public static func scan(root: String,
                            options: SweepOptions = SweepOptions(),
                            progress: (@Sendable (ScanProgress) -> Void)? = nil) -> SweepResult {
        let clock = Date()
        let fm = FileManager.default

        progress?(ScanProgress(stage: "Finding projects", completed: 0, total: 0))
        let projectDirs = findProjectDirectories(root: root)

        // Collect the reference files each project owns.
        var sets: [String: [String]] = [:]
        var backups: [String: [String]] = [:]
        var allRefFiles: [String] = []
        for dir in projectDirs {
            let own = (try? fm.contentsOfDirectory(atPath: dir))?
                .filter { Media.referenceHolding.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
                .map { dir + "/" + $0 } ?? []
            sets[dir] = own

            var backupList: [String] = []
            let backupDir = dir + "/Backup"
            if let e = fm.enumerator(atPath: backupDir) {
                for case let sub as String in e
                where Media.referenceHolding.contains((sub as NSString).pathExtension.lowercased()) {
                    backupList.append(backupDir + "/" + sub)
                }
            }
            backups[dir] = backupList.sorted()
            allRefFiles.append(contentsOf: own)
            allRefFiles.append(contentsOf: backupList)
        }

        // Parse every reference file in parallel - by far the expensive part.
        let total = allRefFiles.count
        progress?(ScanProgress(stage: "Reading Live Sets", completed: 0, total: total))
        var parsed = [RefIndex](repeating: RefIndex(), count: total)
        let counter = Counter()
        parsed.withUnsafeMutableBufferPointer { buffer in
            let buf = UnsafeMutableBufferPointerBox(buffer)
            DispatchQueue.concurrentPerform(iterations: total) { i in
                buf.pointer[i] = parseRefFile(allRefFiles[i], deep: options.deep)
                let done = counter.increment()
                if done % 25 == 0 || done == total {
                    progress?(ScanProgress(stage: "Reading Live Sets",
                                           completed: done, total: total))
                }
            }
        }
        var indexByPath: [String: RefIndex] = [:]
        indexByPath.reserveCapacity(total)
        for (i, path) in allRefFiles.enumerated() { indexByPath[path] = parsed[i] }

        // Global indexes. A sample referenced by ANY set anywhere is never an
        // orphan, even when it physically lives in another project's folder.
        var globalSets = RefIndex()
        var globalBackups = RefIndex()
        for dir in projectDirs {
            for f in sets[dir] ?? [] { globalSets.formUnion(indexByPath[f] ?? RefIndex()) }
            if !options.ignoreBackups {
                for f in backups[dir] ?? [] { globalBackups.formUnion(indexByPath[f] ?? RefIndex()) }
            }
        }

        // Longest path first, so a nested project claims its own files.
        let byDepth = projectDirs.sorted { $0.count > $1.count }
        func owner(of path: String) -> String? {
            byDepth.first { path.hasPrefix($0 + "/") }
        }

        progress?(ScanProgress(stage: "Checking samples", completed: 0, total: projectDirs.count))
        var projects: [SweepProject] = []
        for (n, dir) in projectDirs.enumerated() {
            var ownSets = RefIndex(), ownBackups = RefIndex()
            for f in sets[dir] ?? [] { ownSets.formUnion(indexByPath[f] ?? RefIndex()) }
            for f in backups[dir] ?? [] { ownBackups.formUnion(indexByPath[f] ?? RefIndex()) }

            var files: [SweepFile] = []
            var pendingASD: [(path: String, name: String, size: Int64)] = []
            var statusByName: [String: FileStatus] = [:]

            walk(dir) { fullPath, name, size in
                guard owner(of: fullPath) == dir else { return }   // nested project
                let ext = (name as NSString).pathExtension.lowercased()
                if ext == "asd" {
                    pendingASD.append((fullPath, name, size)); return
                }
                guard Media.audio.contains(ext) else { return }

                let normPath = fullPath.precomposedStringWithCanonicalMapping
                let base = name.precomposedStringWithCanonicalMapping
                let status: FileStatus
                if ownSets.absolutePaths.contains(normPath) || ownSets.basenames.contains(base) {
                    status = .used
                } else if globalSets.absolutePaths.contains(normPath) || globalSets.basenames.contains(base) {
                    status = .usedElsewhere
                } else if ownBackups.absolutePaths.contains(normPath) || ownBackups.basenames.contains(base)
                            || globalBackups.absolutePaths.contains(normPath)
                            || globalBackups.basenames.contains(base) {
                    status = .backupOnly
                } else {
                    status = .orphan
                }
                statusByName[base] = status

                let rel = String(fullPath.dropFirst(dir.count + 1))
                let bucket = bucketFor(rel)
                files.append(SweepFile(path: fullPath, relativePath: rel, size: size,
                                       status: status, bucket: bucket,
                                       reclaimable: isReclaimable(status, bucket, options)))
            }

            // .asd analysis files inherit their sample's verdict. If the sample
            // is gone entirely, the .asd is dead weight on its own.
            for entry in pendingASD {
                let parent = String(entry.name.dropLast(4)).precomposedStringWithCanonicalMapping
                let rel = String(entry.path.dropFirst(dir.count + 1))
                let bucket = bucketFor(rel)
                let status = statusByName[parent] ?? .strayASD
                files.append(SweepFile(path: entry.path, relativePath: rel, size: entry.size,
                                       status: status, bucket: bucket,
                                       reclaimable: isReclaimable(status, bucket, options)))
            }

            projects.append(SweepProject(directory: dir,
                                         displayName: displayName(dir, root: root),
                                         sets: sets[dir] ?? [], backups: backups[dir] ?? [],
                                         files: files))
            if n % 10 == 0 {
                progress?(ScanProgress(stage: "Checking samples",
                                       completed: n, total: projectDirs.count))
            }
        }

        var stats = summarize(projects)
        stats.projectCount = projectDirs.count
        stats.liveSetCount = projectDirs.reduce(0) { $0 + (sets[$1]?.count ?? 0) }
        stats.backupCount = projectDirs.reduce(0) { $0 + (backups[$1]?.count ?? 0) }
        stats.seconds = Date().timeIntervalSince(clock)
        return SweepResult(root: root, projects: projects, stats: stats)
    }

    // MARK: - Classification

    static func isReclaimable(_ status: FileStatus, _ bucket: Bucket,
                              _ options: SweepOptions) -> Bool {
        guard status == .orphan || status == .strayASD else { return false }
        switch bucket {
        case .liveManaged: return true
        case .looseInSamples: return options.includeLooseInSamples
        case .unmanaged: return options.includeUnmanaged
        }
    }

    /// Live only ever writes into Samples/<Recorded|Imported|Processed/...>.
    /// Anything else in there was put there by a person and is treated as
    /// deliberate until they say otherwise.
    static func bucketFor(_ relativePath: String) -> Bucket {
        var parts = relativePath.components(separatedBy: "/")
        guard let i = parts.firstIndex(of: "Samples") else { return .unmanaged }
        parts.removeLast()                       // drop the filename
        let tail = Array(parts[(i + 1)...])
        if tail.isEmpty { return .looseInSamples }
        if tail[0] == "Processed" && tail.count > 1 {
            return .liveManaged("Processed/\(tail[1])")
        }
        return .liveManaged(tail[0])
    }

    // MARK: - Filesystem

    static func findProjectDirectories(root: String) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
                                    includingPropertiesForKeys: [.isDirectoryKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var dirs: [String] = [root]
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                dirs.append(url.path)
            }
        }
        for dir in dirs {
            if (dir as NSString).lastPathComponent == "Backup" { continue }
            let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            if contents.contains(where: { ($0 as NSString).pathExtension.lowercased() == "als" }) {
                found.append(dir)
            }
        }
        return found.sorted()
    }

    /// Walk a project folder, skipping Live's own Backup directory.
    static func walk(_ dir: String, _ visit: (String, String, Int64) -> Void) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: URL(fileURLWithPath: dir),
                                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                    options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in e {
            if url.lastPathComponent == "Backup" { e.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  v.isRegularFile == true else { continue }
            visit(url.path, url.lastPathComponent, Int64(v.fileSize ?? 0))
        }
    }

    static func parseRefFile(_ path: String, deep: Bool) -> RefIndex {
        guard let data = FileManager.default.contents(atPath: path) else { return RefIndex() }
        var payload = data
        if data.count >= 2, data[data.startIndex] == 0x1f,
           data[data.index(after: data.startIndex)] == 0x8b {
            payload = (try? Gunzip.inflate(data)) ?? data
        }
        return RefScanner.scan([UInt8](payload), deep: deep)
    }

    static func displayName(_ dir: String, root: String) -> String {
        dir.hasPrefix(root + "/") ? String(dir.dropFirst(root.count + 1)) : dir
    }

    public static func summarize(_ projects: [SweepProject]) -> SweepStats {
        var stats = SweepStats()
        for project in projects {
            for file in project.files {
                var s = stats.byStatus[file.status] ?? (0, 0)
                s.files += 1; s.bytes += file.size
                stats.byStatus[file.status] = s
                if file.reclaimable {
                    stats.reclaimableFiles += 1
                    stats.reclaimableBytes += file.size
                    var b = stats.reclaimableByBucket[file.bucket.label] ?? (0, 0)
                    b.files += 1; b.bytes += file.size
                    stats.reclaimableByBucket[file.bucket.label] = b
                } else if file.status == .orphan || file.status == .strayASD {
                    stats.heldBackFiles += 1
                    stats.heldBackBytes += file.size
                }
            }
        }
        return stats
    }
}

// MARK: - Small concurrency helpers

final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Lets concurrentPerform write into distinct slots of one buffer.
final class UnsafeMutableBufferPointerBox<T>: @unchecked Sendable {
    let pointer: UnsafeMutableBufferPointer<T>
    init(_ pointer: UnsafeMutableBufferPointer<T>) { self.pointer = pointer }
}
