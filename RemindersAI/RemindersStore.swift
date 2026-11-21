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
    var repeats: Repeat
    var url: String

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
        repeats = Repeat(reminder.recurrenceRules?.first)
        url = reminder.url?.absoluteString ?? ""
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
    /// False for lists the account does not let this app rename or delete.
    var isEditable: Bool
}

enum ReminderFilter: Hashable {
    case today, scheduled, all, completed, assistant
    case list(String)
}

/// The simple repeat choices Reminders offers. A reminder with a more
/// elaborate rule reads as its base frequency and is left alone unless changed.
enum Repeat: String, CaseIterable, Identifiable, Sendable {
    case never, daily, weekly, monthly, yearly

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    init(_ rule: EKRecurrenceRule?) {
        switch rule?.frequency {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        default: self = .never
        }
    }

    var rule: EKRecurrenceRule? {
        let frequency: EKRecurrenceFrequency
        switch self {
        case .never: return nil
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)
    }
}

/// The colours Reminders offers for a list.
enum ListColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, cyan, blue, indigo, pink, purple, brown, gray

    var id: String { rawValue }

    var uiColor: UIColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .cyan: .systemCyan
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .pink: .systemPink
        case .purple: .systemPurple
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }

    var color: Color { Color(uiColor) }
}

enum RemindersAccess { case unknown, granted, denied }

struct MoveRefusal: Equatable {
    /// EventKit's local identifier of the reminder that didn't move.
    let reminderId: String
    let listId: String
    let listTitle: String
}

enum ReminderEditError: LocalizedError {
    case missing
    case readOnly
    case invalid(String)
    case moveRefused

    var errorDescription: String? {
        switch self {
        case .moveRefused: "iOS wouldn't move this reminder to that list."
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
    /// A list change iOS refused, waiting for the person to choose whether to copy instead.
    private(set) var moveRefusal: MoveRefusal?

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
            .map {
                ReminderList(id: $0.calendarIdentifier, title: $0.title, color: Color(cgColor: $0.cgColor),
                             isWritable: $0.allowsContentModifications, isEditable: !$0.isImmutable)
            }
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

    /// The number on a list's card or row: open reminders, or for Completed, the completed ones.
    func openCount(_ filter: ReminderFilter, threadIds: Set<String> = []) -> Int {
        items(for: filter, includeCompleted: false, threadIds: threadIds).count
    }

    /// Reminders whose title or notes contain the text, completed ones included.
    func search(_ text: String) -> [ReminderItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return items(for: .all, includeCompleted: true).filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query)
        }
    }

    func items(for filter: ReminderFilter, includeCompleted: Bool, threadIds: Set<String> = []) -> [ReminderItem] {
        let matching = items.filter { item in
            if filter == .completed { return item.isCompleted }
            guard includeCompleted || !item.isCompleted else { return false }
            switch filter {
            case .all, .completed: return true
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
        } catch ReminderEditError.moveRefused {
            // Not an error to show: the reminder's page asks what to do.
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await reload()
    }

    func add(title: String, notes: String = "", listId: String?, due: DateComponents? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform {
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = trimmed
            reminder.notes = notes.isEmpty ? nil : notes
            let calendar = listId.flatMap { eventStore.calendar(withIdentifier: $0) } ?? eventStore.defaultCalendarForNewReminders()
            guard let calendar, calendar.allowsContentModifications else { throw ReminderEditError.readOnly }
            reminder.calendar = calendar
            setDue(due, on: reminder)
            try save(reminder)
        }
    }

    /// Sets the due date and, as Reminders does, an alert at that moment when
    /// the date has a time. All-day reminders rely on Reminders' own daily alert.
    private func setDue(_ due: DateComponents?, on reminder: EKReminder) {
        reminder.dueDateComponents = due
        for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil { reminder.removeAlarm(alarm) }
        if let due, due.hour != nil, let date = Calendar.current.date(from: due) {
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        // EventKit refuses a repeating reminder without a due date.
        if due == nil, let rules = reminder.recurrenceRules { rules.forEach(reminder.removeRecurrenceRule) }
    }

    /// Title and notes only, for typing straight into a reminder.
    func rename(_ item: ReminderItem, title: String, notes: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title || notes != item.notes else { return }
        await perform {
            guard let reminder = reminder(id: item.id) else { throw ReminderEditError.missing }
            reminder.title = trimmed
            reminder.notes = notes.isEmpty ? nil : notes
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

    /// Saves the reminder's fields and, when `listId` differs, moves it. Returns the
    /// reminder's external id afterwards: EventKit may give a moved reminder a new one.
    @discardableResult
    func update(_ item: ReminderItem, title: String, notes: String, due: DateComponents?, priority: Priority,
                repeats: Repeat, url: String, listId: String) async -> String? {
        var savedId: String?
        await perform {
            guard let reminder = reminder(id: item.id) else { throw ReminderEditError.missing }
            reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            reminder.notes = notes.isEmpty ? nil : notes
            if DueDate.string(from: due) != DueDate.string(from: item.due) { setDue(due, on: reminder) }
            reminder.priority = priority.eventKit
            if repeats != item.repeats || due == nil {
                reminder.recurrenceRules?.forEach(reminder.removeRecurrenceRule)
                if due != nil, let rule = repeats.rule { reminder.addRecurrenceRule(rule) }
            }
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedURL != item.url {
                if trimmedURL.isEmpty {
                    reminder.url = nil
                } else if let parsed = URL(string: trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)") {
                    reminder.url = parsed
                } else {
                    throw ReminderEditError.invalid("That link isn't a valid address.")
                }
            }
            guard listId != item.listId else {
                try save(reminder)
                savedId = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
                return
            }
            guard let calendar = eventStore.calendar(withIdentifier: listId), calendar.allowsContentModifications else {
                throw ReminderEditError.readOnly
            }
            savedId = try move(reminder, to: calendar)
        }
        return savedId
    }

    /// Moves a reminder to another list. When iOS refuses (it sometimes does,
    /// with reminderkit error -3002), the other edits are still saved and
    /// `moveRefusal` asks the person whether to copy the reminder instead.
    private func move(_ reminder: EKReminder, to calendar: EKCalendar) throws -> String {
        let originalCalendar = reminder.calendar
        reminder.calendar = calendar
        if (try? eventStore.save(reminder, commit: true)) != nil,
           let saved = eventStore.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder,
           saved.calendar?.calendarIdentifier == calendar.calendarIdentifier {
            return saved.calendarItemExternalIdentifier ?? saved.calendarItemIdentifier
        }
        reminder.calendar = originalCalendar
        try? save(reminder)
        moveRefusal = MoveRefusal(reminderId: reminder.calendarItemIdentifier, listId: calendar.calendarIdentifier,
                                  listTitle: calendar.title)
        throw ReminderEditError.moveRefused
    }

    /// The other way to change lists: a copy in the new list, then the original
    /// removed. EventKit can't see subtasks, tags, flags or images, so those
    /// are lost; only do this when the person agrees. Returns the copy's external id.
    func copy(_ item: ReminderItem, toList listId: String) async -> String? {
        moveRefusal = nil
        var copiedId: String?
        await perform {
            guard let original = reminder(id: item.id) else { throw ReminderEditError.missing }
            guard let calendar = eventStore.calendar(withIdentifier: listId), calendar.allowsContentModifications else {
                throw ReminderEditError.readOnly
            }
            let copy = EKReminder(eventStore: eventStore)
            copy.title = original.title
            copy.notes = original.notes
            copy.url = original.url
            copy.priority = original.priority
            copy.startDateComponents = original.startDateComponents
            copy.dueDateComponents = original.dueDateComponents
            for alarm in original.alarms ?? [] { copy.addAlarm(alarm.copy() as! EKAlarm) }
            for rule in original.recurrenceRules ?? [] { copy.addRecurrenceRule(rule.copy() as! EKRecurrenceRule) }
            copy.isCompleted = original.isCompleted
            copy.calendar = calendar
            try eventStore.save(copy, commit: true)
            copiedId = copy.calendarItemExternalIdentifier ?? copy.calendarItemIdentifier
            do {
                try eventStore.remove(original, commit: true)
            } catch {
                // Better a duplicate than a lost reminder; say so.
                throw ReminderEditError.invalid("Copied to \(calendar.title), but the original couldn't be removed.")
            }
        }
        return copiedId
    }

    func dismissMoveRefusal() { moveRefusal = nil }

    // MARK: Lists

    func createList(title: String, color: ListColor) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform {
            // New lists go where new reminders go (normally iCloud), else any account that takes them.
            let source = eventStore.defaultCalendarForNewReminders()?.source
                ?? eventStore.sources.first { $0.sourceType == .calDAV || $0.sourceType == .local }
            guard let source else { throw ReminderEditError.invalid("No Reminders account can hold a new list.") }
            let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
            calendar.title = trimmed
            calendar.cgColor = color.uiColor.cgColor
            calendar.source = source
            try eventStore.saveCalendar(calendar, commit: true)
        }
    }

    func updateList(_ list: ReminderList, title: String, color: ListColor?) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform {
            guard let calendar = eventStore.calendar(withIdentifier: list.id), !calendar.isImmutable else {
                throw ReminderEditError.readOnly
            }
            calendar.title = trimmed
            if let color { calendar.cgColor = color.uiColor.cgColor }
            try eventStore.saveCalendar(calendar, commit: true)
        }
    }

    /// Deletes the list and every reminder in it, as Reminders does.
    func deleteList(_ list: ReminderList) async {
        await perform {
            guard let calendar = eventStore.calendar(withIdentifier: list.id), !calendar.isImmutable else {
                throw ReminderEditError.readOnly
            }
            try eventStore.removeCalendar(calendar, commit: true)
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

    // MARK: Commitments from the weekly review

    /// Brings Reminders in step with the commitments the server sent: makes a
    /// reminder for each accepted one, removes the open reminder of one that is
    /// no longer wanted, and notes which were checked off. Returns what the
    /// server should be told. A commitment that fails is left for the next sync.
    func reconcile(_ commitments: [Commitment]) async -> [CommitmentReport] {
        guard access == .granted, !commitments.isEmpty else { return [] }
        var reports: [CommitmentReport] = []
        var changed = false
        for commitment in commitments {
            let existing = commitment.reminderId.flatMap { reminder(externalId: $0) }
            switch CommitmentSync.action(for: commitment, reminderCompleted: existing?.isCompleted) {
            case .none:
                break
            case .create:
                // One made earlier whose report never arrived, or made by another device, is taken up.
                guard let reminder = try? adopted(for: commitment) ?? created(for: commitment) else { continue }
                changed = true
                reports.append(report(commitment, reminder))
            case .remove:
                guard let existing, (try? eventStore.remove(existing, commit: true)) != nil else { continue }
                changed = true
                reports.append(CommitmentReport(week: commitment.week, id: commitment.id, reminderId: nil, done: false))
            case .report:
                guard let existing else { continue }
                reports.append(report(commitment, existing))
            }
        }
        if changed { await reload() }
        return reports
    }

    private func report(_ commitment: Commitment, _ reminder: EKReminder) -> CommitmentReport {
        CommitmentReport(
            week: commitment.week, id: commitment.id,
            reminderId: reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier,
            done: reminder.isCompleted,
            completedAt: reminder.isCompleted ? reminder.completionDate.map(JSONCoding.timestamp) : nil
        )
    }

    /// A reminder already in the commitments list with this commitment's title and due date.
    private func adopted(for commitment: Commitment) -> EKReminder? {
        items.first {
            $0.listTitle == CommitmentSync.listTitle && $0.title == commitment.text
                && DueDate.string(from: $0.due) == commitment.due
        }.flatMap { reminder(id: $0.id) }
    }

    private func created(for commitment: Commitment) throws -> EKReminder {
        guard let due = DueDate.components(from: commitment.due) else {
            throw ReminderEditError.invalid("Bad due date: \(commitment.due)")
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = commitment.text
        reminder.notes = CommitmentSync.notes(for: commitment)
        reminder.calendar = try commitmentsCalendar()
        setDue(due, on: reminder)
        try save(reminder)
        return reminder
    }

    /// The "Weekly Commitments" list, made the first time it is needed. Found
    /// again by its identifier, so renaming it in Reminders is fine.
    private func commitmentsCalendar() throws -> EKCalendar {
        let key = "commitmentsListId"
        let lists = eventStore.calendars(for: .reminder).filter(\.allowsContentModifications)
        let saved = UserDefaults.standard.string(forKey: key)
        if let found = lists.first(where: { $0.calendarIdentifier == saved })
            ?? lists.first(where: { $0.title == CommitmentSync.listTitle }) {
            UserDefaults.standard.set(found.calendarIdentifier, forKey: key)
            return found
        }
        let source = eventStore.defaultCalendarForNewReminders()?.source
            ?? eventStore.sources.first { $0.sourceType == .calDAV || $0.sourceType == .local }
        guard let source else { throw ReminderEditError.invalid("No Reminders account can hold a new list.") }
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = CommitmentSync.listTitle
        calendar.cgColor = ListColor.green.uiColor.cgColor
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: key)
        return calendar
    }

    private func write(_ payload: OpPayload, to reminder: EKReminder) throws {
        if let title = payload.title { reminder.title = title }
        if let notes = payload.notes { reminder.notes = notes.isEmpty ? nil : notes }
        if let priority = payload.priority.flatMap(Priority.init(rawValue:)) { reminder.priority = priority.eventKit }
        switch payload.due {
        case .unchanged: break
        case .clear: setDue(nil, on: reminder)
        case .set(let value):
            guard let components = DueDate.components(from: value) else { throw ReminderEditError.invalid("Bad due date: \(value)") }
            setDue(components, on: reminder)
        }
    }
}
