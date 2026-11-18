import SwiftUI

/// The assistant's conversation about one reminder.
struct ThreadView: View {
    let reminderId: String

    @Environment(Session.self) private var session
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant
    @State private var draft = ""
    @State private var confirmingDelete = false
    @FocusState private var inputFocused: Bool

    private static let starters = ["Work on this", "What's the first step?", "Research this for me", "Break this down"]

    private var item: ReminderItem? { reminders.item(externalId: reminderId) }
    private var detail: ThreadDetail? { assistant.details[reminderId] }
    private var status: ThreadStatus { detail?.status ?? assistant.summary(for: reminderId)?.status ?? .idle }
    private var isSending: Bool { assistant.sending.contains(reminderId) }

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
                    } else if assistant.summary(for: reminderId) != nil {
                        // The thread exists and is still loading: no starters to tap by mistake.
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
                    if let error = assistant.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: detail?.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: status) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Options", systemImage: "ellipsis.circle") {
                    if status == .working {
                        Button("Stop Working", systemImage: "stop.circle") {
                            Task { await assistant.stop(reminderId, session: session) }
                        }
                    }
                    Button("Delete Conversation", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(detail == nil)
                }
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                Task { await assistant.delete(reminderId, session: session) }
            }
        } message: {
            Text("The reminder itself stays in Reminders.")
        }
        .task(id: reminderId) { await assistant.load(reminderId, session: session) }
        .task(id: status) { await follow() }
    }

    /// Keeps the thread fresh: often while the assistant is working, slowly
    /// otherwise. Restarts whenever the status changes, so a turn that just
    /// ended is marked read and its queued edits reach Reminders right away.
    private func follow() async {
        if status != .working {
            await assistant.markRead(reminderId, session: session)
            await assistant.sync(session: session, reminders: reminders)
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(status == .working ? 2.5 : 20))
            guard !Task.isCancelled else { return }
            await assistant.load(reminderId, session: session)
            await assistant.markRead(reminderId, session: session)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item?.title ?? detail?.title ?? "Reminder").font(.title3.bold())
            if let item {
                let facts = [item.listTitle, item.dueDate.map { DueText.short($0, hasTime: item.hasDueTime) }]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                }
                if !item.notes.isEmpty {
                    Text(item.notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                }
            } else {
                Text("This reminder isn't on this iPhone any more.").font(.subheadline).foregroundStyle(.secondary)
            }
            Divider().padding(.top, 8)
        }
    }

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
            TextField(detail?.openQuestion == nil ? "Message" : "Your answer", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
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
        Task { await assistant.send(trimmed, about: item, session: session) }
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
            Text(Self.rich(message.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .question:
            VStack(alignment: .leading, spacing: 10) {
                Label("Question", systemImage: "questionmark.bubble.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text(Self.rich(message.text))
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

    /// Bold, italics and links from the assistant's Markdown; line breaks kept.
    static func rich(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
