import AppKit
import Foundation
import HoardiniCore

/// User options, persisted in UserDefaults (plain ObservableObject; no property-wrapper macros needed).
final class AppSettings: ObservableObject {
    @Published var autoConvert: Bool { didSet { UserDefaults.standard.set(autoConvert, forKey: "autoConvert") } }
    @Published var deleteOriginal: Bool { didSet { UserDefaults.standard.set(deleteOriginal, forKey: "deleteOriginal") } }

    init() {
        UserDefaults.standard.register(defaults: ["autoConvert": true, "deleteOriginal": false])
        autoConvert = UserDefaults.standard.bool(forKey: "autoConvert")
        deleteOriginal = UserDefaults.standard.bool(forKey: "deleteOriginal")
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []

    let maxConcurrent = 3
    let settings = AppSettings()
    let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Paused tasks still unwinding; a resume waits for them so it reuses their files instead of starting a new copy.
    private var stopping: [UUID: Task<Void, Never>] = [:]
    private var lastSample: [UUID: (time: Date, bytes: Int64)] = [:]
    private var pollTimer: Timer?

    private var queueFile: URL { AppPaths.support.appendingPathComponent("queue.json") }

    init() {
        try? AppPaths.privateDirectory(AppPaths.support)
        try? AppPaths.privateDirectory(AppPaths.inbox)
        load()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollInbox() }
        }
        pump()
    }

    // MARK: - Adding

    func add(_ request: JobRequest) {
        guard request.validURL != nil else { return }
        items.insert(DownloadItem(request: request), at: 0)
        save()
        pump()
    }

    /// Jobs dropped into the inbox directory by the browser host.
    private func pollInbox() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.inbox, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            defer { try? fm.removeItem(at: f) }
            if let data = try? Data(contentsOf: f), let req = try? JSONDecoder().decode(JobRequest.self, from: data) {
                add(req)
            }
        }
    }

    // MARK: - Controls

    func pause(_ id: UUID) {
        guard let i = index(id), items[i].canPause else { return }
        items[i].status = .paused
        items[i].speed = 0
        tasks[id]?.cancel()
        stopping[id] = tasks.removeValue(forKey: id)
        save()
        pump()
    }

    func resume(_ id: UUID) {
        guard let i = index(id), items[i].status == .paused || items[i].status == .failed else { return }
        items[i].status = .queued
        items[i].error = nil
        save()
        pump()
    }

    /// Stops the download and deletes any partial data.
    func cancelAndRemove(_ id: UUID) {
        let running = [tasks.removeValue(forKey: id), stopping.removeValue(forKey: id)].compactMap { $0 }
        running.forEach { $0.cancel() }
        if let i = index(id) {
            if items[i].status != .completed, let d = items[i].destination {
                // Delete only once the download has stopped writing.
                Task {
                    for t in running { await t.value }
                    Partial.remove(d)
                }
            }
            items.remove(at: i)
        }
        save()
        pump()
    }

    /// Finished downloads (not ones still converting). Removes list entries only; files stay on disk.
    var finishedCount: Int { items.filter { $0.status == .completed && !$0.isConverting }.count }

    func clearFinished() {
        items.removeAll { $0.status == .completed && !$0.isConverting }
        save()
    }

    /// Removes one entry from the list without touching its files.
    func removeFromList(_ id: UUID) {
        guard let i = index(id), items[i].status == .completed, !items[i].isConverting else { return }
        items.remove(at: i)
        save()
    }

    func reveal(_ id: UUID) {
        guard let d = index(id).flatMap({ items[$0].playableURL }), FileManager.default.fileExists(atPath: d.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([d])
    }

    func open(_ id: UUID) {
        guard let d = index(id).flatMap({ items[$0].playableURL }), FileManager.default.fileExists(atPath: d.path) else { return }
        NSWorkspace.shared.open(d)
    }

    // MARK: - MP4 conversion

    /// Adds existing files (e.g. earlier downloads) to the list and converts them.
    func convertFiles(_ urls: [URL]) {
        for url in urls {
            var item = DownloadItem(request: JobRequest(url: url.absoluteString))
            item.status = .completed
            item.destination = url
            item.fraction = 1
            item.total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            items.insert(item, at: 0)
            convert(item.id)
        }
        save()
    }

    func convert(_ id: UUID) {
        guard let i = index(id), items[i].canConvert, let src = items[i].destination else { return }
        items[i].converting = true
        items[i].convertError = nil
        let deleteOriginal = settings.deleteOriginal
        Task { [weak self] in
            do {
                let mp4 = try await Remux.toMP4(src)
                if deleteOriginal { try? FileManager.default.removeItem(at: src) }
                self?.conversionDone(id, mp4: mp4, deletedOriginal: deleteOriginal)
            } catch {
                self?.conversionFailed(id, error.localizedDescription)
            }
        }
    }

    private func conversionDone(_ id: UUID, mp4: URL, deletedOriginal: Bool) {
        guard let i = index(id) else { return }
        items[i].converting = false
        items[i].mp4 = mp4
        if deletedOriginal { items[i].destination = mp4 }
        save()
    }

    private func conversionFailed(_ id: UUID, _ message: String) {
        guard let i = index(id) else { return }
        items[i].converting = false
        items[i].convertError = message
        save()
    }

    func shutdown() {
        for (_, t) in tasks { t.cancel() }
        for i in items.indices where items[i].status == .downloading { items[i].status = .paused }
        save()
    }

    // MARK: - Scheduling

    private func pump() {
        var running = items.filter { $0.status == .downloading }.count
        for i in items.indices.reversed() where running < maxConcurrent && items[i].status == .queued {
            start(items[i].id)
            running += 1
        }
    }

    private func start(_ id: UUID) {
        guard let i = index(id) else { return }
        items[i].status = .downloading
        items[i].speed = 0
        lastSample[id] = (Date(), items[i].done)

        let req = items[i].request
        guard let url = req.validURL else { fail(id, "Invalid URL"); return }
        let dir = downloadsDir
        // On resume keep the name the downloader chose the first time so its state file is found.
        let name = items[i].destination?.lastPathComponent ?? req.cleanFilename

        let prior = stopping.removeValue(forKey: id)
        tasks[id] = Task { [weak self] in
            await prior?.value
            if Task.isCancelled { return }
            let onProgress: @Sendable (DownloadProgress) -> Void = { p in
                Task { @MainActor in self?.progress(id, p) }
            }
            let onDest: @Sendable (URL) -> Void = { u in
                Task { @MainActor in
                    if let self, let i = self.index(id) { self.items[i].destination = u }
                }
            }
            do {
                let out: URL
                if req.isHLS {
                    let d = HLSDownloader(url: url, directory: dir, headers: req.headers, filename: name,
                                          variant: req.validVariant)
                    d.destinationHandler = onDest
                    out = try await d.run(progress: onProgress)
                } else if let audio = req.validAudio {
                    let d = PairDownloader(video: url, audio: audio, directory: dir, headers: req.headers, filename: name)
                    d.destinationHandler = onDest
                    out = try await d.run(progress: onProgress)
                } else {
                    let d = Downloader(url: url, directory: dir, headers: req.headers, filename: name)
                    d.destinationHandler = onDest
                    out = try await d.run(progress: onProgress)
                }
                await self?.finish(id, out)
            } catch {
                if Task.isCancelled { return }   // pause / cancel already updated state
                await self?.fail(id, error.localizedDescription)
            }
        }
    }

    private func progress(_ id: UUID, _ p: DownloadProgress) {
        guard let i = index(id), items[i].status == .downloading else { return }
        items[i].done = p.done
        items[i].total = p.total
        items[i].fraction = p.fraction
        let now = Date()
        if let s = lastSample[id] {
            let dt = now.timeIntervalSince(s.time)
            if dt >= 0.5 {
                let inst = Double(p.done - s.bytes) / dt
                items[i].speed = items[i].speed == 0 ? inst : items[i].speed * 0.7 + inst * 0.3
                lastSample[id] = (now, p.done)
            }
        }
    }

    private func finish(_ id: UUID, _ url: URL) {
        guard let i = index(id) else { return }
        items[i].status = .completed
        items[i].destination = url
        items[i].fraction = 1
        items[i].speed = 0
        items[i].request.cookies = nil     // session cookies are not kept once they are no longer needed
        tasks[id] = nil
        save()
        pump()
        if settings.autoConvert { convert(id) }
    }

    private func fail(_ id: UUID, _ message: String) {
        guard let i = index(id) else { return }
        items[i].status = .failed
        items[i].error = message
        items[i].speed = 0
        tasks[id] = nil
        save()
        pump()
    }

    // MARK: - Persistence

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: queueFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: queueFile.path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: queueFile),
              var saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        for i in saved.indices {
            saved[i].speed = 0
            saved[i].converting = nil     // a conversion cannot survive a quit
            // Anything mid-flight when the app quit is paused, ready to resume where it stopped.
            if saved[i].status == .downloading { saved[i].status = .paused }
        }
        items = saved
    }
}
