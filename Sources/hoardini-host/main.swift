import AppKit
import HoardiniCore

// Chrome native-messaging host. Protocol: 4-byte native-endian length + UTF-8 JSON, on stdin/stdout.
// The host is short-lived (the browser kills it when the port closes), so it only validates the
// request and passes it on:
//   1. Hoardini.app installed -> write the job to its inbox (launching the app if needed).
//   2. otherwise            -> start a detached `hoardini` command-line process.
//
// Request:  {"url", "referrer", "cookies": "a=b; c=d", "userAgent", "kind": "file"|"hls", "filename", "variant"}
// Response: {"ok": true} or {"ok": false, "error": "..."}

func readMessage() -> Data? {
    let stdin = FileHandle.standardInput
    guard let lenData = try? stdin.read(upToCount: 4), lenData.count == 4 else { return nil }
    let len = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    guard len > 0, len < 1_048_576, let body = try? stdin.read(upToCount: Int(len)), body.count == Int(len) else { return nil }
    return body
}

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var len = UInt32(data.count)
    FileHandle.standardOutput.write(Data(bytes: &len, count: 4))
    FileHandle.standardOutput.write(data)
}

func deliverToApp(_ job: JobRequest) -> String? {
    let fm = FileManager.default
    do {
        try AppPaths.privateDirectory(AppPaths.inbox)
        let tmp = AppPaths.inbox.appendingPathComponent(UUID().uuidString + ".tmp")
        try JSONEncoder().encode(job).write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        try fm.moveItem(at: tmp, to: tmp.deletingPathExtension().appendingPathExtension("json"))
    } catch { return "could not queue job: \(error.localizedDescription)" }

    if NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.bundleID).isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", AppPaths.bundleID]     // -g: don't steal focus from the browser
        do { try p.run() } catch { return "could not launch Hoardini: \(error.localizedDescription)" }
    }
    return nil
}

func runCLI(_ job: JobRequest, url: URL) -> String? {
    // Headers (cookies included) go through a pipe: command-line arguments are visible to every user via `ps`.
    var args = [url.absoluteString, "-o", (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/Downloads", "--headers-stdin"]
    if job.isHLS { args.append("--hls") }
    if job.isHLS, let v = job.validVariant { args += ["--variant", v.absoluteString] }
    if let n = job.cleanFilename { args += ["--name", n] }

    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("hoardini")
    guard FileManager.default.isExecutableFile(atPath: exe.path) else { return "hoardini binary not found next to host" }

    let p = Process()
    p.executableURL = exe
    p.arguments = args
    let pipe = Pipe()
    p.standardInput = pipe
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "\(error)" }
    let headerText = job.headers.map { "\($0.key): \($0.value)\n" }.joined()
    try? pipe.fileHandleForWriting.write(contentsOf: Data(headerText.utf8))
    try? pipe.fileHandleForWriting.close()
    return nil
}

signal(SIGPIPE, SIG_IGN)   // a CLI that exits early must not take the host down with it
let fm = FileManager.default

func handle(_ data: Data) -> [String: Any] {
    guard let job = try? JSONDecoder().decode(JobRequest.self, from: data), let url = job.validURL else {
        return ["ok": false, "error": "invalid url"]
    }
    let appInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppPaths.bundleID) != nil
    if let err = appInstalled ? deliverToApp(job) : runCLI(job, url: url) { return ["ok": false, "error": err] }
    return ["ok": true]
}

while let msg = readMessage() { send(handle(msg)) }
