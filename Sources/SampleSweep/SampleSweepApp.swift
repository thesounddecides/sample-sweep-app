import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SweepCore

enum Phase {
    case welcome
    case scanning
    case results
    case moving
    case done(MoveOutcome)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: Phase = .welcome
    @Published var root: String?
    @Published var result: SweepResult?
    @Published var selection: Set<String> = []
    @Published var progressStage = ""
    @Published var progressFraction = 0.0
    @Published var moveProgress = ""
    @Published var options = SweepOptions()
    @Published var errorMessage: String?

    var projectsWithFindings: [SweepProject] {
        (result?.projects ?? [])
            .filter { project in project.files.contains { $0.reclaimable } }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    var selectedFiles: [SweepFile] {
        (result?.projects ?? []).flatMap { $0.files }.filter { selection.contains($0.path) }
    }
    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }

    var abletonIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            (app.localizedName ?? "").localizedCaseInsensitiveContains("Ableton")
                || (app.bundleIdentifier ?? "").localizedCaseInsensitiveContains("ableton")
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan This Folder"
        panel.message = "Choose the folder that holds your Ableton projects."
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        panel.directoryURL = music?.appendingPathComponent("Ableton")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url.path
        startScan()
    }

    func startScan() {
        guard let root else { return }
        phase = .scanning
        progressStage = "Finding projects"
        progressFraction = 0
        let options = self.options
        Task.detached(priority: .userInitiated) { [model = self] in
            let result = Scanner.scan(root: root, options: options) { p in
                Task { @MainActor in
                    model.progressStage = p.stage
                    model.progressFraction = p.fraction
                }
            }
            await MainActor.run {
                model.result = result
                model.selection = Set(result.projects.flatMap { $0.files }
                    .filter(\.reclaimable).map(\.path))
                model.phase = .results
            }
        }
    }

    func rescan() { startScan() }

    func moveSelected() {
        guard let root, !selectedFiles.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Move Files Here"
        panel.message = "Choose where to put the swept files. You can check them, "
            + "then archive or delete the folder yourself."
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory,
                                                      in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let files = selectedFiles
        phase = .moving
        moveProgress = "Moving \(files.count) files…"
        Task.detached(priority: .userInitiated) { [model = self] in
            do {
                let outcome = try Quarantine.move(files: files, root: root,
                                                  destination: destination) { done, total in
                    Task { @MainActor in
                        model.moveProgress = "Moving \(done) of \(total)…"
                    }
                }
                await MainActor.run {
                    UserDefaults.standard.set(outcome.folder.path, forKey: "lastSweepFolder")
                    model.phase = .done(outcome)
                }
            } catch {
                await MainActor.run {
                    model.errorMessage = error.localizedDescription
                    model.phase = .results
                }
            }
        }
    }

    /// Ask for the swept FOLDER, not a file. People should never have to work
    /// out which .json in a folder is the one that restores their samples.
    func undoSweep() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .folder]
        panel.prompt = "Put Files Back"
        panel.message = "Choose the folder Sample Sweep created."
        if let last = UserDefaults.standard.string(forKey: "lastSweepFolder") {
            let parent = URL(fileURLWithPath: last).deletingLastPathComponent()
            panel.directoryURL = FileManager.default.fileExists(atPath: last)
                ? URL(fileURLWithPath: last) : parent
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory,
                                                          in: .userDomainMask).first
        }
        guard panel.runModal() == .OK, let picked = panel.url else { return }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDirectory)
        let manifest = isDirectory.boolValue ? Quarantine.findManifest(in: picked) : picked
        guard let manifest else {
            let alert = NSAlert()
            alert.messageText = "That folder wasn't made by Sample Sweep"
            alert.informativeText = "Pick the folder Sample Sweep created when it moved "
                + "your files aside. It has a file called \"\(Quarantine.manifestFileName)\" "
                + "inside it."
            alert.runModal()
            return
        }
        performRestore(manifest)
    }

    func performRestore(_ manifest: URL) {
        do {
            let outcome = try Quarantine.restore(manifestAt: manifest)
            let alert = NSAlert()
            if outcome.restored == outcome.total {
                alert.messageText = "Put \(outcome.restored) files back"
                alert.informativeText = "Everything is where it started again."
            } else {
                alert.messageText = "Put \(outcome.restored) of \(outcome.total) files back"
                var lines: [String] = []
                if outcome.alreadyInPlace > 0 {
                    lines.append("\(outcome.alreadyInPlace) were already in place.")
                }
                if outcome.missing > 0 {
                    lines.append("\(outcome.missing) could not be found. They may have "
                                 + "been moved or deleted since the sweep.")
                }
                alert.informativeText = lines.joined(separator: "\n")
            }
            alert.runModal()
            if result != nil { rescan() }
        } catch {
            errorMessage = "That file could not be read as a Sample Sweep record.\n\n"
                + error.localizedDescription
        }
    }

    /// Lets the app be launched straight into a scan, for testing and for
    /// anyone who wants to wire it into a script.
    func startIfPreconfigured() {
        guard case .welcome = phase,
              let preset = ProcessInfo.processInfo.environment["SAMPLESWEEP_ROOT"],
              FileManager.default.fileExists(atPath: preset) else { return }
        root = preset
        startScan()
    }

    func reset() {
        phase = .welcome
        result = nil
        selection = []
        root = nil
    }
}

@main
struct SampleSweepApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Sample Sweep") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { model.startIfPreconfigured() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Put Files Back…") { model.undoSweep() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .welcome:          WelcomeView()
            case .scanning:         ScanningView()
            case .results:          ResultsView()
            case .moving:           MovingView()
            case .done(let out):    CompletionView(outcome: out)
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 96, height: 96)
                .padding(.bottom, 14)
            Text("Sample Sweep").font(.system(size: 34, weight: .semibold))
            SoundDecisionsMark(height: 40, opacity: 0.85)
                .padding(.top, 12)
            Text("Find unused samples in your Ableton projects")
                .font(.title3).foregroundStyle(.secondary)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 14) {
                Bullet("magnifyingglass", "Reads every Live Set in a folder you choose",
                       "Works out which samples each one actually uses.")
                Bullet("tray.full", "Finds the leftovers",
                       "Dead takes, freeze files from tracks you unfroze, old bounces and crops.")
                Bullet("arrow.uturn.backward", "Never deletes anything",
                       "Files are moved to a folder you pick, and one click puts them back.")
            }
            .padding(.top, 34)
            .frame(maxWidth: 520, alignment: .leading)

            Button(action: model.chooseFolder) {
                Text("Choose Your Ableton Folder…").frame(width: 240)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            .padding(.top, 36)

            Text("Usually ~/Music/Ableton. Pick the biggest folder you can. Sample Sweep\n"
                 + "checks the other projects so it never flags a sample two of them share.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.top, 14)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func Bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The "by Sound Decisions" lockup, in whichever polarity suits the appearance.
/// Clicking it opens the company site.
struct SoundDecisionsMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat = 26
    var opacity: Double = 0.65

    private static let site = URL(string: "https://thesounddecides.com")!

    var body: some View {
        if let image = NSImage(named: colorScheme == .dark ? "sd-logo-dark" : "sd-logo-light")
            ?? Bundle.main.image(forResource: colorScheme == .dark ? "sd-logo-dark" : "sd-logo-light") {
            Link(destination: Self.site) {
                Image(nsImage: image)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(height: height)
                    .opacity(opacity)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("thesounddecides.com")
            .accessibilityLabel("by Sound Decisions")
        }
    }
}

struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView(value: model.progressFraction).frame(width: 320)
            Text(model.progressStage).font(.headline)
            Text(model.root ?? "").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { SoundDecisionsMark().padding(.bottom, 26) }
    }
}

struct MovingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(model.moveProgress).font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
