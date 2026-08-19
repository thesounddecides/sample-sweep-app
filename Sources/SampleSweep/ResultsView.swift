import SwiftUI
import AppKit
import SweepCore

struct ResultsView: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded: Set<String> = []

    private var stats: SweepStats { model.result?.stats ?? SweepStats() }
    private var projects: [SweepProject] { model.projectsWithFindings }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.abletonIsRunning { abletonWarning }
            if projects.isEmpty { emptyState } else { projectList }
            Divider()
            footer
        }
    }

    // MARK: Header

    /// Built as a plain string. SwiftUI only parses inflection markup in
    /// literal LocalizedStringKeys, and this is assembled at runtime.
    private var subtitle: String {
        guard stats.reclaimableFiles > 0 else {
            return "Scanned \(stats.projectCount) "
                + (stats.projectCount == 1 ? "project" : "projects")
        }
        return pluralized(stats.reclaimableFiles, "file")
            + " in " + pluralized(projects.count, "project")
            + ", out of \(stats.projectCount) scanned"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(humanBytes(stats.reclaimableBytes))
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(stats.reclaimableBytes > 0 ? .green : .secondary)
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Menu {
                    Toggle("Include files outside Samples (bounces, masters)",
                           isOn: binding(\.includeUnmanaged))
                    Toggle("Include files dropped straight into Samples",
                           isOn: binding(\.includeLooseInSamples))
                    Toggle("Treat backup-only samples as unused",
                           isOn: binding(\.ignoreBackups))
                    Divider()
                    Toggle("Search inside plugin presets (slower)", isOn: binding(\.deep))
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton).fixedSize()

                if stats.heldBackFiles > 0 {
                    Text("\(stats.heldBackFiles) unused files (\(humanBytes(stats.heldBackBytes))) "
                         + "held back as too risky")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private func binding(_ key: WritableKeyPath<SweepOptions, Bool>) -> Binding<Bool> {
        Binding(get: { model.options[keyPath: key] },
                set: { model.options[keyPath: key] = $0; model.rescan() })
    }

    private var abletonWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Ableton Live is open. Quit it before you sweep, then reopen your projects "
                 + "to check them. A Set that's already open has its samples loaded in memory, "
                 + "so it will look fine even if something went wrong.")
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.green)
            Text("Nothing to sweep").font(.title3.weight(.medium))
            Text("Every sample in these projects is being used.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Project list

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(projects) { project in
                    ProjectRow(project: project,
                               isExpanded: expanded.contains(project.id),
                               toggleExpanded: {
                                   if expanded.contains(project.id) { expanded.remove(project.id) }
                                   else { expanded.insert(project.id) }
                               })
                    Divider()
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Scan a Different Folder") { model.reset() }
            Button("Put Files Back…") { model.undoSweep() }
            Spacer()
            if model.selectedFiles.isEmpty {
                Text("Nothing selected").foregroundStyle(.secondary)
            } else {
                Text("\(model.selectedFiles.count) selected · \(humanBytes(model.selectedBytes))")
                    .foregroundStyle(.secondary)
            }
            Button(action: model.moveSelected) {
                Text("Move Files Aside…").frame(minWidth: 140)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedFiles.isEmpty)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }
}

func pluralized(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)" + (count == 1 ? "" : "s")
}

struct ProjectRow: View {
    @EnvironmentObject var model: AppModel
    let project: SweepProject
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    private var candidates: [SweepFile] {
        project.files.filter(\.reclaimable).sorted { $0.size > $1.size }
    }
    private var selectedCount: Int {
        candidates.filter { model.selection.contains($0.path) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { selectedCount == candidates.count && !candidates.isEmpty },
                    set: { on in
                        for f in candidates {
                            if on { model.selection.insert(f.path) }
                            else { model.selection.remove(f.path) }
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                Button(action: toggleExpanded) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.displayName).fontWeight(.medium).lineLimit(1)
                    Text(summaryLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(humanBytes(project.reclaimableBytes))
                    .monospacedDigit().foregroundStyle(.green)
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directory)
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Show in Finder")
            }
            .padding(.horizontal, 22).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { file in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { model.selection.contains(file.path) },
                                set: { on in
                                    if on { model.selection.insert(file.path) }
                                    else { model.selection.remove(file.path) }
                                }))
                                .labelsHidden().toggleStyle(.checkbox)
                            Text(file.relativePath).font(.callout).lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(file.bucket.label).font(.caption)
                                .foregroundStyle(.secondary)
                            Text(humanBytes(file.size)).font(.callout).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                        }
                        .padding(.leading, 62).padding(.trailing, 22).padding(.vertical, 3)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(isExpanded ? Color.primary.opacity(0.03) : Color.clear)
    }

    private var summaryLine: String {
        var counts: [String: Int] = [:]
        for f in candidates { counts[f.bucket.label, default: 0] += 1 }
        let parts = counts.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.value) \($0.key)" }
        return parts.joined(separator: " · ")
    }
}

struct CompletionView: View {
    @EnvironmentObject var model: AppModel
    let outcome: MoveOutcome

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50)).foregroundStyle(.green)
            Text("Swept \(humanBytes(outcome.bytes))")
                .font(.system(size: 30, weight: .semibold)).padding(.top, 14)
            Text("\(pluralized(outcome.moved, "file")) moved. Nothing was deleted.")
                .foregroundStyle(.secondary).padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                Step(1, "Open your projects in Ableton and check they still load.")
                Step(2, "If all is well, archive that folder or drag it to the Trash.")
                Step(3, "If something is missing, choose Put Files Back and pick that folder.")
            }
            .padding(.top, 30).frame(maxWidth: 480, alignment: .leading)

            if !outcome.failures.isEmpty {
                Text("\(outcome.failures.count) files could not be moved and were left in place.")
                    .font(.callout).foregroundStyle(.orange).padding(.top, 16)
            }

            HStack(spacing: 12) {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(outcome.manifest.path,
                                                  inFileViewerRootedAtPath: outcome.folder.path)
                }
                .controlSize(.large)
                Button("Put These Files Back") { model.performRestore(outcome.manifest) }
                    .controlSize(.large)
                Button("Scan Again") { model.rescan() }
                    .controlSize(.large).buttonStyle(.borderedProminent)
            }
            .padding(.top, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    @ViewBuilder
    private func Step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.callout.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
            Text(text).font(.callout)
        }
    }
}
