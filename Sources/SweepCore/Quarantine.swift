import Foundation

public struct MovedFile: Codable, Sendable {
    public let from: String
    public let to: String
    public let bytes: Int64
}

public struct SweepManifest: Codable, Sendable {
    public let tool: String
    public let version: String
    public let root: String
    public let created: String
    /// Absent in manifests written before 1.0.2.
    public var folder: String?
    public var moved: [MovedFile]

    public var totalBytes: Int64 { moved.reduce(0) { $0 + $1.bytes } }
}

public struct MoveOutcome: Sendable {
    public let folder: URL
    public let manifest: URL
    public let moved: Int
    public let bytes: Int64
    public let failures: [(path: String, reason: String)]
}

/// Moves orphans aside. Nothing here deletes - the user decides that in Finder,
/// after they have opened their projects and seen that everything still loads.
public enum Quarantine {

    /// What the restore file is called. The older names are still accepted so
    /// folders swept by earlier versions can always be put back.
    public static let manifestFileName = "Put These Files Back.json"
    static let legacyManifestNames = ["Sample Sweep Manifest.json", "_manifest.json"]

    /// Finds the restore file inside a swept folder, so the user can point at
    /// the folder itself rather than hunting for the right .json.
    public static func findManifest(in folder: URL) -> URL? {
        let fm = FileManager.default
        for name in [manifestFileName] + legacyManifestNames {
            let candidate = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // Fall back to any JSON that parses as one of our manifests.
        let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: url),
               let m = try? JSONDecoder().decode(SweepManifest.self, from: data),
               !m.moved.isEmpty {
                return url
            }
        }
        return nil
    }

    public static func move(files: [SweepFile], root: String, destination: URL,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> MoveOutcome {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = formatter.string(from: Date())
        let folder = destination.appendingPathComponent("Sample Sweep \(stamp)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var moved: [MovedFile] = []
        var failures: [(String, String)] = []

        for (i, file) in files.enumerated() {
            let relative = file.path.hasPrefix(root + "/")
                ? String(file.path.dropFirst(root.count + 1))
                : (file.path as NSString).lastPathComponent
            let target = folder.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: file.path), to: target)
                moved.append(MovedFile(from: file.path, to: target.path, bytes: file.size))
            } catch {
                failures.append((file.path, error.localizedDescription))
            }
            progress?(i + 1, files.count)
        }

        let manifest = SweepManifest(tool: "Sample Sweep", version: SweepVersion.current,
                                     root: root, created: stamp, folder: folder.path,
                                     moved: moved)
        let manifestURL = folder.appendingPathComponent(Quarantine.manifestFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)

        // A plain-language note, so the folder still explains itself months later.
        let readme = """
        Sample Sweep, \(stamp)

        These \(moved.count) files (\(humanBytes(manifest.totalBytes))) were moved out of your
        Ableton projects because no Live Set was using them.

        Nothing has been deleted. The folder structure mirrors your projects, so
        you can see exactly where each file came from.

        What to do now:
          1. Open the projects you care about in Ableton and check they load.
          2. If everything is fine, drag this folder to the Trash, or archive it.
          3. If something is missing, open Sample Sweep, choose "Put Files Back"
             from the File menu, and pick THIS FOLDER. Everything returns to
             where it came from.

        You can rename this folder or move it anywhere you like. Put Files Back
        still works, as long as "Put These Files Back.json" stays inside it.

        """
        try? readme.data(using: .utf8)?.write(to: folder.appendingPathComponent("READ ME.txt"))

        return MoveOutcome(folder: folder, manifest: manifestURL, moved: moved.count,
                           bytes: manifest.totalBytes, failures: failures)
    }

    public static func restore(manifestAt url: URL,
                               progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> RestoreOutcome {
        let fm = FileManager.default
        let manifest = try JSONDecoder().decode(SweepManifest.self, from: Data(contentsOf: url))
        let folder = url.deletingLastPathComponent()

        var restored = 0, alreadyInPlace = 0, missing = 0
        for (i, entry) in manifest.moved.enumerated() {
            defer { progress?(i + 1, manifest.moved.count) }
            if fm.fileExists(atPath: entry.from) { alreadyInPlace += 1; continue }
            guard let source = locate(entry, manifest: manifest, folder: folder, fm: fm) else {
                missing += 1; continue
            }
            let parent = (entry.from as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: source, to: URL(fileURLWithPath: entry.from))
                restored += 1
            } catch { missing += 1 }
        }
        return RestoreOutcome(restored: restored, alreadyInPlace: alreadyInPlace,
                              missing: missing, total: manifest.moved.count)
    }

    /// Where the swept copy actually lives now.
    ///
    /// The recorded absolute path is only a hint: people rename the folder, or
    /// drag it somewhere tidier, and that must not break Undo. The folder
    /// mirrors the project tree, so the file's path relative to the scan root
    /// locates it inside whatever the folder is called today.
    private static func locate(_ entry: MovedFile, manifest: SweepManifest,
                               folder: URL, fm: FileManager) -> URL? {
        if fm.fileExists(atPath: entry.to) { return URL(fileURLWithPath: entry.to) }
        let root = manifest.root
        guard entry.from.hasPrefix(root + "/") else { return nil }
        let relative = String(entry.from.dropFirst(root.count + 1))
        let candidate = folder.appendingPathComponent(relative)
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

public struct RestoreOutcome: Sendable {
    public let restored: Int
    public let alreadyInPlace: Int
    public let missing: Int
    public let total: Int
}

public enum SweepVersion { public static let current = "1.0.2" }
