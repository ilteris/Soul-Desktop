import Foundation
import Testing
@testable import Soul_Desktop

@MainActor
@Suite("Reminder store")
struct ReminderStoreTests {
    @Test func createPersistsAndReloadsReminderContext() throws {
        let url = try Self.temporaryLedgerURL()
        let store = ReminderStore(storageURL: url)
        let dueAt = Date(timeIntervalSince1970: 1_800_000_000)

        let reminder = try #require(store.create(Self.draft(text: "Follow up", dueAt: dueAt)))

        let reloaded = ReminderStore(storageURL: url)
        let loaded = try #require(reloaded.reminders.first)
        #expect(loaded.id == reminder.id)
        #expect(loaded.text == "Follow up")
        #expect(loaded.projectId == "soul-desktop")
        #expect(loaded.threadId == "thread-123")
        #expect(loaded.provider == "codex")
        #expect(loaded.status == .pending)
    }

    @Test func dueRemindersFiltersPendingByCurrentTime() throws {
        let url = try Self.temporaryLedgerURL()
        let store = ReminderStore(storageURL: url)
        let dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let later = Date(timeIntervalSince1970: 1_800_003_600)

        let due = try #require(store.create(Self.draft(text: "Due", dueAt: dueAt)))
        _ = store.create(Self.draft(text: "Later", dueAt: later))

        store.now = dueAt.addingTimeInterval(1)
        #expect(store.dueReminders.map(\.id) == [due.id])
    }

    @Test func completeAndDismissFoldAcrossReload() throws {
        let url = try Self.temporaryLedgerURL()
        let store = ReminderStore(storageURL: url)
        let done = try #require(store.create(Self.draft(text: "Done", dueAt: Date())))
        let dismissed = try #require(store.create(Self.draft(text: "Dismissed", dueAt: Date())))

        store.complete(done.id)
        store.dismiss(dismissed.id)

        let reloaded = ReminderStore(storageURL: url)
        let byId = Dictionary(uniqueKeysWithValues: reloaded.reminders.map { ($0.id, $0.status) })
        #expect(byId[done.id] == .completed)
        #expect(byId[dismissed.id] == .dismissed)
        #expect(reloaded.pendingReminders.isEmpty)
    }

    private static func draft(text: String, dueAt: Date) -> SoulReminderDraft {
        SoulReminderDraft(
            text: text,
            dueAt: dueAt,
            context: SoulReminderContext(
                projectId: "soul-desktop",
                projectName: "Soul Desktop",
                projectPath: "/tmp/Soul-Desktop",
                threadId: "thread-123",
                threadTitle: "Reminder thread",
                provider: "codex"
            )
        )
    }

    private static func temporaryLedgerURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("soul-reminder-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reminders.jsonl")
    }
}
