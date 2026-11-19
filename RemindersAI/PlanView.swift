import SwiftUI

// MARK: Model

struct PlanReminder: Encodable {
    let id: String
    let title: String
    let list: String
    let due: String?
    let priority: String
    let notes: String
    let conversation: String
}

struct PlanRequest: Encodable {
    let reminders: [PlanReminder]
    let timeZone: String
    let now: String
}

struct PlanSuggestion: Codable, Identifiable, Equatable {
    let reminderId: String
    let reason: String
    let nextStep: String
    let assistantPrompt: String
    var id: String { reminderId }
}

struct DayPlan: Codable, Equatable {
    let summary: String
    let suggestions: [PlanSuggestion]
    var madeAt = Date()
    /// Picks started with the assistant from this plan.
    var started: Set<String> = []
    /// Picks checked off from this plan. Kept here because a repeating
    /// reminder never stays completed: Reminders moves it to its next date.
    var finished: Set<String> = []

    private enum CodingKeys: String, CodingKey { case summary, suggestions, madeAt, started, finished }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        suggestions = try c.decode([PlanSuggestion].self, forKey: .suggestions)
        madeAt = try c.decodeIfPresent(Date.self, forKey: .madeAt) ?? Date()
        started = try c.decodeIfPresent(Set<String>.self, forKey: .started) ?? []
        finished = try c.decodeIfPresent(Set<String>.self, forKey: .finished) ?? []
    }
}

/// A reminder left out of Plan My Day, until a time or for good (`until` nil).
struct PlanDismissal: Codable, Equatable {
    let reminderId: String
    let until: Date?
}

private struct PlanDismissals: Decodable { let dismissals: [PlanDismissal] }
private struct DismissBody: Encodable { let until: String? }

/// How long to leave a reminder out of the suggestions.
enum DismissLength: CaseIterable, Identifiable {
    case today, week, month, forever
    var id: Self { self }

    var label: String {
        switch self {
        case .today: "For Today"
        case .week: "For a Week"
        case .month: "For a Month"
        case .forever: "Don't Suggest Again"
        }
    }

    var symbol: String {
        switch self {
        case .today: "moon"
        case .week: "calendar"
        case .month: "calendar.badge.clock"
        case .forever: "nosign"
        }
    }

    /// When the reminder comes back; nil means never.
    func until(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .week: calendar.date(byAdding: .day, value: 7, to: now)
        case .month: calendar.date(byAdding: .month, value: 1, to: now)
        case .forever: nil
        }
    }
}

/// Today's plan: made on request by Claude on the server from the open
/// reminders, and kept on this device until the day is over.
@MainActor
@Observable
final class PlannerStore {
    private(set) var plan: DayPlan?
    private(set) var isPlanning = false
    var lastError: String?
    /// Suggestions started with the assistant from this plan.
    var started: Set<String> { plan?.started ?? [] }
    /// Reminders left out of the suggestions, by reminder id. Kept on the
    /// server so they apply on every device, and the planner never sees them.
    private(set) var dismissals: [String: PlanDismissal] = [:]

    private static let key = "dayPlan"
    /// The saved plan's own format. The API coders don't round-trip dates:
    /// the encoder writes a number and the decoder expects an ISO string.
    private static let storeEncoder = JSONEncoder()
    private static let storeDecoder = JSONDecoder()
    /// The longest list sent; the earliest due and highest priority go first.
    static let maxReminders = 400

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? Self.storeDecoder.decode(DayPlan.self, from: data),
           Calendar.current.isDateInToday(saved.madeAt) {
            plan = saved
        }
    }

    /// The plan, unless it was made on an earlier day.
    var todaysPlan: DayPlan? {
        guard let plan, Calendar.current.isDateInToday(plan.madeAt) else { return nil }
        return plan
    }

    func make(reminders: RemindersStore, assistant: AssistantStore, session: Session) async {
        guard !isPlanning else { return }
        isPlanning = true
        defer { isPlanning = false }
        await loadDismissals(session: session)
        let open = reminders.items(for: .all, includeCompleted: false).prefix(Self.maxReminders)
        let request = PlanRequest(
            reminders: open.map { item in
                PlanReminder(
                    id: item.externalId, title: item.title, list: item.listTitle, due: DueDate.string(from: item.due),
                    priority: item.priority.rawValue, notes: String(item.notes.prefix(1000)),
                    conversation: assistant.summary(for: item.externalId)?.status.rawValue ?? "none"
                )
            },
            timeZone: TimeZone.current.identifier,
            now: JSONCoding.timestamp(Date())
        )
        do {
            let made: DayPlan = try await session.request("POST", "/api/plan", body: request, timeout: 120)
            plan = made
            lastError = nil
            save()
        } catch APIError.offline {
            lastError = "Couldn't reach the server. Check your connection and try again."
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Today's picks that are still to do: not checked off here, and not
    /// completed (or deleted) in Reminders.
    func open(in reminders: RemindersStore) -> [PlanSuggestion] {
        guard let plan = todaysPlan else { return [] }
        return plan.suggestions.filter { suggestion in
            !plan.finished.contains(suggestion.reminderId)
                && !isDismissed(suggestion.reminderId)
                && (reminders.item(externalId: suggestion.reminderId).map { !$0.isCompleted } ?? false)
        }
    }

    func isDismissed(_ reminderId: String, now: Date = Date()) -> Bool {
        guard let dismissal = dismissals[reminderId] else { return false }
        return dismissal.until.map { $0 > now } ?? true
    }

    /// Dismissals still in force, soonest to come back first, the permanent ones last.
    var activeDismissals: [PlanDismissal] {
        dismissals.values.filter { isDismissed($0.reminderId) }.sorted {
            ($0.until ?? .distantFuture) < ($1.until ?? .distantFuture)
        }
    }

    func loadDismissals(session: Session) async {
        do {
            let loaded: PlanDismissals = try await session.request("GET", "/api/plan/dismissals")
            dismissals = Dictionary(loaded.dismissals.map { ($0.reminderId, $0) }, uniquingKeysWith: { _, last in last })
        } catch {
            // Keep what we had; the plan still works, and the server filters too.
        }
    }

    /// Hides the reminder from today's plan now, and from new plans until then.
    func dismiss(_ reminderId: String, for length: DismissLength, session: Session) async {
        let previous = dismissals[reminderId]
        let dismissal = PlanDismissal(reminderId: reminderId, until: length.until())
        dismissals[reminderId] = dismissal
        do {
            let _: PlanDismissal = try await session.request(
                "PUT", Self.dismissalPath(reminderId), body: DismissBody(until: dismissal.until.map(JSONCoding.timestamp))
            )
            lastError = nil
        } catch {
            dismissals[reminderId] = previous
            lastError = "Couldn't dismiss it: \(error.localizedDescription)"
        }
    }

    /// Lets the reminder be suggested again.
    func restore(_ reminderId: String, session: Session) async {
        let previous = dismissals.removeValue(forKey: reminderId)
        do {
            let _: EmptyResponse = try await session.request("DELETE", Self.dismissalPath(reminderId))
            lastError = nil
        } catch {
            dismissals[reminderId] = previous
            lastError = "Couldn't bring it back: \(error.localizedDescription)"
        }
    }

    private static func dismissalPath(_ reminderId: String) -> String {
        "/api/plan/dismissals/" + (reminderId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? reminderId)
    }

    func markStarted(_ reminderId: String) {
        plan?.started.insert(reminderId)
        save()
    }

    func markFinished(_ reminderId: String) {
        plan?.finished.insert(reminderId)
        save()
    }

    private func save() {
        guard let plan, let data = try? Self.storeEncoder.encode(plan) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func reset() {
        plan = nil
        dismissals = [:]
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

// MARK: Home card

/// The wide card above the smart lists that opens today's plan.
struct PlanCard: View {
    @Environment(AppModel.self) private var model
    @Environment(PlannerStore.self) private var planner
    @Environment(RemindersStore.self) private var reminders

    var body: some View {
        Button {
            model.path.append(.plan)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.orange, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan My Day").font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if planner.isPlanning {
                    ProgressView()
                } else if planner.todaysPlan != nil {
                    let count = planner.open(in: reminders).count
                    Text("\(count)").font(.title2.bold()).fontDesign(.rounded)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if planner.isPlanning { return "Reading your reminders…" }
        if let plan = planner.todaysPlan { return plan.summary.isEmpty ? "Today's picks" : plan.summary }
        return "What to make progress on today"
    }
}

// MARK: Plan page

struct PlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant
    @Environment(PlannerStore.self) private var planner

    var body: some View {
        List {
            if let plan = planner.todaysPlan {
                if !plan.summary.isEmpty {
                    Section {
                        Text(plan.summary).font(.body)
                    } footer: {
                        Text("Made \(plan.madeAt.formatted(date: .omitted, time: .shortened)) from your open reminders.")
                    }
                }
                let shown = planner.open(in: reminders)
                if shown.isEmpty {
                    ContentUnavailableView("All Done", systemImage: "checkmark.circle",
                                           description: Text("Everything picked for today is finished or gone. Plan again for more."))
                }
                ForEach(shown) { suggestion in
                    if let item = reminders.item(externalId: suggestion.reminderId) {
                        Section {
                            SuggestionRow(item: item, suggestion: suggestion, started: planner.started.contains(item.externalId)) {
                                start(suggestion, item: item)
                            }
                        }
                    }
                }
            } else if planner.isPlanning {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading your reminders and picking what to work on today…").foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Claude reads your open reminders and picks the few worth making progress on today, with a first step for each. Where the assistant can help, one tap starts it.")
                            .foregroundStyle(.secondary)
                        Button {
                            plan()
                        } label: {
                            Label("Plan My Day", systemImage: "sparkles").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Your open reminders' titles, lists, dates and the start of their notes are sent to Claude to make the plan. The plan stays on this device.")
                }
            }
            if let error = planner.lastError {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            DismissedSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Today's Plan")
        .toolbar {
            if planner.todaysPlan != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Plan Again", systemImage: "arrow.clockwise") { plan() }
                        .disabled(planner.isPlanning)
                }
            }
        }
        .refreshable { if planner.todaysPlan != nil { await make() } }
        .task { await planner.loadDismissals(session: session) }
    }

    private func plan() {
        Task { await make() }
    }

    private func make() async {
        await planner.make(reminders: reminders, assistant: assistant, session: session)
    }

    private func start(_ suggestion: PlanSuggestion, item: ReminderItem) {
        planner.markStarted(item.externalId)
        model.path.append(.thread(item.externalId))
        Task { await assistant.send(suggestion.assistantPrompt, about: item, session: session) }
    }
}

private struct SuggestionRow: View {
    let item: ReminderItem
    let suggestion: PlanSuggestion
    let started: Bool
    let onStart: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant
    @Environment(PlannerStore.self) private var planner
    @Environment(Session.self) private var session

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Completes the reminder, like the circle on every reminder row.
            Button {
                planner.markFinished(item.externalId)
                Task { await reminders.setCompleted(item, true) }
            } label: {
                Image(systemName: "circle").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark as completed")

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.path.append(.thread(item.externalId))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title.isEmpty ? "Untitled" : item.title).font(.headline).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if let thread = assistant.summary(for: item.externalId) { ThreadBadge(thread: thread) }
                        }
                        Text(meta).font(.subheadline).foregroundStyle(item.isOverdue() ? .red : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !suggestion.reason.isEmpty {
                    Text(suggestion.reason).font(.subheadline).foregroundStyle(.secondary)
                }
                if !suggestion.nextStep.isEmpty {
                    Text(suggestion.nextStep).font(.subheadline)
                }
                HStack(spacing: 8) {
                    if !suggestion.assistantPrompt.isEmpty {
                        assistantButton
                    }
                    dismissMenu
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Leaves this reminder out of the plan for a while, or for good.
    private var dismissMenu: some View {
        Menu {
            ForEach(DismissLength.allCases) { length in
                Button(length.label, systemImage: length.symbol) {
                    Task { await planner.dismiss(item.externalId, for: length, session: session) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                Text("Dismiss")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }

    /// A small capsule that hands the suggested prompt to the assistant; the prompt shows on long press.
    @ViewBuilder
    private var assistantButton: some View {
        if started {
            Label("Assistant is on it", systemImage: "sparkles")
                .font(.subheadline)
                .foregroundStyle(.purple)
        } else {
            Button(action: onStart) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").symbolRenderingMode(.monochrome)
                    Text("Ask Assistant")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            // The Liquid Glass of the toolbar and the floating add button.
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .contextMenu {
                Text("Asks: \u{201C}\(suggestion.assistantPrompt)\u{201D}")
            }
        }
    }

    private var meta: String {
        var parts = [item.listTitle]
        if let due = item.dueDate { parts.append(DueText.short(due, hasTime: item.hasDueTime)) }
        if item.priority != .none { parts.append("\(item.priority.label) priority") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: Dismissed reminders

/// The reminders left out of the suggestions, with a way to bring each back.
private struct DismissedSection: View {
    @Environment(RemindersStore.self) private var reminders
    @Environment(PlannerStore.self) private var planner
    @Environment(Session.self) private var session
    @State private var expanded = false

    var body: some View {
        let shown = planner.activeDismissals.compactMap { dismissal in
            reminders.item(externalId: dismissal.reminderId).map { (dismissal, $0) }
        }
        if !shown.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(shown, id: \.0.reminderId) { dismissal, item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title.isEmpty ? "Untitled" : item.title)
                                Text(Self.untilText(dismissal.until)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Restore") {
                                Task { await planner.restore(dismissal.reminderId, session: session) }
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .font(.subheadline.weight(.medium))
                        }
                    }
                } label: {
                    Text("Not Suggesting (\(shown.count))").foregroundStyle(.secondary)
                }
            }
        }
    }

    static func untilText(_ until: Date?) -> String {
        guard let until else { return "Never suggested again" }
        if Calendar.current.isDateInTomorrow(until) && Calendar.current.startOfDay(for: until) == until {
            return "Back tomorrow"
        }
        return "Back \(until.formatted(date: .abbreviated, time: .omitted))"
    }
}
