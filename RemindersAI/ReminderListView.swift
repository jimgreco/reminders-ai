import SwiftUI

struct ReminderListView: View {
    let filter: ReminderFilter

    @Environment(AppModel.self) private var model
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant
    @State private var showCompleted = false
    @State private var editingList: ReminderList?
    @State private var confirmingDeleteList = false
    @State private var newTitle = ""
    @FocusState private var addingFocused: Bool

    private var title: String {
        switch filter {
        case .today: "Today"
        case .scheduled: "Scheduled"
        case .all: "All"
        case .completed: "Completed"
        case .assistant: "Assistant"
        case .list(let id): reminders.list(id)?.title ?? "List"
        }
    }

    private var tint: Color {
        switch filter {
        case .today: .blue
        case .scheduled: .red
        case .all: Color(.darkGray)
        case .completed: .gray
        case .assistant: .purple
        case .list(let id): reminders.list(id)?.color ?? .accentColor
        }
    }

    /// New reminders go to the list on screen, or to the default list from a smart list.
    private var targetListId: String? {
        if case .list(let id) = filter { return id }
        return reminders.defaultListId
    }

    private var canAdd: Bool {
        guard filter != .assistant, filter != .completed, let id = targetListId else { return false }
        return reminders.list(id)?.isWritable ?? false
    }

    var body: some View {
        let items = reminders.items(for: filter, includeCompleted: showCompleted, threadIds: assistant.threadIds)
        List {
            // The big coloured title Reminders puts at the top of a list.
            Text(title)
                .font(.largeTitle.bold())
                .fontDesign(.rounded)
                .foregroundStyle(tint)
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                ReminderRow(item: item, showsList: !isSingleList)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await reminders.delete(item) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button(item.isCompleted ? "Not Done" : "Done", systemImage: "checkmark") {
                            Task { await reminders.setCompleted(item, !item.isCompleted) }
                        }
                        .tint(.green)
                    }
            }
            if canAdd {
                HStack(spacing: 12) {
                    Image(systemName: "circle").font(.title3).foregroundStyle(.tertiary)
                    TextField("New Reminder", text: $newTitle)
                        .focused($addingFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty && !canAdd {
                ContentUnavailableView(
                    filter == .assistant ? "Nothing with the assistant yet" : "No Reminders",
                    systemImage: filter == .assistant ? "sparkles" : "checklist",
                    description: Text(filter == .assistant ? "Swipe a reminder to the right, or open it, to have the assistant work on it." : "")
                )
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .tint(tint)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Options", systemImage: "ellipsis.circle") {
                    if filter != .completed {
                        Toggle("Show Completed", systemImage: "eye", isOn: $showCompleted)
                    }
                    if let list = editableList {
                        Button("Show List Info", systemImage: "info.circle") { editingList = list }
                        Button("Delete List", systemImage: "trash", role: .destructive) { confirmingDeleteList = true }
                    }
                }
            }
            if canAdd {
                ToolbarItemGroup(placement: .addBar) {
                    Button {
                        addingFocused = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("New Reminder")
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(tint)
                    }
                    Spacer()
                }
            }
        }
        .refreshable { await model.refresh() }
        .sheet(item: $editingList) { ListEditor(list: $0) }
        .confirmationDialog("Delete \u{201C}\(title)\u{201D}?", isPresented: $confirmingDeleteList, titleVisibility: .visible) {
            Button("Delete List", role: .destructive) {
                guard let list = editableList else { return }
                Task {
                    await reminders.deleteList(list)
                    if !model.path.isEmpty { model.path.removeLast() }
                }
            }
        } message: {
            Text("This deletes all reminders in this list, in Reminders too.")
        }
    }

    /// The list on screen, when it is one the account lets this app rename or delete.
    private var editableList: ReminderList? {
        guard case .list(let id) = filter, let list = reminders.list(id), list.isEditable else { return nil }
        return list
    }

    /// Today's reminders are added due today, as in Reminders.
    private var newDue: DateComponents? {
        filter == .today ? DueDate.components(hasDate: true, hasTime: false, date: Date()) : nil
    }

    private var isSingleList: Bool {
        if case .list = filter { return true }
        return false
    }

    private func add() {
        let title = newTitle
        newTitle = ""
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await reminders.add(title: title, listId: targetListId, due: newDue)
            addingFocused = true
        }
    }
}

struct ReminderRow: View {
    let item: ReminderItem
    var showsList = false

    @Environment(AppModel.self) private var model
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await reminders.setCompleted(item, !item.isCompleted) }
            } label: {
                Image(systemName: item.isCompleted ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? reminders.color(for: item) : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Mark as not completed" : "Mark as completed")

            Button {
                model.path.append(.thread(item.externalId))
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if item.priority != .none {
                            Text(item.priority.marks).foregroundStyle(reminders.color(for: item)).fontWeight(.semibold)
                        }
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .foregroundStyle(item.isCompleted ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                    }
                    if !item.notes.isEmpty {
                        Text(item.notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(item.isOverdue() ? .red : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let thread = assistant.summary(for: item.externalId) {
                ThreadBadge(thread: thread)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if showsList, !item.listTitle.isEmpty { parts.append(item.listTitle) }
        if let due = item.dueDate { parts.append(DueText.short(due, hasTime: item.hasDueTime)) }
        if item.repeats != .never { parts.append(item.repeats.label) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The assistant's state on a reminder, shown at the end of its row.
struct ThreadBadge: View {
    let thread: ThreadSummary

    var body: some View {
        Group {
            switch thread.status {
            case .working:
                ProgressView().controlSize(.small)
            case .needsInput:
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
            case .error:
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.red)
            case .idle:
                Image(systemName: thread.unread ? "sparkles" : "sparkle")
                    .foregroundStyle(thread.unread ? .purple : .secondary)
            }
        }
        .font(.body)
        .frame(width: 30, height: 30)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch thread.status {
        case .working: "Assistant is working"
        case .needsInput: "Assistant has a question"
        case .error: "Assistant stopped"
        case .idle: thread.unread ? "Assistant has a new reply" : "Assistant thread"
        }
    }
}

enum DueText {
    static func short(_ date: Date, hasTime: Bool, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInTomorrow(date) {
            day = "Tomorrow"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return hasTime ? "\(day), \(date.formatted(date: .omitted, time: .shortened))" : day
    }
}
