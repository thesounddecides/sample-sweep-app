import Foundation
import SweepCore

// Exercises the move/restore round trip end to end. Used to prove that Undo
// still works after the swept folder has been renamed or moved.
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    print("usage: sweeptool <sweep|restore> <root> <folder>"); exit(2)
}
let mode = args[0], root = args[1], folder = args[2]

switch mode {
case "sweep":
    let result = Scanner.scan(root: root)
    let files = result.projects.flatMap { $0.files }.filter(\.reclaimable)
    let out = try Quarantine.move(files: files, root: root,
                                  destination: URL(fileURLWithPath: folder))
    print("moved \(out.moved) files (\(humanBytes(out.bytes))) -> \(out.folder.lastPathComponent)")
case "restore":
    guard let manifest = Quarantine.findManifest(in: URL(fileURLWithPath: folder)) else {
        print("NO RESTORE FILE FOUND in \(folder)"); exit(1)
    }
    print("found restore file: \(manifest.lastPathComponent)")
    let o = try Quarantine.restore(manifestAt: manifest)
    print("restored=\(o.restored) alreadyInPlace=\(o.alreadyInPlace) missing=\(o.missing) total=\(o.total)")
    if o.missing > 0 { exit(1) }
case "verify":
    // Non-destructive: can we find the restore file, and would every entry
    // resolve to a real file if the user hit Undo right now?
    guard let manifest = Quarantine.findManifest(in: URL(fileURLWithPath: folder)) else {
        print("NO RESTORE FILE FOUND in \(folder)"); exit(1)
    }
    let data = try Data(contentsOf: manifest)
    let m = try JSONDecoder().decode(SweepManifest.self, from: data)
    let fm = FileManager.default
    var atRecorded = 0, viaFolder = 0, unresolved = 0
    for e in m.moved {
        if fm.fileExists(atPath: e.to) { atRecorded += 1; continue }
        let rel = e.from.hasPrefix(m.root + "/") ? String(e.from.dropFirst(m.root.count + 1)) : ""
        let candidate = URL(fileURLWithPath: folder).appendingPathComponent(rel)
        if !rel.isEmpty, fm.fileExists(atPath: candidate.path) { viaFolder += 1 } else { unresolved += 1 }
    }
    print("restore file : \(manifest.lastPathComponent)")
    print("entries      : \(m.moved.count)  (\(humanBytes(m.totalBytes)))")
    print("at recorded path : \(atRecorded)")
    print("found via folder : \(viaFolder)")
    print("UNRESOLVED       : \(unresolved)")
default: print("unknown mode"); exit(2)
}
