import XCTest
@testable import FM1Hub

/// The library is the only record of what was installed, which backups exist, and which update was interrupted.
/// It is written as JSON with ISO-8601 dates; these tests put a real store through a cold launch, because the way
/// this breaks is silent: a decoder that disagrees with the encoder returns an empty library and nothing says so.
@MainActor
final class LibraryStoreTests: XCTestCase {
    /// Where the store under test keeps its library. A folder of its own per test, so nothing these tests write or
    /// delete can touch the real library or the rescue files the app promises its user it will keep.
    private var folder = URL(fileURLWithPath: NSTemporaryDirectory())
    private var libraryFile: URL { folder.appendingPathComponent("library.json") }

    /// The rescue copies are named after a hash of their own bytes, so they are found by prefix.
    private func rescueFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("library-unreadable") }
    }

    private let aRecord = InstallRecord(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        date: Date(timeIntervalSince1970: 1_761_000_000),
        firmwareId: "felucca", name: "Felucca", version: "1.4", product: "FM-1_900", sha256: "a1b2",
        identityBefore: "FM-1_015", identityAfter: "FM-1_900", source: .hub, success: true)

    private let aSnapshot = Snapshot(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        date: Date(timeIntervalSince1970: 1_761_000_500),
        name: "Before install", identity: "FM-1_900", firmwareId: "felucca", firmwareName: "Felucca",
        version: "1.4", product: "FM-1_900", packageFile: "package.fwsc", packageSHA256: "a1b2",
        packageSize: 699_956, packageExact: true, archiveFile: "felucca-backup.json",
        archiveBytes: 2048, archiveObjects: 13)

    private let aPending = PendingUpdate(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        date: Date(timeIntervalSince1970: 1_761_000_000),
        product: "FM-1_904", sha256: "beefbeef", firmwareId: "melodee", name: "Melodee", version: "2.0",
        usesStockLoader: false, source: .hub)

    /// Runs the body against an empty library in a directory created for this test alone, and takes it away after.
    private func withCleanLibrary(_ body: () throws -> Void) rethrows {
        let fm = FileManager.default
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FM1HubLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try body()
    }

    func testHistoryAndBackupsSurviveAColdLaunch() {
        withCleanLibrary {
            let store = LibraryStore(folder: folder)
            XCTAssertTrue(store.history.isEmpty)
            store.add(aRecord)
            store.add(aSnapshot)
            XCTAssertNil(store.problem, "writing the library must not fail")

            let reloaded = LibraryStore(folder: folder)
            XCTAssertNil(reloaded.problem)
            XCTAssertEqual(reloaded.history, [aRecord], "the install history must still be there after a relaunch")
            XCTAssertEqual(reloaded.snapshots, [aSnapshot], "the backup index must still be there after a relaunch")
            XCTAssertEqual(reloaded.history.first?.date, aRecord.date, "and the dates come back unchanged")
        }
    }

    func testTheNewestEntriesComeFirst() {
        withCleanLibrary {
            let store = LibraryStore(folder: folder)
            store.add(aRecord)
            store.add(InstallRecord(date: Date(timeIntervalSince1970: 1_761_900_000), firmwareId: nil,
                                    name: "newer", version: "", product: "FM-1_016", sha256: nil,
                                    identityBefore: nil, identityAfter: "FM-1_016", source: .stock, success: true))
            XCTAssertEqual(LibraryStore(folder: folder).history.map(\.name), ["newer", "Felucca"])
        }
    }

    /// Each backup keeps its own record, so the index can be rebuilt from the folders.
    func testABackupMissingFromTheIndexIsFoundAgainFromItsFolder() throws {
        try withCleanLibrary {
            LibraryStore(folder: folder).add(aSnapshot)
            try FileManager.default.removeItem(at: libraryFile)

            XCTAssertEqual(LibraryStore(folder: folder).snapshots, [aSnapshot])
        }
    }

    func testWhatAFirmwareSaidOfItselfSurvivesAColdLaunch() {
        withCleanLibrary {
            var s = aSnapshot
            s.reportedName = "SLOOP 2.8.4"
            s.packageConfirmed = true
            LibraryStore(folder: folder).add(s)
            XCTAssertEqual(LibraryStore(folder: folder).snapshots, [s])
        }
    }

    func testABackupRecordFromBeforeThoseFieldsStillReads() throws {
        try withCleanLibrary {
            let id = "44444444-4444-4444-4444-444444444444"
            let dir = folder.appendingPathComponent("Snapshots/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let old = #"{"id":"\#(id)","date":"2026-10-30T08:00:00Z","name":"Old","identity":"FM-1_900","firmwareName":"Hortator","packageExact":true,"notes":""}"#
            try Data(old.utf8).write(to: dir.appendingPathComponent("snapshot.json"))

            let found = try XCTUnwrap(LibraryStore(folder: folder).snapshots.first)
            XCTAssertEqual(found.name, "Old")
            XCTAssertNil(found.reportedName)
            XCTAssertNil(found.packageConfirmed, "it is not known to be the firmware that was on the device")
        }
    }

    func testASloopBackupIsFoundAgainFromItsArchive() throws {
        try withCleanLibrary {
            let id = UUID()
            let dir = folder.appendingPathComponent("Snapshots/\(id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let archive = SloopArchive(format: SloopArchive.formatName, version: 1, firmware: "FELUCCA SLOOP 2.8.4", date: "2026-10-31T08:00:00Z",
                                       objects: [SloopArchiveObject(id: 1, len: 0, crc: 0, data: "")])
            try JSONEncoder().encode(archive).write(to: dir.appendingPathComponent(SloopArchive.fileName))

            let found = try XCTUnwrap(LibraryStore(folder: folder).snapshots.first)
            XCTAssertEqual(found.id, id)
            XCTAssertTrue(found.hasSloopArchive)
            XCTAssertEqual(found.firmwareName, "SLOOP 2.8.4")
            XCTAssertEqual(found.reportedName, "SLOOP 2.8.4")
            XCTAssertEqual(found.date, ISO8601DateFormatter().date(from: archive.date))
        }
    }

    func testAPackageBesideASloopArchiveIsNotTakenForExact() throws {
        try withCleanLibrary {
            let dir = folder.appendingPathComponent("Snapshots/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let archive = SloopArchive(format: SloopArchive.formatName, version: 1, firmware: "FELUCCA SLOOP 2.8.4", date: "2026-10-31T08:00:00Z", objects: [])
            try JSONEncoder().encode(archive).write(to: dir.appendingPathComponent(SloopArchive.fileName))
            try FWSCPackageTests.makePackage(product: "FM-1_900").write(to: dir.appendingPathComponent("package.fwsc"))

            let found = try XCTUnwrap(LibraryStore(folder: folder).snapshots.first)
            XCTAssertEqual(found.identity, "FM-1_900")
            XCTAssertFalse(found.packageExact)
        }
    }

    func testACorruptLibraryStillFindsItsBackups() throws {
        try withCleanLibrary {
            let store = LibraryStore(folder: folder)
            store.add(aRecord)
            store.add(aSnapshot)
            try Data("not json".utf8).write(to: libraryFile)

            let reloaded = LibraryStore(folder: folder)
            XCTAssertEqual(reloaded.snapshots, [aSnapshot], "the folders are untouched by a bad index")
            XCTAssertTrue(reloaded.history.isEmpty, "only the index knew the history")
            XCTAssertEqual(rescueFiles().count, 1, "and the bad index is still kept")
        }
    }

    /// A library that can't be read yet may hold a better record of the same backups, so the folders wait for it.
    func testAHeldLibraryIsNotOverruledByTheFolders() throws {
        try withCleanLibrary {
            var indexed = aSnapshot
            indexed.name = "Named in the index"
            let store = LibraryStore(folder: folder)
            store.add(aSnapshot)
            store.update(indexed)
            let dir = store.folder(for: indexed)
            try Data("no record".utf8).write(to: dir.appendingPathComponent("snapshot.json"))

            let reads = Reads()
            let held = LibraryStore(folder: folder, readData: { try reads.read($0) })
            XCTAssertTrue(held.snapshots.isEmpty, "nothing is rebuilt while the library is held")
            XCTAssertNil(held.writeProblem, "and nothing tried to write over it")

            reads.allowed = true
            held.flush()
            XCTAssertEqual(held.snapshots, [indexed], "the index comes back, and its name wins")
        }
    }

    func testAnInterruptedUpdateIsStillKnownAfterARelaunch() throws {
        try withCleanLibrary {
            let store = LibraryStore(folder: folder)
            XCTAssertNil(store.pending)
            try store.beginAttempt(aPending)
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending, "Resume depends on this surviving the relaunch")

            try store.clearPending()
            XCTAssertNil(LibraryStore(folder: folder).pending, "a finished update leaves nothing to resume")
            XCTAssertNil(store.problem)
        }
    }

    /// An attempt that never reached the device puts the earlier record back, so a half-written update is not
    /// forgotten because the user tapped Install on something else.
    func testRestorePendingPutsAnEarlierRecordBack() throws {
        try withCleanLibrary {
            let store = LibraryStore(folder: folder)
            try store.beginAttempt(aPending)
            let other = PendingUpdate(product: "FM-1_016", sha256: "cafe", firmwareId: nil,
                                      name: "Official firmware", version: "V16", usesStockLoader: true, source: .stock)
            let token = try store.beginAttempt(other)
            XCTAssertEqual(store.pending, other)

            try store.abandonAttempt(token)
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending, "the half-written update is the one to resume")
        }
    }

    func testPendingAndHistoryAreIndependent() throws {
        try withCleanLibrary {
            let store = LibraryStore(folder: folder)
            try store.beginAttempt(aPending)
            store.add(aRecord)
            let reloaded = LibraryStore(folder: folder)
            XCTAssertEqual(reloaded.pending?.sha256, "beefbeef",
                           "a successful install of something else must not become the thing to resume")
            XCTAssertEqual(reloaded.history.count, 1)
        }
    }

    func testClearingHistoryKeepsTheBackups() {
        withCleanLibrary {
            let store = LibraryStore(folder: folder)
            store.add(aRecord)
            store.add(aSnapshot)
            store.clearHistory()
            let reloaded = LibraryStore(folder: folder)
            XCTAssertTrue(reloaded.history.isEmpty)
            XCTAssertEqual(reloaded.snapshots.count, 1)
        }
    }

    func testInstallCountOnlyCountsSuccesses() {
        withCleanLibrary {
            let store = LibraryStore(folder: folder)
            store.add(aRecord)
            store.add(InstallRecord(firmwareId: "felucca", name: "Felucca", version: "1.4", product: "FM-1_900",
                                    sha256: "a1b2", identityBefore: nil, identityAfter: nil, source: .hub,
                                    success: false, error: "stopped"))
            XCTAssertEqual(store.installCount(firmwareId: "felucca"), 1)
            XCTAssertEqual(store.installCount(firmwareId: "nobody"), 0)
        }
    }

    /// A library from an older build carries Foundation's numeric dates; it is read, not thrown away.
    func testReadsALibraryWithNumericDates() throws {
        try withCleanLibrary {
            let json = """
            {"history":[{"date":752000000,"id":"44444444-4444-4444-4444-444444444444","name":"Felucca",\
            "product":"FM-1_900","source":"hub","success":true,"version":"1.4"}],"snapshots":[]}
            """
            try Data(json.utf8).write(to: libraryFile)
            let store = LibraryStore(folder: folder)
            XCTAssertNil(store.problem)
            XCTAssertEqual(store.history.count, 1)
            XCTAssertEqual(store.history.first?.date, Date(timeIntervalSinceReferenceDate: 752_000_000))
        }
    }

    /// A library that cannot be read is said out loud and kept for rescue, never silently replaced.
    func testAnUnreadableLibraryIsReportedAndKept() throws {
        try withCleanLibrary {
            try Data("this is not JSON".utf8).write(to: libraryFile)
            let store = LibraryStore(folder: folder)
            XCTAssertNotNil(store.problem, "an unreadable library must be reported, not swallowed")
            XCTAssertTrue(store.history.isEmpty)
            let kept = rescueFiles()
            XCTAssertEqual(kept.count, 1, "the old file is kept so it can be rescued from the Files app")
            XCTAssertEqual(try Data(contentsOf: kept[0]), Data("this is not JSON".utf8))
            XCTAssertTrue(store.problem?.contains(kept[0].lastPathComponent) == true,
                          "the message names the file the user has to go and find")
        }
    }

    // MARK: When the disk says no

    /// A writer that refuses the rescue copies while letting library.json through, so the "do not write over the
    /// only copy of the history" rule can be driven from both sides.
    private final class Gate {
        var blockRescues = true
        func write(_ data: Data, _ url: URL) throws {
            if blockRescues, url.lastPathComponent != "library.json" { throw Disk.Full() }
            try data.write(to: url, options: .atomic)
        }
    }

    /// A reader that refuses until it is told not to, so "the original cannot even be read" can be driven.
    private final class Reads {
        var allowed = false
        func read(_ url: URL) throws -> Data {
            guard allowed else { throw Disk.Full() }
            return try Data(contentsOf: url)
        }
    }

    /// A writer that fails until it is told to stop failing, so the recovery policies can be tested exactly.
    private final class Disk {
        struct Full: LocalizedError { var errorDescription: String? { "the disk is full" } }
        var failing = true
        func write(_ data: Data, _ url: URL) throws {
            if failing { throw Full() }
            try data.write(to: url, options: .atomic)
        }
    }

    /// Before the device is touched: if the record is not durable the install must be refused, and the app must go
    /// on believing exactly what the disk says.
    func testSetPendingThrowsAndChangesNothingWhenItCannotBeWritten() throws {
        try withCleanLibrary {
            let disk = Disk()
            let store = LibraryStore(folder: folder) { try disk.write($0, $1) }
            XCTAssertThrowsError(try store.beginAttempt(aPending)) { e in
                XCTAssertEqual((e as? FM1Error)?.code, "package")
            }
            XCTAssertNil(store.pending, "nothing on disk means nothing in the app either")
            XCTAssertNotNil(store.writeProblem)
            XCTAssertNil(LibraryStore(folder: folder).pending)
        }
    }

    /// After a verified install: the cleared state stands even though its own write failed, and the very next
    /// write — the successful install record — carries it to the disk. The stale record must not come back.
    func testAFailedClearIsFinishedByTheNextWrite() throws {
        try withCleanLibrary {
            let disk = Disk()
            disk.failing = false
            let store = LibraryStore(folder: folder) { try disk.write($0, $1) }
            try store.beginAttempt(aPending)
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending)

            disk.failing = true
            XCTAssertThrowsError(try store.clearPending())
            XCTAssertNil(store.pending, "the install finished: there is nothing left to resume, disk or no disk")
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending, "the disk is still behind, as expected")

            disk.failing = false
            store.add(aRecord)
            let reloaded = LibraryStore(folder: folder)
            XCTAssertNil(reloaded.pending, "the history write carried the clear through")
            XCTAssertEqual(reloaded.history, [aRecord])
            XCTAssertNil(store.writeProblem)
        }
    }

    /// Putting an earlier record back after an attempt that never reached the device: same policy, and the failure
    /// is reported rather than passed off as done.
    func testAFailedRestoreKeepsTheEarlierRecordInMemoryAndSaysSo() throws {
        try withCleanLibrary {
            let disk = Disk()
            disk.failing = false
            let store = LibraryStore(folder: folder) { try disk.write($0, $1) }
            try store.beginAttempt(aPending)
            let other = PendingUpdate(product: "FM-1_016", sha256: "cafe", firmwareId: nil, name: "Official firmware",
                                      version: "V16", usesStockLoader: true, source: .stock)
            let token = try store.beginAttempt(other)

            disk.failing = true
            XCTAssertThrowsError(try store.abandonAttempt(token))
            XCTAssertEqual(store.pending, aPending, "the half-written update is the truth, written or not")
            XCTAssertNotNil(store.writeProblem, "and the app says the disk has not caught up")

            disk.failing = false
            store.add(aRecord)
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending)
        }
    }

    /// A rescue notice is about history that is gone for good; no amount of successful writing makes it untrue.
    func testTheRescueNoticeOutlivesLaterWritesAndOnlyTheUserPutsItAway() throws {
        try withCleanLibrary {
            try Data("this is not JSON".utf8).write(to: libraryFile)
            let store = LibraryStore(folder: folder)
            XCTAssertFalse(store.rescueNotes.isEmpty)

            store.add(aRecord)
            XCTAssertNil(store.writeProblem, "that write succeeded")
            XCTAssertFalse(store.rescueNotes.isEmpty, "but the old history is still only in the rescue file")
            XCTAssertEqual(store.notices.map(\.kind), [.rescue])

            // and it is still there in the next launch, because the file still has to be fetched
            let relaunched = LibraryStore(folder: folder)
            XCTAssertEqual(relaunched.rescueNotes.first, store.rescueNotes.first,
                           "a successful write replaced library.json, but not the lost history")
            XCTAssertNotNil(relaunched.rescueNotes.first?.file)

            store.dismiss(store.notices[0])
            XCTAssertTrue(store.rescueNotes.isEmpty)
            XCTAssertNil(LibraryStore(folder: folder).rescueNotes.first, "dismissing it is remembered too")
            XCTAssertTrue(store.notices.isEmpty)
        }
    }

    func testBothNoticesAreShownWorstFirst() throws {
        try withCleanLibrary {
            try Data("this is not JSON".utf8).write(to: libraryFile)
            let disk = Disk()
            let store = LibraryStore(folder: folder) { try disk.write($0, $1) }
            XCTAssertFalse(store.rescueNotes.isEmpty)
            store.add(aRecord)
            XCTAssertEqual(store.notices.map(\.kind), [.write, .rescue])
            XCTAssertFalse(store.notices[0].dismissible, "a write problem clears itself when a write succeeds")
            XCTAssertTrue(store.notices[1].dismissible)
        }
    }

    /// A second corruption must not quietly retire the first one's warning: the folder is the record.
    func testTwoCorruptionsLeaveTwoOutstandingRescues() throws {
        try withCleanLibrary {
            try Data("first bad library".utf8).write(to: libraryFile)
            let first = LibraryStore(folder: folder)
            XCTAssertEqual(first.rescueNotes.count, 1)
            first.add(aRecord)                                  // a valid library replaces the bad one

            try Data("second bad library".utf8).write(to: libraryFile)
            let second = LibraryStore(folder: folder)
            XCTAssertEqual(rescueFiles().count, 2, "two different bad libraries, two copies")
            XCTAssertEqual(second.rescueNotes.count, 2, "and both are still waiting to be fetched")
            XCTAssertEqual(Set(second.notices.map(\.id)).count, 2, "each has its own notice")

            // putting one away leaves the other
            let one = second.notices.first { $0.kind == .rescue }!
            second.dismiss(one)
            XCTAssertEqual(second.rescueNotes.count, 1)
            XCTAssertEqual(LibraryStore(folder: folder).rescueNotes.count, 1)
        }
    }

    /// Two different bad payloads must never share a rescue name, whatever their timestamps say: the name is the
    /// full hash of the bytes, so nothing but identical content can map to the same file.
    func testTwoBadPayloadsWithTheSameDateAreKeptApart() throws {
        try withCleanLibrary {
            let when = Date(timeIntervalSince1970: 1_761_000_000)
            try Data("payload one".utf8).write(to: libraryFile)
            try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: libraryFile.path)
            _ = LibraryStore(folder: folder)

            try Data("payload two".utf8).write(to: libraryFile)
            try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: libraryFile.path)
            let store = LibraryStore(folder: folder)

            XCTAssertEqual(rescueFiles().count, 2, "the name follows the bytes, not the clock")
            let kept = try Set(rescueFiles().map { try Data(contentsOf: $0) })
            XCTAssertEqual(kept, [Data("payload one".utf8), Data("payload two".utf8)], "both payloads survive")
            XCTAssertEqual(store.rescueNotes.count, 2)
            for u in rescueFiles() {
                let hash = u.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "library-unreadable-", with: "")
                XCTAssertEqual(hash.count, 64, "the whole digest, not a prefix that could collide")
                XCTAssertEqual(hash, FWSCPackage.sha256Hex(try Data(contentsOf: u)), "the name is the content")
            }
        }
    }

    /// Putting a notice away has to stick through a later corruption too: the list of outstanding rescues is
    /// rebuilt from the folder, so a dismissed file must no longer look outstanding.
    func testADismissedRescueDoesNotComeBackOnTheNextCorruption() throws {
        try withCleanLibrary {
            try Data("bad library A".utf8).write(to: libraryFile)
            let first = LibraryStore(folder: folder)
            let noticeA = first.notices.first { $0.kind == .rescue }!
            first.dismiss(noticeA)
            XCTAssertTrue(first.rescueNotes.isEmpty)
            XCTAssertEqual(rescueFiles().count, 0, "A is no longer outstanding")

            try Data("bad library B".utf8).write(to: libraryFile)
            let second = LibraryStore(folder: folder)
            XCTAssertEqual(second.rescueNotes.count, 1, "only B is waiting to be fetched")
            XCTAssertNotEqual(second.rescueNotes[0].file, noticeA.file)
        }
    }

    /// The user said they have the file; it is still theirs, just not shouted about any more.
    func testADismissedRescueFileIsKeptUnderItsOwnName() throws {
        try withCleanLibrary {
            try Data("bad library A".utf8).write(to: libraryFile)
            let store = LibraryStore(folder: folder)
            store.dismiss(store.notices.first { $0.kind == .rescue }!)

            let all = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let rescued = all.filter { $0.lastPathComponent.hasPrefix("library-rescued-") }
            XCTAssertEqual(rescued.count, 1, "the bytes are not thrown away")
            XCTAssertEqual(try Data(contentsOf: rescued[0]), Data("bad library A".utf8))
        }
    }

    /// The bytes of an unreadable library are the only copy of the history. Until they are safely aside, an
    /// ordinary install or list change must not be what writes over them — and once the copy can be made, the
    /// ordinary write goes through on its own.
    func testAFailedRescueCopyBlocksWritesUntilItSucceeds() throws {
        try withCleanLibrary {
            let original = Data("precious old history".utf8)
            try original.write(to: libraryFile)

            // library.json itself is writable; only the rescue copy is refused
            let gate = Gate()
            let store = LibraryStore(folder: folder) { try gate.write($0, $1) }
            XCTAssertEqual(rescueFiles().count, 0, "the copy could not be made")
            XCTAssertEqual(store.rescueNotes.count, 1, "and the app says so")

            store.add(aRecord)
            XCTAssertNotNil(store.writeProblem, "the write was refused rather than destroying the original")
            XCTAssertEqual(try Data(contentsOf: libraryFile), original, "the only copy of the history is intact")

            gate.blockRescues = false
            store.flush()
            XCTAssertNil(store.writeProblem, "the copy succeeded, so the write went through")
            XCTAssertEqual(rescueFiles().count, 1)
            XCTAssertEqual(try Data(contentsOf: rescueFiles()[0]), original, "kept, byte for byte")
            XCTAssertEqual(LibraryStore(folder: folder).history, [aRecord])
        }
    }

    /// Acknowledging one rescue says nothing about another library whose bytes still have nowhere to live.
    func testAcknowledgingOneRescueDoesNotReleaseAnothersHold() throws {
        try withCleanLibrary {
            let a = Data("bad library A".utf8)
            let b = Data("bad library B".utf8)
            let nameA = "library-unreadable-\(FWSCPackage.sha256Hex(a)).json"
            let nameB = "library-unreadable-\(FWSCPackage.sha256Hex(b)).json"

            // A became unreadable once and was kept aside properly
            try a.write(to: libraryFile)
            _ = LibraryStore(folder: folder)
            XCTAssertEqual(rescueFiles().map(\.lastPathComponent), [nameA])

            // now B is unreadable too, and its copy cannot be made
            try b.write(to: libraryFile)
            let gate = Gate()
            let store = LibraryStore(folder: folder) { try gate.write($0, $1) }
            XCTAssertEqual(Set(store.rescueNotes.map(\.file)), [nameA, nameB], "both are outstanding")

            store.dismiss(store.notices.first { $0.file == nameA }!)
            XCTAssertNotNil(store.writeProblem, "B still has nowhere to live, so nothing may be written")
            XCTAssertEqual(try Data(contentsOf: libraryFile), b, "B's only copy is intact")

            gate.blockRescues = false
            store.flush()
            XCTAssertNil(store.writeProblem)
            let kept = rescueFiles().first { $0.lastPathComponent == nameB }
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept)), b, "B is kept now")
        }
    }

    /// A read that fails is no proof that a write would, so an original nobody can read is still not replaced.
    func testAnOriginalThatCannotBeReadIsStillNotWrittenOver() throws {
        try withCleanLibrary {
            let original = Data("unreadable but precious".utf8)
            try original.write(to: libraryFile)

            let reads = Reads()
            let store = LibraryStore(folder: folder, readData: { try reads.read($0) })
            XCTAssertEqual(store.rescueNotes.count, 1, "it said the list cannot be read")
            XCTAssertEqual(rescueFiles().count, 0, "and nothing could be kept aside")

            store.add(aRecord)
            XCTAssertNotNil(store.writeProblem, "so the write is refused, not allowed through")
            XCTAssertEqual(try Data(contentsOf: libraryFile), original, "the only copy is intact")

            reads.allowed = true
            store.flush()
            XCTAssertNil(store.writeProblem, "now it could be read, so now it could be kept")
            XCTAssertEqual(rescueFiles().count, 1)
            XCTAssertEqual(try Data(contentsOf: rescueFiles()[0]), original)
            XCTAssertEqual(store.rescueNotes.first?.file, rescueFiles()[0].lastPathComponent,
                           "and the notice names the copy rather than library.json")
            XCTAssertEqual(LibraryStore(folder: folder).history, [aRecord])
        }
    }

    /// A half-written update must not be undone by a *later* job that never got as far as writing anything. Only
    /// the job holding the attempt's own token can abandon it.
    func testALaterJobThatNeverBeganAnAttemptCannotAbandonAnEarlierOne() throws {
        try withCleanLibrary {
            let store = LibraryStore(folder: folder)
            try store.beginAttempt(aPending)       // A, interrupted: its record stays, its token is let go of

            // a second job is refused during preflight, so its hook never ran and it holds no token
            try store.abandonAttempt(nil)
            XCTAssertEqual(store.pending, aPending, "A is still the half-written one")
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending, "on the disk too")
        }
    }

    /// Nor by one whose own record could not be written: it never got a token either.
    func testAJobWhoseRecordCouldNotBeWrittenCannotAbandonAnEarlierOne() throws {
        try withCleanLibrary {
            let disk = Disk()
            disk.failing = false
            let store = LibraryStore(folder: folder) { try disk.write($0, $1) }
            try store.beginAttempt(aPending)

            disk.failing = true
            let b = PendingUpdate(product: "FM-1_016", sha256: "cafe", firmwareId: nil, name: "Official firmware",
                                  version: "V16", usesStockLoader: true, source: .stock)
            var token: LibraryStore.AttemptToken?
            do {
                token = try store.beginAttempt(b)
                XCTFail("the record could not be written, so the attempt must be refused")
            } catch {
                XCTAssertNil(token, "a refused attempt hands back no token")
            }

            disk.failing = false
            try store.abandonAttempt(token)
            XCTAssertEqual(store.pending, aPending, "A stands; B never began")
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending)
        }
    }

    /// And a token from an attempt that has since been superseded is spent.
    func testAStaleTokenCannotAbandonTheAttemptThatFollowedIt() throws {
        try withCleanLibrary {
            let store = LibraryStore(folder: folder)
            let first = try store.beginAttempt(aPending)
            let b = PendingUpdate(product: "FM-1_016", sha256: "cafe", firmwareId: nil, name: "Official firmware",
                                  version: "V16", usesStockLoader: true, source: .stock)
            try store.beginAttempt(b)

            try store.abandonAttempt(first)
            XCTAssertEqual(store.pending, b, "the attempt in progress is B's, and B's token alone can undo it")
        }
    }

    /// A reader and writer that can each be turned off, for the cases that need both.
    private final class IO {
        var readsAllowed = false
        var writesAllowed = true
        func read(_ url: URL) throws -> Data {
            guard readsAllowed else { throw Disk.Full() }
            return try Data(contentsOf: url)
        }
        func write(_ data: Data, _ url: URL) throws {
            guard writesAllowed else { throw Disk.Full() }
            try data.write(to: url, options: .atomic)
        }
    }

    /// The nastiest of the recovery cases: an interrupted update A is on a library that will not read at launch, so
    /// the app starts believing nothing is pending. A later attempt at B must not roll back to that nothing — the
    /// store resolves the library before it looks at what it is replacing, so what comes back is A.
    func testARefusedAttemptRollsBackToTheRecoveredUpdateNotToTheNothingThatStoodInForIt() throws {
        try withCleanLibrary {
            let seed = LibraryStore(folder: folder)
            try seed.beginAttempt(aPending)                       // A is interrupted and on the disk

            let io = IO()
            let store = LibraryStore(folder: folder, readData: { try io.read($0) }, writeData: { try io.write($0, $1) })
            XCTAssertNil(store.pending, "it could not be read, so the app knows nothing yet")

            io.readsAllowed = true
            io.writesAllowed = false
            let b = PendingUpdate(product: "FM-1_016", sha256: "cafe", firmwareId: nil, name: "Official firmware",
                                  version: "V16", usesStockLoader: true, source: .stock, identityBefore: "FM-1_015")
            XCTAssertThrowsError(try store.beginAttempt(b), "the record would not write, so the attempt is refused")
            XCTAssertEqual(store.pending, aPending, "and the list says A, which is what is really half-written")

            io.writesAllowed = true
            store.add(aRecord)                                    // the failed install being recorded
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending, "A survives to the disk and a relaunch")
        }
    }

    /// A read that fails says nothing about the contents. A library that would not read at launch but reads and
    /// decodes later was never corrupt: it comes back rather than being kept as a rescue and replaced by nothing.
    func testAGoodLibraryThatWouldNotReadAtLaunchIsTakenBackNotDiscarded() throws {
        try withCleanLibrary {
            // a real library with history, a backup and a pending update
            let seed = LibraryStore(folder: folder)
            seed.add(aRecord)
            seed.add(aSnapshot)
            try seed.beginAttempt(aPending)
            let onDisk = try Data(contentsOf: libraryFile)

            let reads = Reads()
            let store = LibraryStore(folder: folder, readData: { try reads.read($0) })
            XCTAssertTrue(store.history.isEmpty, "it could not be read, so nothing is loaded yet")
            XCTAssertEqual(store.rescueNotes.count, 1)

            reads.allowed = true
            store.flush()
            XCTAssertNil(store.writeProblem)
            XCTAssertEqual(store.history, [aRecord], "the history came back")
            XCTAssertEqual(store.snapshots, [aSnapshot], "and the backups")
            XCTAssertEqual(store.pending, aPending, "and the interrupted update, which Resume needs")
            XCTAssertTrue(store.rescueNotes.isEmpty, "nothing was ever wrong with it, so there is nothing to fetch")
            XCTAssertEqual(rescueFiles().count, 0, "and no pointless copy was left behind")
            XCTAssertEqual(try Data(contentsOf: libraryFile), onDisk, "unchanged, bar the rewrite of the same state")
        }
    }

    /// And what the user did while the library was unreadable is not thrown away by that recovery either.
    func testRecoveryKeepsWhatWasRecordedInTheMeantime() throws {
        try withCleanLibrary {
            let seed = LibraryStore(folder: folder)
            seed.add(aRecord)

            let reads = Reads()
            let store = LibraryStore(folder: folder, readData: { try reads.read($0) })
            let meanwhile = InstallRecord(date: Date(timeIntervalSince1970: 1_761_900_000), firmwareId: nil,
                                          name: "while it was unreadable", version: "", product: "FM-1_016",
                                          sha256: nil, identityBefore: nil, identityAfter: "FM-1_016",
                                          source: .stock, success: true)
            store.add(meanwhile)                     // refused by the hold, but believed in memory

            reads.allowed = true
            store.flush()
            XCTAssertEqual(store.history.map(\.name), ["while it was unreadable", "Felucca"],
                           "both the recovered history and what was done in the meantime, newest first")
            XCTAssertEqual(LibraryStore(folder: folder).history.count, 2, "and that is what was written")
        }
    }

    /// A rescue copy is trusted for its bytes, never for its name: one that has been truncated or edited in Files
    /// must not pass for the preserved original.
    func testADamagedRescueCopyIsNotMistakenForThePreservedOriginal() throws {
        try withCleanLibrary {
            let bad = Data("bad library A".utf8)
            let name = "library-unreadable-\(FWSCPackage.sha256Hex(bad)).json"
            try Data("truncated".utf8).write(to: folder.appendingPathComponent(name))
            try bad.write(to: libraryFile)

            let store = LibraryStore(folder: folder)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), bad,
                           "the damaged copy was replaced with the real bytes, not accepted")
            store.add(aRecord)
            XCTAssertNil(store.writeProblem, "and with an intact copy the write may go ahead")
        }
    }

    /// Acknowledging must not delete the outstanding copy because something unverified shares its destination name.
    func testAcknowledgementKeepsBothWhenTheDestinationIsNotTheSameBytes() throws {
        try withCleanLibrary {
            let bad = Data("bad library A".utf8)
            let hash = FWSCPackage.sha256Hex(bad)
            try bad.write(to: libraryFile)
            let store = LibraryStore(folder: folder)

            // something else is already sitting under the acknowledged name
            let taken = folder.appendingPathComponent("library-rescued-\(hash).json")
            try Data("not the same bytes".utf8).write(to: taken)

            store.dismiss(store.notices.first { $0.kind == .rescue }!)
            XCTAssertEqual(try Data(contentsOf: taken), Data("not the same bytes".utf8), "left alone")
            let all = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let rescued = all.filter { $0.lastPathComponent.hasPrefix("library-rescued-") }
            XCTAssertEqual(rescued.count, 2, "the real bytes were put beside it rather than dropped")
            XCTAssertTrue(try rescued.contains { try Data(contentsOf: $0) == bad })
        }
    }

    /// Saying "I have the file" is the one thing that lets the app write over an original it could not copy.
    func testDismissingTheNoticeReleasesTheHoldOnWriting() throws {
        try withCleanLibrary {
            try Data("precious old history".utf8).write(to: libraryFile)
            let gate = Gate()
            let store = LibraryStore(folder: folder) { try gate.write($0, $1) }
            store.add(aRecord)
            XCTAssertNotNil(store.writeProblem)

            // the note names the copy that could not be made; acknowledging it finds nothing to rename, which is
            // not a failure, and releases the hold because the hold is about those very bytes
            store.dismiss(store.notices.first { $0.kind == .rescue }!)
            store.add(aSnapshot)
            XCTAssertNil(store.writeProblem, "the user took the bytes; the app may get on with it")
            XCTAssertEqual(LibraryStore(folder: folder).snapshots.count, 1)
        }
    }

    /// A dismissal whose rename cannot be recorded must not pretend to have worked: the rename *is* the
    /// acknowledgement, so if it fails the notice has to stay or the warning would reappear unexplained later.
    func testDismissalThatCannotBeRecordedKeepsTheNotice() throws {
        try withCleanLibrary {
            try Data("bad library A".utf8).write(to: libraryFile)
            let store = LibraryStore(folder: folder)
            let notice = store.notices.first { $0.kind == .rescue }!
            XCTAssertEqual(rescueFiles().count, 1)

            let fm = FileManager.default
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            try XCTSkipUnless(fm.isWritableFile(atPath: folder.path) == false,
                              "this filesystem ignores the mode bits, so the rename cannot be made to fail")

            store.dismiss(notice)
            XCTAssertEqual(store.rescueNotes.count, 1, "it could not be moved, so it is still outstanding")
            XCTAssertNotNil(store.writeProblem, "and the app says why")
        }
    }

    /// A rename that landed stays authoritative even if the save that followed it did not.
    func testAnAcknowledgedFileWinsOverAStaleNote() throws {
        try withCleanLibrary {
            try Data("bad library A".utf8).write(to: libraryFile)
            let first = LibraryStore(folder: folder)
            let notice = first.notices.first { $0.kind == .rescue }!
            first.dismiss(notice)

            // put a library back on disk that still carries the note, as a failed save would have left it
            let stale = #"{"history":[],"snapshots":[],"rescues":[{"date":"2025-10-20T12:00:00Z","#
                + #""file":"\#(notice.file!)","text":"old warning"}]}"#
            try Data(stale.utf8).write(to: libraryFile)

            let second = LibraryStore(folder: folder)
            XCTAssertTrue(second.rescueNotes.isEmpty, "the file was acknowledged; the note is out of date")
        }
    }

    /// A rescue note has to survive its own round trip, fractional seconds and all.
    func testARescueNoteComparesEqualAfterASaveAndALoad() throws {
        try withCleanLibrary {
            try Data("bad library A".utf8).write(to: libraryFile)
            let store = LibraryStore(folder: folder)
            store.add(aRecord)                       // a valid library, carrying the note
            let reloaded = LibraryStore(folder: folder)
            XCTAssertEqual(reloaded.rescueNotes, store.rescueNotes,
                           "dates are stamped at the precision the library is written with")
        }
    }

    func testDatesAreStampedAtTheSecond() {
        let note = RescueNote(date: Date(timeIntervalSince1970: 1_761_000_000.123_456), file: "x", text: "y")
        XCTAssertEqual(note.date, Date(timeIntervalSince1970: 1_761_000_000))
        // not compared against "now", which could tick over between the two reads
        let stamped = InstallRecord(firmwareId: nil, name: "n", version: "", product: "p", sha256: nil,
                                    identityBefore: nil, identityAfter: nil, source: .hub, success: true).date
        XCTAssertEqual(stamped.timeIntervalSince1970, stamped.timeIntervalSince1970.rounded(.down),
                       "a record is stamped with no fractional seconds, because none would survive the save")
    }

    /// A library written before `pending` and `rescues` existed must still be read, not taken for corrupt.
    func testReadsALegacyLibraryWithoutTheNewerKeys() throws {
        try withCleanLibrary {
            let record = #"{"date":"2025-10-20T12:00:00Z","id":"55555555-5555-5555-5555-555555555555","#
                + #""name":"Felucca","product":"FM-1_900","source":"hub","success":true,"version":"1.4"}"#
            let json = #"{"history":["# + record + #"],"snapshots":[]}"#
            try Data(json.utf8).write(to: libraryFile)
            let store = LibraryStore(folder: folder)
            XCTAssertNil(store.problem, "a missing key is an older version, not a corrupt library")
            XCTAssertEqual(store.history.count, 1)
            XCTAssertNil(store.pending)
            XCTAssertTrue(store.rescueNotes.isEmpty)
        }
    }

    /// And one with nothing in it at all.
    func testReadsAnEmptyLibraryObject() throws {
        try withCleanLibrary {
            try Data("{}".utf8).write(to: libraryFile)
            let store = LibraryStore(folder: folder)
            XCTAssertNil(store.problem)
            XCTAssertTrue(store.history.isEmpty)
            XCTAssertTrue(store.snapshots.isEmpty)
        }
    }

    /// A clear that did not reach the disk is retried by flush(), without any unrelated library change.
    func testFlushRetriesAWriteThatDidNotLand() throws {
        try withCleanLibrary {
            let disk = Disk()
            disk.failing = false
            let store = LibraryStore(folder: folder) { try disk.write($0, $1) }
            try store.beginAttempt(aPending)

            disk.failing = true
            XCTAssertThrowsError(try store.clearPending())
            XCTAssertTrue(store.unsaved)
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending, "the disk is behind")

            disk.failing = false
            store.flush()
            XCTAssertFalse(store.unsaved)
            XCTAssertNil(LibraryStore(folder: folder).pending, "flush finished the job on its own")
        }
    }

    func testFlushDoesNothingWhenEverythingIsSaved() throws {
        try withCleanLibrary {
            let store = LibraryStore(folder: folder)
            try store.beginAttempt(aPending)
            XCTAssertFalse(store.unsaved)
            store.flush()
            XCTAssertEqual(LibraryStore(folder: folder).pending, aPending)
        }
    }

    /// Relaunching on the same unreadable file must find the copy it already made, not pile up another one.
    func testASecondLaunchOnTheSameBadFileDoesNotMakeASecondRescue() throws {
        try withCleanLibrary {
            try Data("this is not JSON".utf8).write(to: libraryFile)
            let first = LibraryStore(folder: folder)
            XCTAssertEqual(rescueFiles().count, 1)
            let second = LibraryStore(folder: folder)
            XCTAssertEqual(rescueFiles().count, 1, "the rescue name comes from the bad file, not from the clock")
            XCTAssertEqual(second.rescueNotes.first?.file, first.rescueNotes.first?.file)
        }
    }

    func testDatesAreWrittenAsISO8601Strings() throws {
        let data = try LibraryStore.makeEncoder().encode(aRecord)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertTrue(json?["date"] is String, "ISO-8601, which is exactly what the decoder has to be told to read")
        XCTAssertEqual(try LibraryStore.makeDecoder().decode(InstallRecord.self, from: data), aRecord)
    }

    func testTheDecoderRefusesADateItCannotRead() throws {
        let json = Data("""
        {"date":"not a date","id":"44444444-4444-4444-4444-444444444444","name":"x","product":"p",\
        "source":"hub","success":true,"version":"1"}
        """.utf8)
        XCTAssertThrowsError(try LibraryStore.makeDecoder().decode(InstallRecord.self, from: json))
    }
}
