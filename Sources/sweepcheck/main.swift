import Foundation
import SweepCore

// Validation harness: emits one line per file so the Swift engine can be
// diffed against the reference Python implementation.
var args = Array(CommandLine.arguments.dropFirst())
var options = SweepOptions()
options.includeLooseInSamples = true   // match the Python default
if let i = args.firstIndex(of: "--app-defaults") {
    args.remove(at: i); options = SweepOptions()   // exactly what the app uses
}
if let i = args.firstIndex(of: "--deep") { args.remove(at: i); options.deep = true }
if let i = args.firstIndex(of: "--include-loose") {
    args.remove(at: i); options.includeUnmanaged = true
}
guard let root = args.first else {
    FileHandle.standardError.write(Data("usage: sweepcheck <root> [--deep] [--include-loose]\n".utf8))
    exit(2)
}

let result = Scanner.scan(root: root, options: options) { p in
    if p.total > 0 && p.completed % 200 == 0 {
        FileHandle.standardError.write(Data("  \(p.stage) \(p.completed)/\(p.total)\r".utf8))
    }
}

var out = ""
for project in result.projects.sorted(by: { $0.directory < $1.directory }) {
    for file in project.files.sorted(by: { $0.path < $1.path }) {
        out += "\(file.status.rawValue)\t\(file.reclaimable ? 1 : 0)\t\(file.size)\t\(file.bucket.label)\t\(file.path)\n"
    }
}
FileHandle.standardOutput.write(Data(out.utf8))

let s = result.stats
FileHandle.standardError.write(Data("""

  projects=\(s.projectCount) sets=\(s.liveSetCount) backups=\(s.backupCount)
  reclaimable=\(s.reclaimableFiles) files \(humanBytes(s.reclaimableBytes))
  seconds=\(String(format: "%.1f", s.seconds))

""".utf8))
