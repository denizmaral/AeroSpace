@testable import AppBundle
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct SettingsRepositoryTest {
    private let store = SettingsRepository(directory: FileManager.default.temporaryDirectory.appending(path: "SettingsRepositoryTest-\(UUID().uuidString)"))

    private func settings(focusFollowsMouse: Bool) -> Settings {
        var settings = Settings()
        settings.general.focusFollowsMouse = focusFollowsMouse
        settings.modes = [Settings.BindingMode(name: "main", shortcuts: [Settings.Shortcut(chord: KeyChord([.option], .h), actions: [.focus(.left)])])]
        return settings
    }

    @Test func testFirstLaunchHasNoSettings() {
        assertEquals(store.load(), .none)
    }

    @Test func testSavedSettingsAreLoadedAndOnlyTheUserCanReadThem() throws {
        try store.save(settings(focusFollowsMouse: true))
        assertEquals(store.load(), .loaded(settings(focusFollowsMouse: true)))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileUrl.path)
        assertEquals((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// A flipped byte is detected by the checksum: the backup (the previous valid save) is used, the damaged file is kept
    @Test func testDamagedFileIsReplacedByTheBackup() throws {
        try store.save(settings(focusFollowsMouse: false))
        try store.save(settings(focusFollowsMouse: true))
        try flipLastByte(store.fileUrl)

        guard case .restoredFromBackup(let restored, let damaged) = store.load() else {
            Issue.record("Expected the backup")
            return
        }
        assertEquals(restored, settings(focusFollowsMouse: false))
        #expect(FileManager.default.fileExists(atPath: damaged.path))
        // The file itself is good again
        try FileManager.default.removeItem(at: store.backupUrl)
        assertEquals(store.load(), .loaded(settings(focusFollowsMouse: false)))
    }

    /// Damage that still decodes (e.g. a flipped bit in a value) is found by the checksum
    @Test func testChecksumFindsDamageThatStillDecodes() throws {
        try store.save(settings(focusFollowsMouse: true))
        let original = try Data(contentsOf: store.fileUrl)
        try store.save(settings(focusFollowsMouse: false))
        let other = try Data(contentsOf: store.fileUrl)
        // The payload of the other settings with the length and the checksum of the original
        let headerSize = 44
        var damaged = original.prefix(headerSize)
        damaged.replaceSubrange(8 ..< 12, with: other[8 ..< 12])
        damaged.append(other.dropFirst(headerSize))
        try damaged.write(to: store.fileUrl)
        try FileManager.default.removeItem(at: store.backupUrl)

        guard case .unreadable = store.load() else {
            Issue.record("Expected unreadable")
            return
        }
    }

    /// Never silently defaults: nothing on the disk is changed
    @Test func testDamagedFileWithoutBackupIsUnreadableAndUntouched() throws {
        try store.save(settings(focusFollowsMouse: true))
        try flipLastByte(store.fileUrl)
        let damaged = try Data(contentsOf: store.fileUrl)

        guard case .unreadable = store.load() else {
            Issue.record("Expected unreadable")
            return
        }
        assertEquals(try Data(contentsOf: store.fileUrl), damaged)
    }

    /// A crash between the two renames of a save leaves only the backup
    @Test func testOnlyTheBackupIsLeft() throws {
        try store.save(settings(focusFollowsMouse: false))
        try store.save(settings(focusFollowsMouse: true))
        try FileManager.default.removeItem(at: store.fileUrl)
        assertEquals(store.load(), .loaded(settings(focusFollowsMouse: false)))
    }

    /// A damaged file doesn't push the good backup out
    @Test func testSavingOverADamagedFileKeepsTheBackup() throws {
        try store.save(settings(focusFollowsMouse: false))
        try store.save(settings(focusFollowsMouse: true))
        try flipLastByte(store.fileUrl)
        try store.save(settings(focusFollowsMouse: true))
        try FileManager.default.removeItem(at: store.fileUrl)
        assertEquals(store.load(), .loaded(settings(focusFollowsMouse: false)))
    }

    @Test func testSettingsOfANewerMarSpaceAreNotRead() throws {
        var newer = settings(focusFollowsMouse: true)
        newer.schemaVersion = Settings.currentSchemaVersion + 1
        try store.save(newer)
        guard case .unreadable(let reason) = store.load() else {
            Issue.record("Expected unreadable")
            return
        }
        #expect(reason.contains("newer"))
    }

    /// A save never overwrites a file that can't be read (written by a newer MarSpace): it's kept aside, byte for byte
    @Test func testSavingOverSettingsOfANewerMarSpaceKeepsThemAside() throws {
        var newer = settings(focusFollowsMouse: true)
        newer.schemaVersion = Settings.currentSchemaVersion + 1
        try store.save(newer)
        let newerBytes = try Data(contentsOf: store.fileUrl)
        try store.save(settings(focusFollowsMouse: false))
        assertEquals(store.load(), .loaded(settings(focusFollowsMouse: false)))
        assertEquals(try keptAside("unreadable"), [newerBytes])
    }

    @Test func testSavingOverADamagedFileWithoutBackupKeepsItAside() throws {
        try store.save(settings(focusFollowsMouse: true))
        try flipLastByte(store.fileUrl)
        let damaged = try Data(contentsOf: store.fileUrl)
        try store.save(settings(focusFollowsMouse: false))
        assertEquals(try keptAside("unreadable"), [damaged])
    }

    /// `reload-config --dry-run`: the backup is read, the disk isn't changed
    @Test func testLoadingWithoutRepairDoesNotChangeTheDisk() throws {
        try store.save(settings(focusFollowsMouse: false))
        try store.save(settings(focusFollowsMouse: true))
        try flipLastByte(store.fileUrl)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        let damaged = try Data(contentsOf: store.fileUrl)
        assertEquals(store.load(repair: false), .loaded(settings(focusFollowsMouse: false)))
        assertEquals(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted(), files)
        assertEquals(try Data(contentsOf: store.fileUrl), damaged)
    }

    private func keptAside(_ kind: String) throws -> [Data] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
            .filter { $0.hasPrefix("Settings.\(kind)-") }
            .map { try Data(contentsOf: store.directory.appending(path: $0)) }
    }

    private func flipLastByte(_ url: URL) throws {
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0xFF
        try data.write(to: url)
    }
}
