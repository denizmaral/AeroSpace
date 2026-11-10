import CryptoKit
import Foundation

/// Stores the settings in `~/Library/Application Support/MarSpace`. The user never sees or edits the file.
///
/// Safety:
/// - Integrity: a header with the SHA-256 of the payload. A damaged file is detected, never half read
/// - Atomic: the new file is written next to the old one and renamed over it. The previous valid file becomes the backup.
///   A crash at any point leaves a valid file or a valid backup
/// - A damaged file is replaced by the backup (and kept aside for diagnosis), never silently by defaults
/// - A file that can't be read (damaged, or written by a newer MarSpace) is never overwritten: a save keeps it aside
/// - Only the user can read and write it (0600, the folder 0700)
/// - Versioned: settings written by a newer MarSpace are not read
///
/// Format (little-endian):
/// ```
/// magic:         UInt32 "MSST"
/// formatVersion: UInt16 (1)
/// reserved:      UInt16
/// payloadLength: UInt32
/// sha256:        32 bytes, of the payload
/// payload:       binary property list of Settings
/// ```
struct SettingsStore: Sendable {
    let directory: URL

    static let applicationSupport = SettingsStore(
        directory: URL.applicationSupportDirectory.appending(path: "MarSpace", directoryHint: .isDirectory),
    )

    var fileUrl: URL { directory.appending(path: "Settings.marspace") }
    var backupUrl: URL { directory.appending(path: "Settings.backup.marspace") }

    enum LoadResult: Equatable {
        case loaded(Settings)
        /// First launch: nothing stored yet
        case none
        /// The file was damaged. It was replaced by the backup and kept aside for diagnosis
        case restoredFromBackup(Settings, damagedFileKeptAt: URL)
        /// Neither the file nor the backup can be read. Nothing was changed on the disk
        case unreadable(reason: String)
    }

    /// `repair`: a damaged file is replaced by the backup on the disk. Without it, the disk isn't changed (a dry run)
    func load(repair: Bool = true) -> LoadResult {
        let manager = FileManager.default
        let fileExists = manager.fileExists(atPath: fileUrl.path)
        let backupExists = manager.fileExists(atPath: backupUrl.path)
        if !fileExists, !backupExists { return .none }
        let main = fileExists ? Self.read(fileUrl) : .failure(.missing)
        if case .success(let settings) = main { return .loaded(settings) }
        if case .failure(.newerVersion(let version)) = main {
            return .unreadable(reason: "The settings were written by a newer MarSpace (schema \(version))")
        }
        guard backupExists, case .success(let settings) = Self.read(backupUrl) else {
            return .unreadable(reason: "The settings file is damaged and there is no valid backup: \(main.failureDescription)")
        }
        guard repair else { return .loaded(settings) }
        // A crash between the two renames of `save` leaves only the backup: nothing to keep aside
        let damaged = asideUrl("damaged")
        if fileExists { try? manager.moveItem(at: fileUrl, to: damaged) }
        try? manager.copyItem(at: backupUrl, to: fileUrl)
        return fileExists ? .restoredFromBackup(settings, damagedFileKeptAt: damaged) : .loaded(settings)
    }

    func save(_ settings: Settings) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = Self.header(for: try encoder.encode(settings))

        let temporary = directory.appending(path: ".Settings-\(UUID().uuidString).marspace")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        // The previous file becomes the backup only if it's valid: a damaged file must not replace a good backup. A file
        // that can't be read (damaged, or written by a newer MarSpace) is kept aside, never overwritten
        if manager.fileExists(atPath: fileUrl.path) {
            switch Self.read(fileUrl) {
                case .success: try Self.rename(fileUrl, to: backupUrl)
                case .failure: try manager.moveItem(at: fileUrl, to: asideUrl("unreadable"))
            }
        }
        try Self.rename(temporary, to: fileUrl)
    }

    /// A copy of the file as it is, once: e.g. before a migration, an older MarSpace can still read the copy
    func keepCopy(named name: String) {
        let copy = directory.appending(path: name)
        guard !FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.copyItem(at: fileUrl, to: copy)
    }

    /// A file kept aside for the user or for diagnosis, e.g. `Settings.damaged-1762800000-1A2B3C4D.marspace`
    private func asideUrl(_ kind: String) -> URL {
        directory.appending(path: "Settings.\(kind)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).marspace")
    }

    private enum ReadFailure: Error {
        case missing
        case damaged(String)
        case newerVersion(Int)
    }

    private static let magic: UInt32 = 0x5453_534D // "MSST" little-endian
    private static let formatVersion: UInt16 = 1
    private static let headerSize = 44

    private static func header(for payload: Data) -> Data {
        var data = Data(capacity: headerSize + payload.count)
        data.appendLE(magic)
        data.appendLE(formatVersion)
        data.appendLE(UInt16(0))
        data.appendLE(UInt32(payload.count))
        data.append(contentsOf: SHA256.hash(data: payload))
        data.append(payload)
        return data
    }

    private static func read(_ url: URL) -> Result<Settings, ReadFailure> {
        // Memory-mapped: nothing is copied before the checksum says the data is good
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return .failure(.missing) }
        guard data.count >= headerSize, data.loadLE(UInt32.self, at: 0) == magic else { return .failure(.damaged("not a settings file")) }
        guard data.loadLE(UInt16.self, at: 4) == formatVersion else { return .failure(.damaged("unknown format")) }
        let payloadLength = Int(data.loadLE(UInt32.self, at: 8))
        guard data.count == headerSize + payloadLength else { return .failure(.damaged("wrong length")) }
        let payload = data[(data.startIndex + headerSize)...]
        guard Data(SHA256.hash(data: payload)) == data[(data.startIndex + 12) ..< (data.startIndex + headerSize)] else {
            return .failure(.damaged("checksum mismatch"))
        }
        guard let settings = try? PropertyListDecoder().decode(Settings.self, from: payload) else {
            // A newer schema may not decode: tell it apart from damage
            if let version = (try? PropertyListDecoder().decode(SchemaVersionOnly.self, from: payload))?.schemaVersion,
               version > Settings.currentSchemaVersion
            {
                return .failure(.newerVersion(version))
            }
            return .failure(.damaged("can't decode the settings"))
        }
        guard settings.schemaVersion <= Settings.currentSchemaVersion else { return .failure(.newerVersion(settings.schemaVersion)) }
        return .success(settings)
    }

    private struct SchemaVersionOnly: Decodable { let schemaVersion: Int }

    /// Atomic: the destination is the old or the new file, never something in between
    private static func rename(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }
}

extension Result {
    fileprivate var failureDescription: String {
        if case .failure(let error) = self { return "\(error)" }
        return ""
    }
}
