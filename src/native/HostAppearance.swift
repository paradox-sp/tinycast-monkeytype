import AppKit
import Darwin

/// Tinycast's persisted appearance policy, not its resolved light/dark launch snapshot.
enum HostAppearance: String {
    case system, light, dark

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class HostAppearanceObserver {
    static let supportedHosts: Set<String> = ["com.tinycast.app", "com.tinycast.app.beta", "com.tinycast.app.dev"]

    private struct Modification: Equatable {
        let inode: ino_t
        let seconds: Int
        let nanoseconds: Int
        let size: off_t
    }

    let domain: String
    private let preferencesPath: String
    private let onChange: (HostAppearance) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var modification: Modification?
    private var selection: HostAppearance?

    init(domain: String, onChange: @escaping (HostAppearance) -> Void) {
        self.domain = domain
        self.onChange = onChange
        preferencesPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist").path
    }

    isolated deinit { stop() }

    func start() throws {
        stop()
        // Watch the directory: cfprefsd can replace the plist atomically, or create it later.
        guard let watcher = watch(path: (preferencesPath as NSString).deletingLastPathComponent, events: [.write]) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Could not observe Tinycast’s appearance preference."
            ])
        }
        source = watcher
        refresh(force: true)
    }

    private func watch(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: events, queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
        watcher.setCancelHandler { Darwin.close(descriptor) }
        watcher.resume()
        return watcher
    }

    func stop() {
        source?.cancel()
        source = nil
        fileSource?.cancel()
        fileSource = nil
    }

    private func refresh(force: Bool) {
        var attributes = Darwin.stat()
        let latest: Modification?
        if Darwin.lstat(preferencesPath, &attributes) == 0 {
            latest = Modification(inode: attributes.st_ino, seconds: attributes.st_mtimespec.tv_sec,
                nanoseconds: attributes.st_mtimespec.tv_nsec, size: attributes.st_size)
        } else {
            latest = nil
        }
        guard force || latest != modification else { return }
        if force || latest?.inode != modification?.inode {
            fileSource?.cancel()
            fileSource = latest == nil ? nil : watch(path: preferencesPath, events: [.write, .extend, .delete, .rename, .revoke])
        }
        modification = latest
        // Only the appearance key is read. No host preferences are written or imported.
        CFPreferencesAppSynchronize(domain as CFString)
        let raw = CFPreferencesCopyAppValue("appearance" as CFString, domain as CFString) as? String
        // This is Tinycast's own default for an absent/unrecognised value.
        let updated = raw.flatMap(HostAppearance.init(rawValue:)) ?? .system
        guard force || updated != selection else { return }
        selection = updated
        onChange(updated)
    }
}
