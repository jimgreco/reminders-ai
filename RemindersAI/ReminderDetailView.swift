import SwiftUI

/// One reminder: its fields, editable as in Reminders, and the way into its
/// assistant thread.
struct ReminderDetailView: View {
    let itemId: String

    @Environment(AppModel.self) private var model
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDate = false
    @State private var hasTime = false
    @State private var date = Date()
    @State private var priority = Priority.none
    @State private var loadedFrom: ReminderItem?

    var body: some View {
        Group {
            if let item = reminders.item(id: itemId) {
                form(item)
            } else {
                ContentUnavailableView("Reminder not found", systemImage: "checklist",
                                       description: Text("It may have been deleted in Reminders."))
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ item: ReminderItem) -> some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...12)
            }

            Section {
                Button {
                    Task {
                        await save(item)
                        model.path.append(.thread(item.externalId))
                    }
                } label: {
                    AssistantEntry(thread: assistant.summary(for: item.externalId))
                }
            }

            Section {
                Toggle(isOn: $hasDate.animation()) { Label("Date", systemImage: "calendar") }
                if hasDate {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Toggle(isOn: $hasTime.animation()) { Label("Time", systemImage: "clock") }
                    if hasTime {
                        DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                    }
                }
            }

            Section {
                Picker(selection: $priority) {
                    ForEach(Priority.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("Priority", systemImage: "exclamationmark.circle")
                }
                LabeledContent {
                    Text(item.listTitle)
                } label: {
                    Label("List", systemImage: "list.bullet")
                }
            }

            Section {
                Button(item.isCompleted ? "Mark as Not Completed" : "Mark as Completed") {
                    Task {
                        await save(item)
                        await reminders.setCompleted(item, !item.isCompleted)
                    }
                }
                Button("Delete Reminder", role: .destructive) {
                    Task {
                        await reminders.delete(item)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { load(item) }
        .onChange(of: item) { _, changed in
            // Reload the fields when the reminder changes underneath (an edit by
            // the assistant or in Reminders), unless there are unsaved edits here.
            if !isDirty { load(changed) }
        }
        .onDisappear {
            if let current = reminders.item(id: itemId) { Task { await save(current) } }
        }
    }

    private var dueComponents: DateComponents? {
        guard hasDate else { return nil }
        let units: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        var components = Calendar.current.dateComponents(units, from: date)
        components.calendar = Calendar.current
        return components
    }

    private var isDirty: Bool {
        guard let loadedFrom else { return false }
        return title != loadedFrom.title || notes != loadedFrom.notes || priority != loadedFrom.priority
            || DueDate.string(from: dueComponents) != DueDate.string(from: loadedFrom.due)
    }

    private func load(_ item: ReminderItem) {
        title = item.title
        notes = item.notes
        priority = item.priority
        hasDate = item.due != nil
        hasTime = item.hasDueTime
        date = item.dueDate ?? Date()
        loadedFrom = item
    }

    private func save(_ item: ReminderItem) async {
        guard isDirty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await reminders.update(item, title: title, notes: notes, due: dueComponents, priority: priority)
        if let saved = reminders.item(id: itemId) { loadedFrom = saved }
    }
}

private struct AssistantEntry: View {
    let thread: ThreadSummary?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.body.bold())
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.purple, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(thread == nil ? "Work on this" : "Assistant").foregroundStyle(Color.primary)
                Text(status).font(.subheadline).foregroundStyle(statusColor)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
        }
    }

    private var status: String {
        guard let thread else { return "Research it, ask me questions, help me finish" }
        switch thread.status {
        case .working: return "Working on it…"
        case .needsInput: return "Has a question for you"
        case .error: return "Stopped before finishing"
        case .idle: return thread.unread ? "New reply" : "Open the conversation"
        }
    }

    private var statusColor: Color {
        switch thread?.status {
        case .needsInput: .orange
        case .error: .red
        default: .secondary
        }
    }
}
