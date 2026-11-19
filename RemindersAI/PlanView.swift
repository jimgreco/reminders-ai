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

    private enum CodingKeys: String, CodingKey { case summary, suggestions, madeAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        suggestions = try c.decode([PlanSuggestion].self, forKey: .suggestions)
        madeAt = try c.decodeIfPresent(Date.self, forKey: .madeAt) ?? Date()
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
    private(set) var started: Set<String> = []

    private static let key = "dayPlan"
    /// The longest list sent; the earliest due and highest priority go first.
    static let maxReminders = 400

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONCoding.decoder.decode(DayPlan.self, from: data),
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
            started = []
            lastError = nil
            if let data = try? JSONCoding.encoder.encode(made) { UserDefaults.standard.set(data, forKey: Self.key) }
        } catch APIError.offline {
            lastError = "Couldn't reach the server. Check your connection and try again."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func markStarted(_ reminderId: String) { started.insert(reminderId) }

    func reset() {
        plan = nil
        started = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

// MARK: Home card

/// The wide card above the smart lists that opens today's plan.
struct PlanCard: View {
    @Environment(AppModel.self) private var model
    @Environment(PlannerStore.self) private var planner

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
                } else if let count = planner.todaysPlan?.suggestions.count {
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
                let shown = plan.suggestions.filter { reminders.item(externalId: $0.reminderId).map { !$0.isCompleted } ?? false }
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
                        .buttonStyle(.borderedProminent)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Completes the reminder, like the circle on every reminder row.
            Button {
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
                if !suggestion.assistantPrompt.isEmpty {
                    assistantButton
                }
            }
        }
        .padding(.vertical, 4)
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
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.purple)
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
