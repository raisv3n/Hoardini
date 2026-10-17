import AppKit
import CryptoKit
import Foundation
import HoardiniCore

/// Installs what the browser needs from the copies inside the app bundle, so dragging Hoardini.app into
/// Applications is the whole install (and dragging in a newer one updates it on next launch):
/// - Contents/Helpers/{hoardini, hoardini-host} ->  ~/Library/Application Support/Hoardini/bin
/// - Contents/Resources/extension               ->  ~/Library/Application Support/Hoardini/extension
/// - the native-messaging host manifest, for Chrome and for Brave, Edge, Chromium, Vivaldi and Arc when installed.
/// The copies live outside the app because the browser keeps using the paths it was given.
enum BrowserSetup {
    static let hostName = "com.hoardini.host"
    static var binDir: URL { AppPaths.support.appendingPathComponent("bin") }
    static var extensionDir: URL { AppPaths.support.appendingPathComponent("extension") }

    /// Other Chromium browsers each read their own folder; only registered when the browser is installed.
    private static let otherBrowsers = ["BraveSoftware/Brave-Browser", "Microsoft Edge", "Chromium", "Vivaldi", "Arc/User Data"]

    /// Returns false when the bundle carries no helpers (e.g. the bare SwiftPM binary run from .build).
    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let tools = ["hoardini", "hoardini-host"].map { bundle.appendingPathComponent("Helpers/\($0)") }
        let ext = bundle.appendingPathComponent("Resources/extension")
        guard tools.allSatisfy({ fm.isExecutableFile(atPath: $0.path) }),
              fm.fileExists(atPath: ext.appendingPathComponent("manifest.json").path) else { return false }
        do {
            try AppPaths.privateDirectory(AppPaths.support)
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            for tool in tools { try replace(binDir.appendingPathComponent(tool.lastPathComponent), with: tool) }
            try replace(extensionDir, with: ext)
            try registerHost(manifest: extensionDir.appendingPathComponent("manifest.json"),
                             host: binDir.appendingPathComponent("hoardini-host"))
            return true
        } catch {
            NSLog("Hoardini: browser setup failed: \(error)")
            return false
        }
    }

    /// Copies next to the target, then swaps it in, so a running host or a half-finished copy is never left behind.
    private static func replace(_ target: URL, with source: URL) throws {
        let fm = FileManager.default
        let staged = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        clearQuarantine(staged)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: target)
        }
    }

    /// Files this app writes are quarantined (LSFileQuarantineEnabled); its own helpers must not be,
    /// or macOS blocks the host when the browser starts it.
    private static func clearQuarantine(_ url: URL) {
        let paths = [url.path] + ((FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String]) ?? [])
            .map { url.appendingPathComponent($0).path }
        for p in paths { removexattr(p, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    private static func registerHost(manifest: URL, host: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        guard let key = json?["key"] as? String, let der = Data(base64Encoded: key) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let hostManifest: [String: Any] = [
            "name": hostName, "description": "Hoardini native host", "path": host.path, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID(der))/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: hostManifest, options: [.prettyPrinted, .sortedKeys])
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let browsers = ["Google/Chrome"] + otherBrowsers.filter {
            FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path)
        }
        for b in browsers {
            let dir = support.appendingPathComponent("\(b)/NativeMessagingHosts")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(hostName).json"), options: .atomic)
        }
    }

    /// Chromium's ID for an extension with a fixed key: first 32 hex digits of SHA-256(key), 0-f mapped to a-p.
    static func extensionID(_ publicKeyDER: Data) -> String {
        let hex = SHA256.hash(data: publicKeyDER).map { String(format: "%02x", $0) }.joined().prefix(32)
        return String(hex.map { Character(UnicodeScalar(UInt8(97) + UInt8($0.hexDigitValue!))) })
    }

    /// The one step the app cannot do: the browser only loads an unpacked extension the user picks.
    @MainActor
    static func showExtensionInstructions() {
        let path = extensionDir.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        let alert = NSAlert()
        alert.messageText = "Add the Hoardini extension to your browser"
        alert.informativeText = """
            1. Open chrome://extensions (Brave: brave://extensions, Edge: edge://extensions).
            2. Turn on Developer mode and click "Load unpacked".
            3. Press ⌘⇧G, paste with ⌘V (the folder path is on your clipboard), press Return, click Select.

            \(path)

            You only need to do this once. When you update Hoardini by dragging in a new version, \
            open it once, then click Reload on the extension.
            """
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Show Folder in Finder")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([extensionDir])
        }
    }
}
