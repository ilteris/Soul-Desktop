import Foundation
import SwiftUI

enum SoulReminderStatus: String, Codable, Sendable {
    case pending
    case completed
    case dismissed
}

struct SoulReminder: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var dueAt: Date
    var text: String
    var projectId: String
    var projectName: String
    var projectPath: String?
    var threadId: String?
    var threadTitle: String?
    var provider: String?
    var status: SoulReminderStatus

    var isPending: Bool { status == .pending }
}

struct SoulReminderContext: Equatable, Sendable {
    var projectId: String
    var projectName: String
    var projectPath: String?
    var threadId: String?
    var threadTitle: String?
    var provider: String?
}

struct SoulReminderDraft: Equatable, Sendable {
    var text: String
    var dueAt: Date
    var context: SoulReminderContext
}

private struct SoulReminderLedgerEvent: Codable {
    enum Kind: String, Codable {
        case created = "ReminderCreated"
        case completed = "ReminderCompleted"
        case dismissed = "ReminderDismissed"
    }

    var event: Kind
    var reminderId: UUID
    var occurredAt: Date
    var reminder: SoulReminder?
}

@MainActor
@Observable
final class ReminderStore {
    static let shared = ReminderStore()

    private(set) var reminders: [SoulReminder] = []
    var now: Date = Date()

    private let storageURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storageURL: URL = ReminderStore.defaultStorageURL(), fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    nonisolated static func defaultStorageURL(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let registry = environment["SOUL_REGISTRY"]
            ?? (home as NSString).appendingPathComponent("soul_registry")
        return URL(fileURLWithPath: registry, isDirectory: true)
            .appendingPathComponent("app_state", isDirectory: true)
            .appendingPathComponent("soul-desktop", isDirectory: true)
            .appendingPathComponent("reminders.jsonl")
    }

    var pendingReminders: [SoulReminder] {
        reminders
            .filter(\.isPending)
            .sorted { $0.dueAt < $1.dueAt }
    }

    var dueReminders: [SoulReminder] {
        pendingReminders.filter { $0.dueAt <= now }
    }

    @discardableResult
    func create(_ draft: SoulReminderDraft) -> SoulReminder? {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let createdAt = Date()
        let reminder = SoulReminder(
            id: UUID(),
            createdAt: createdAt,
            updatedAt: createdAt,
            dueAt: draft.dueAt,
            text: text,
            projectId: draft.context.projectId,
            projectName: draft.context.projectName,
            projectPath: draft.context.projectPath,
            threadId: draft.context.threadId,
            threadTitle: draft.context.threadTitle,
            provider: draft.context.provider,
            status: .pending
        )
        reminders.append(reminder)
        reminders.sort { $0.dueAt < $1.dueAt }
        append(
            SoulReminderLedgerEvent(
                event: .created,
                reminderId: reminder.id,
                occurredAt: createdAt,
                reminder: reminder
            )
        )
        return reminder
    }

    func complete(_ id: UUID) {
        transition(id, to: .completed, event: .completed)
    }

    func dismiss(_ id: UUID) {
        transition(id, to: .dismissed, event: .dismissed)
    }

    func reload() {
        load()
    }

    private func transition(_ id: UUID, to status: SoulReminderStatus, event: SoulReminderLedgerEvent.Kind) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        let updatedAt = Date()
        reminders[index].status = status
        reminders[index].updatedAt = updatedAt
        append(
            SoulReminderLedgerEvent(
                event: event,
                reminderId: id,
                occurredAt: updatedAt,
                reminder: nil
            )
        )
    }

    private func load() {
        var folded: [UUID: SoulReminder] = [:]
        guard let handle = try? FileHandle(forReadingFrom: storageURL) else {
            reminders = []
            return
        }
        defer { try? handle.close() }
        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty else {
            reminders = []
            return
        }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? decoder.decode(SoulReminderLedgerEvent.self, from: Data(line)) else { continue }
            switch event.event {
            case .created:
                if let reminder = event.reminder {
                    folded[event.reminderId] = reminder
                }
            case .completed:
                folded[event.reminderId]?.status = .completed
                folded[event.reminderId]?.updatedAt = event.occurredAt
            case .dismissed:
                folded[event.reminderId]?.status = .dismissed
                folded[event.reminderId]?.updatedAt = event.occurredAt
            }
        }
        reminders = folded.values.sorted { $0.dueAt < $1.dueAt }
    }

    private func append(_ event: SoulReminderLedgerEvent) {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var data = try encoder.encode(event)
            data.append(UInt8(ascii: "\n"))
            if fileManager.fileExists(atPath: storageURL.path) {
                let handle = try FileHandle(forWritingTo: storageURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: storageURL, options: .atomic)
            }
        } catch {
            NSLog("Soul reminder append failed: \(error.localizedDescription)")
        }
    }
}
