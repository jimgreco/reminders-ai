import EventKit
import Foundation
import Observation
import SwiftUI

/// A reminder as the views use it: a value copied out of EventKit.
struct ReminderItem: Identifiable, Equatable, Sendable {
    /// Local identifier, used to find the reminder again on this device.
    var id: String
    /// The same on every device; the key of the reminder's assistant thread.
    var externalId: String
    var title: String
    var notes: String
    var due: DateComponents?
    var priority: Priority
    var isCompleted: Bool
    var completionDate: Date?
    var created: Date?
    var listId: String
    var listTitle: String

    init(_ reminder: EKReminder) {
        id = reminder.calendarItemIdentifier
        externalId = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
        title = reminder.title ?? ""
        notes = reminder.notes ?? ""
        due = reminder.dueDateComponents
        priority = Priority(eventKit: reminder.priority)
        isCompleted = reminder.isCompleted
        completionDate = reminder.completionDate
        created = reminder.creationDate
        listId = reminder.calendar?.calendarIdentifier ?? ""
        listTitle = reminder.calendar?.title ?? ""
    }

    var dueDate: Date? {
        guard let due else { return nil }
        return Calendar.current.date(from: due)
    }

    var hasDueTime: Bool { due?.hour != nil }

    func isOverdue(now: Date = Date()) -> Bool {
        guard !isCompleted, let dueDate else { return false }
        return hasDueTime ? dueDate < now : dueDate < Calendar.current.startOfDay(for: now)
    }

    func isDueToday(now: Date = Date()) -> Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDate(dueDate, inSameDayAs: now) || isOverdue(now: now)
    }

    func snapshot(now: Date = Date()) -> ReminderSnapshot {
        ReminderSnapshot(
            title: title.isEmpty ? "Untitled" : title, notes: notes, list: listTitle,
            due: DueDate.string(from: due), priority: priority.rawValue, completed: isCompleted,
            timeZone: TimeZone.current.identifier, now: JSONCoding.timestamp(now)
        )
    }
}

struct ReminderList: Identifiable, Equatable {
    var id: String
    var title: String
    var color: Color
    var isWritable: Bool
}

enum ReminderFilter: Hashable {
    case today, scheduled, all, assistant
    case list(String)
}

enum RemindersAccess { case unknown, granted, denied }

enum ReminderEditError: LocalizedError {
    case missing
    case readOnly
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missing: "The reminder no longer exists on this iPhone."
        case .readOnly: "This list can't be changed."
        case .invalid(let why): why
        }
    }
}

/// Apple Reminders through EventKit. Reminders is the only store of tasks:
/// nothing here is cached, and every change made in the Reminders app shows up
/// on the next reload.
@MainActor
@Observable
final class RemindersStore {
    private(set) var access: RemindersAccess = .unknown
    private(set) var lists: [ReminderList] = []
    private(set) var items: [ReminderItem] = []
    private(set) var defaultListId: String?
    var lastError: String?

    @ObservationIgnored private let eventStore = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    func start() async {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            access = .granted
        case .notDetermined:
            let granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
            access = granted ? .granted : .denied
        default:
            access = .denied
        }
        guard access == .granted else { return }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: eventStore, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleReload() }
            }
        }
        await reload()
    }

    /// EventKit posts bursts of change notifications; one reload covers them.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        guard access == .granted else { return }
        lists = eventStore.calendars(for: .reminder)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title, color: Color(cgColor: $0.cgColor), isWritable: $0.allowsContentModifications) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        defaultListId = eventStore.defaultCalendarForNewReminders()?.calendarIdentifier
        let recent = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        async let open = fetch(eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        async let done = fetch(eventStore.predicateForCompletedReminders(withCompletionDateStarting: recent, ending: nil, calendars: nil))
        items = await open + done
    }

    private func fetch(_ predicate: NSPredicate) async -> [ReminderItem] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(ReminderItem.init))
            }
        }
    }

    // MARK: Reading

    func list(_ id: String) -> ReminderList? { lists.first { $0.id == id } }

    func item(id: String) -> ReminderItem? { items.first { $0.id == id } }

    func item(externalId: String) -> ReminderItem? { items.first { $0.externalId == externalId } }

    func color(for item: ReminderItem) -> Color { list(item.listId)?.color ?? .accentColor }

    func openCount(_ filter: ReminderFilter, threadIds: Set<String> = []) -> Int {
        items(for: filter, includeCompleted: false, threadIds: threadIds).count
    }

    func items(for filter: ReminderFilter, includeCompleted: Bool, threadIds: Set<String> = []) -> [ReminderItem] {
        let matching = items.filter { item in
            guard includeCompleted || !item.isCompleted else { return false }
            switch filter {
            case .all: return true
            case .today: return item.isDueToday()
            case .scheduled: return item.due != nil
            case .assistant: return threadIds.contains(item.externalId)
            case .list(let id): return item.listId == id
            }
        }
        return matching.sorted { a, b in
            if a.isCompleted != b.isCompleted { return !a.isCompleted }
            if a.isCompleted { return (a.completionDate ?? .distantPast) > (b.completionDate ?? .distantPast) }
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.created ?? .distantPast) < (b.created ?? .distantPast)
            }
        }
    }

    // MARK: Writing

    private func reminder(id: String) -> EKReminder? {
        eventStore.calendarItem(withIdentifier: id) as? EKReminder
    }

    private func reminder(externalId: String) -> EKReminder? {
        if let known = item(externalId: externalId), let found = reminder(id: known.id) { return found }
        return eventStore.calendarItems(withExternalIdentifier: externalId).compactMap { $0 as? EKReminder }.first
    }

    private func save(_ reminder: EKReminder) throws {
        try eventStore.save(reminder, commit: true)
    }

    private func perform(_ work: () throws -> Void) async {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await reload()
    }

    func add(title: String, listId: String?) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform {
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = trimmed
            let calendar = listId.flatMap { eventStore.calendar(withIdentifier: $0) } ?? eventStore.defaultCalendarForNewReminders()
            guard let calendar, calendar.allowsContentModifications else { throw ReminderEditError.readOnly }
            reminder.calendar = calendar
            try save(reminder)
        }
    }

    func setCompleted(_ item: ReminderItem, _ completed: Bool) async {
        await perform {
            guard let reminder = reminder(id: item.id) else { throw ReminderEditError.missing }
            reminder.isCompleted = completed
            try save(reminder)
        }
    }

    func update(_ item: ReminderItem, title: String, notes: String, due: DateComponents?, priority: Priority) async {
        await perform {
            guard let reminder = reminder(id: item.id) else { throw ReminderEditError.missing }
            reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            reminder.notes = notes.isEmpty ? nil : notes
            reminder.dueDateComponents = due
            reminder.priority = priority.eventKit
            try save(reminder)
        }
    }

    func delete(_ item: ReminderItem) async {
        await perform {
            guard let reminder = reminder(id: item.id) else { return }
            try eventStore.remove(reminder, commit: true)
        }
    }

    /// Applies one edit the assistant queued. Throws when it cannot be applied,
    /// so the server can record why.
    func apply(_ op: PendingOp) throws {
        let target = reminder(externalId: op.reminderId)
        switch op.kind {
        case "complete":
            guard let target else { throw ReminderEditError.missing }
            target.isCompleted = true
            try save(target)
        case "update":
            guard let target else { throw ReminderEditError.missing }
            try write(op.payload, to: target)
            try save(target)
        case "create":
            let created = EKReminder(eventStore: eventStore)
            guard let calendar = target?.calendar ?? eventStore.defaultCalendarForNewReminders(),
                  calendar.allowsContentModifications else { throw ReminderEditError.readOnly }
            created.calendar = calendar
            try write(op.payload, to: created)
            guard !(created.title ?? "").isEmpty else { throw ReminderEditError.invalid("A new reminder needs a title.") }
            try save(created)
        default:
            throw ReminderEditError.invalid("Unknown edit: \(op.kind)")
        }
    }

    private func write(_ payload: OpPayload, to reminder: EKReminder) throws {
        if let title = payload.title { reminder.title = title }
        if let notes = payload.notes { reminder.notes = notes.isEmpty ? nil : notes }
        if let priority = payload.priority.flatMap(Priority.init(rawValue:)) { reminder.priority = priority.eventKit }
        switch payload.due {
        case .unchanged: break
        case .clear: reminder.dueDateComponents = nil
        case .set(let value):
            guard let components = DueDate.components(from: value) else { throw ReminderEditError.invalid("Bad due date: \(value)") }
            reminder.dueDateComponents = components
        }
    }
}
