import Foundation

/// Where the app keeps its files, under its own name. The folders once carried the app's
/// working name; what is found under that name is moved over at the first start.
enum AppFolders {
    static let name = "Phone Mac Link"
    static let formerName = "WinPhone"
    static let logName = "phone-mac-link.log"
    static let formerLogName = "winphone.log"

    private static func library(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask)[0]
    }

    /// Content caches, sealed; one file per kind and phone.
    static var support: URL { library(.applicationSupportDirectory).appendingPathComponent(name, isDirectory: true) }
    /// Files on their way in, and other things that may be thrown away.
    static var caches: URL { library(.cachesDirectory).appendingPathComponent(name, isDirectory: true) }
    static var logs: URL { library(.libraryDirectory).appendingPathComponent("Logs/\(name)", isDirectory: true) }
    static var log: URL { logs.appendingPathComponent(logName) }

    /// Moves what an earlier build left under the former name. Run once, before anything is
    /// opened there.
    static func adoptFormerFolders() {
        let manager = FileManager.default
        adopt(in: library(.applicationSupportDirectory), manager: manager)
        adopt(in: library(.cachesDirectory), manager: manager)
        let logs = library(.libraryDirectory).appendingPathComponent("Logs", isDirectory: true)
        adopt(in: logs, manager: manager)
        // The log and the one before it, under the new file name.
        for suffix in ["", ".1"] {
            let old = self.logs.appendingPathComponent(formerLogName + suffix), new = self.logs.appendingPathComponent(logName + suffix)
            if manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) { try? manager.moveItem(at: old, to: new) }
        }
    }

    /// The former folder becomes the new one; where both exist, the former one's files that
    /// the new one lacks are moved in, and the former folder goes when it is empty.
    static func adopt(in parent: URL, manager: FileManager = .default) {
        let old = parent.appendingPathComponent(formerName, isDirectory: true), new = parent.appendingPathComponent(name, isDirectory: true)
        guard manager.fileExists(atPath: old.path) else { return }
        if !manager.fileExists(atPath: new.path) {
            try? manager.moveItem(at: old, to: new)
            return
        }
        for item in (try? manager.contentsOfDirectory(atPath: old.path)) ?? [] {
            let target = new.appendingPathComponent(item)
            if !manager.fileExists(atPath: target.path) { try? manager.moveItem(at: old.appendingPathComponent(item), to: target) }
        }
        if ((try? manager.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty { try? manager.removeItem(at: old) }
    }
}
