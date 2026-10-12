import AppKit
import SwiftUI
import HoardiniCore

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

private func duration(_ s: Double) -> String {
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

enum Brand {
    /// Loads a PNG shipped in the app bundle's Resources, sized in points (the file may be 2x).
    static func image(_ name: String, points: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: points, height: points)
        return img
    }
}

/// Small observable box used instead of @State, which needs the SwiftUI macro plugin
/// that is not available in the Command Line Tools toolchain.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

struct ContentView: View {
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var settings: AppSettings
    @StateObject private var showingAdd = Box(false)

    var body: some View {
        Group {
            if manager.items.isEmpty {
                VStack(spacing: 8) {
                    if let icon = Brand.image("icon-256", points: 96) {
                        Image(nsImage: icon)
                    } else {
                        Image(systemName: "arrow.down.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                    }
                    Text("No downloads yet").font(.headline)
                    Text("Downloads sent from the browser extension appear here.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.items) { item in
                    DownloadRow(item: item).padding(.vertical, 4)
                        .contextMenu {
                            if item.status == .completed && !item.isConverting {
                                Button("Remove from List") { manager.removeFromList(item.id) }
                            }
                        }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .toolbar {
            ToolbarItem {
                Button { showingAdd.value = true } label: { Label("Add URL", systemImage: "plus") }
            }
            ToolbarItem {
                Button { pickFiles() } label: { Label("Convert Files…", systemImage: "film") }
                    .help("Convert existing .ts files to MP4")
            }
            ToolbarItem {
                Menu {
                    Toggle("Convert to MP4 automatically", isOn: $settings.autoConvert)
                    Toggle("Delete the .ts after converting", isOn: $settings.deleteOriginal)
                } label: { Label("Options", systemImage: "gearshape") }
            }
            ToolbarItem {
                Button { manager.clearFinished() } label: {
                    Label(manager.finishedCount > 0 ? "Clear Finished (\(manager.finishedCount))" : "Clear Finished",
                          systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Remove finished downloads from this list (files stay in your Downloads folder)")
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(manager.finishedCount == 0)
            }
        }
        .sheet(isPresented: $showingAdd.value) { AddURLSheet() }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose video files to convert to MP4"
        guard panel.runModal() == .OK else { return }
        manager.convertFiles(panel.urls)
    }
}

struct DownloadRow: View {
    @EnvironmentObject var manager: DownloadManager
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                if item.isConverting {
                    ProgressView().progressViewStyle(.linear)
                } else if item.status == .downloading || item.status == .paused {
                    if let f = item.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                }
                Text(detail).font(.caption).foregroundStyle(item.status == .failed ? .red : .secondary)
            }
            Spacer()
            controls
        }
    }

    private var icon: String {
        switch item.status {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch item.status {
        case .completed: return .green
        case .failed: return .red
        case .downloading: return .accentColor
        default: return .secondary
        }
    }

    private var detail: String {
        switch item.status {
        case .queued: return "Waiting…"
        case .failed: return item.error ?? "Failed"
        case .completed:
            if item.isConverting { return "Converting to MP4…" }
            if let e = item.convertError { return "Conversion failed: \(e)" }
            let size = item.total.map { bytes($0) } ?? bytes(item.done)
            return item.mp4 != nil ? "\(size) · MP4 ready: \(item.mp4!.lastPathComponent)" : size
        case .paused, .downloading:
            var parts: [String] = []
            if let t = item.total { parts.append("\(bytes(item.done)) of \(bytes(t))") }
            else if item.done > 0 { parts.append(bytes(item.done)) }
            if item.status == .paused { parts.append("Paused") }
            if item.speed > 0 { parts.append("\(bytes(Int64(item.speed)))/s") }
            if let eta = item.etaSeconds { parts.append("\(duration(eta)) left") }
            return parts.joined(separator: " · ")
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 6) {
            switch item.status {
            case .downloading where item.canPause:
                Button { manager.pause(item.id) } label: { Image(systemName: "pause.fill") }.help("Pause")
            case .paused, .failed:
                Button { manager.resume(item.id) } label: { Image(systemName: "play.fill") }
                    .help(item.status == .failed ? "Retry" : "Resume")
            case .completed:
                if item.canConvert {
                    Button { manager.convert(item.id) } label: { Image(systemName: "film") }.help("Convert to MP4")
                }
                Button { manager.open(item.id) } label: { Image(systemName: "play.rectangle") }.help("Open")
                Button { manager.reveal(item.id) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder")
            default: EmptyView()
            }
            Button { manager.cancelAndRemove(item.id) } label: { Image(systemName: "xmark") }
                .help(item.status == .completed ? "Remove from list" : "Cancel and delete partial file")
        }
        .buttonStyle(.borderless)
    }
}

struct AddURLSheet: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var text = Box("")

    private var request: JobRequest { JobRequest(url: text.value.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add download").font(.headline)
            TextField("https://…", text: $text.value).textFieldStyle(.roundedBorder).frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download") { manager.add(request); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(request.validURL == nil)
            }
        }
        .padding(20)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = manager.items.filter { $0.status == .downloading }
        let speed = active.reduce(0.0) { $0 + $1.speed }
        Text(active.isEmpty ? "No active downloads" : "\(active.count) downloading · \(bytes(Int64(speed)))/s")
        Divider()
        Button(manager.finishedCount > 0 ? "Clear Finished (\(manager.finishedCount))" : "Clear Finished") {
            manager.clearFinished()
        }
        .disabled(manager.finishedCount == 0)
        Button("Show Hoardini") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Hoardini") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
