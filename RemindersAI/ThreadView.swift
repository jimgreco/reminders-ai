import SwiftUI

/// One reminder: its title and notes, editable in place, with the assistant's
/// conversation about it underneath. Opening a reminder lands here, ready to
/// start chatting or to pick up where the conversation left off.
struct ThreadView: View {
    let reminderId: String

    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant
    @State private var draft = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var loadedFrom: ReminderItem?
    @State private var showingDetails = false
    @State private var confirmingDeleteConversation = false
    @State private var confirmingDeleteReminder = false
    @FocusState private var focus: Field?

    private enum Field { case title, notes, message }

    private static let starters = ["Work on this", "What's the first step?", "Research this for me", "Break this down"]

    private var item: ReminderItem? { reminders.item(externalId: reminderId) }
    private var detail: ThreadDetail? { assistant.details[reminderId] }
    private var hasThread: Bool { assistant.summary(for: reminderId) != nil }
    private var status: ThreadStatus { detail?.status ?? assistant.summary(for: reminderId)?.status ?? .idle }
    private var isSending: Bool { assistant.sending.contains(reminderId) }
    private var tint: Color { item.map(reminders.color(for:)) ?? .accentColor }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header
                    if let detail {
                        ForEach(detail.messages) { message in
                            MessageView(message: message, isOpenQuestion: message.id == detail.openQuestion?.id) { answer in
                                send(answer)
                            }
                        }
                    } else if hasThread {
                        // The conversation exists and is still loading: no starters to tap by mistake.
                        ProgressView().frame(maxWidth: .infinity)
                    } else if !isSending {
                        starterButtons
                    }
                    if status == .working || isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working on it. You can leave; you'll get a notification.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    if let error = assistant.lastError ?? reminders.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: detail?.messages.count) { old, _ in
                // Opening a reminder shows it from the top; new messages scroll into view.
                guard old != nil else { return }
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: status) { _, new in
                if new == .working { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Options", systemImage: "ellipsis.circle") {
                    if let item {
                        Button("Details", systemImage: "info.circle") { openDetails() }
                        Button(item.isCompleted ? "Mark as Not Completed" : "Mark as Completed", systemImage: "checkmark.circle") {
                            Task { await reminders.setCompleted(item, !item.isCompleted) }
                        }
                    }
                    if status == .working {
                        Button("Stop Working", systemImage: "stop.circle") {
                            Task { await assistant.stop(reminderId, session: session) }
                        }
                    }
                    Divider()
                    if hasThread {
                        Button("Delete Conversation", systemImage: "bubble.left.and.bubble.right", role: .destructive) {
                            confirmingDeleteConversation = true
                        }
                    }
                    if item != nil {
                        Button("Delete Reminder", systemImage: "trash", role: .destructive) { confirmingDeleteReminder = true }
                    }
                }
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDeleteConversation, titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                Task { await assistant.delete(reminderId, session: session) }
            }
        } message: {
            Text("The reminder itself stays in Reminders.")
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmingDeleteReminder, titleVisibility: .visible) {
            Button("Delete Reminder", role: .destructive) {
                Task {
                    if let item { await reminders.delete(item) }
                    if hasThread { await assistant.delete(reminderId, session: session) }
                    if !model.path.isEmpty { model.path.removeLast() }
                }
            }
        } message: {
            Text(hasThread ? "Its conversation with the assistant is deleted too." : "")
        }
        .sheet(isPresented: $showingDetails) {
            if let item { ReminderDetailsSheet(itemId: item.id) }
        }
        .onAppear { if let item { loadFields(item) } }
        .onChange(of: item) { _, changed in
            // Pick up edits made elsewhere (the assistant, the Details sheet,
            // Reminders) unless there is unsaved typing here.
            if let changed, !fieldsDirty { loadFields(changed) }
        }
        .onChange(of: focus) { old, _ in
            if old == .title || old == .notes { saveFields() }
        }
        .onDisappear { saveFields() }
        .task(id: reminderId) {
            if hasThread { await assistant.load(reminderId, session: session) }
        }
        .task(id: status) { await follow() }
    }

    /// Keeps the conversation fresh: often while the assistant is working,
    /// slowly otherwise. Restarts whenever the status changes, so a turn that
    /// just ended is marked read and its queued edits reach Reminders right
    /// away. A reminder with no conversation has nothing to follow.
    private func follow() async {
        guard hasThread else { return }
        if status != .working {
            await assistant.markRead(reminderId, session: session)
            await assistant.sync(session: session, reminders: reminders)
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(status == .working ? 2.5 : 20))
            guard !Task.isCancelled, hasThread else { return }
            await assistant.load(reminderId, session: session)
            await assistant.markRead(reminderId, session: session)
        }
    }

    // MARK: The reminder

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        Task { await reminders.setCompleted(item, !item.isCompleted) }
                    } label: {
                        Image(systemName: item.isCompleted ? "largecircle.fill.circle" : "circle")
                            .font(.title2)
                            .foregroundStyle(item.isCompleted ? tint : .secondary)
                            .padding(.top, 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isCompleted ? "Mark as not completed" : "Mark as completed")

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Title", text: $title, axis: .vertical)
                            .font(.title3.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .focused($focus, equals: .title)
                        TextField("Add Note", text: $notes, axis: .vertical)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .focused($focus, equals: .notes)
                    }
                }
                Button(action: openDetails) {
                    HStack(spacing: 6) {
                        Text(facts(item))
                            .font(.subheadline)
                            .foregroundStyle(item.isOverdue() ? .red : .secondary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "info.circle").foregroundStyle(tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details")
                .accessibilityValue(facts(item))
            } else {
                Text(detail?.title ?? "Reminder").font(.title3.bold())
                Text("This reminder isn't on this iPhone any more.").font(.subheadline).foregroundStyle(.secondary)
            }
            Divider().padding(.top, 4)
        }
    }

    private func facts(_ item: ReminderItem) -> String {
        var parts = [item.listTitle]
        if let due = item.dueDate { parts.append(DueText.short(due, hasTime: item.hasDueTime)) }
        if item.repeats != .never { parts.append(item.repeats.label) }
        if item.priority != .none { parts.append("\(item.priority.label) priority") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var fieldsDirty: Bool {
        guard let loadedFrom else { return false }
        return title != loadedFrom.title || notes != loadedFrom.notes
    }

    private func loadFields(_ item: ReminderItem) {
        title = item.title
        notes = item.notes
        loadedFrom = item
    }

    private func saveFields() {
        guard fieldsDirty, let item else { return }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = item.title }
        let (newTitle, newNotes) = (title, notes)
        loadedFrom?.title = newTitle
        loadedFrom?.notes = newNotes
        Task { await reminders.rename(item, title: newTitle, notes: newNotes) }
    }

    private func openDetails() {
        saveFields()
        focus = nil
        showingDetails = true
    }

    // MARK: The conversation

    private var starterButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The assistant can research this, ask you what it needs to know, update the reminder and keep going until it's done.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(Self.starters, id: \.self) { starter in
                Button(starter) { send(starter) }
                    .buttonStyle(.bordered)
                    .tint(.purple)
            }
        }
        .disabled(item == nil)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(detail?.openQuestion == nil ? "Ask the assistant" : "Your answer", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focus, equals: .message)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .tint(.purple)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || item == nil)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending, let item else { return }
        if trimmed == draft.trimmingCharacters(in: .whitespacesAndNewlines) { draft = "" }
        Task {
            // The assistant should see the title and notes as they are on screen.
            if fieldsDirty {
                await reminders.rename(item, title: title, notes: notes)
            }
            let current = reminders.item(externalId: reminderId) ?? item
            loadFields(current)
            await assistant.send(trimmed, about: current, session: session)
        }
    }
}

private struct MessageView: View {
    let message: ThreadMessage
    let isOpenQuestion: Bool
    let answer: (String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(.purple, in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
        case .assistant:
            SelectableText(markdown: message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .question:
            VStack(alignment: .leading, spacing: 10) {
                Label("Question", systemImage: "questionmark.bubble.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                SelectableText(markdown: message.text)
                if isOpenQuestion, let options = message.options, !options.isEmpty {
                    ForEach(options, id: \.self) { option in
                        Button(option) { answer(option) }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        case .activity:
            Label(message.text, systemImage: "sparkle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
