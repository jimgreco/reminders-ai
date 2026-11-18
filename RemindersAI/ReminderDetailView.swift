import SwiftUI

/// The Details sheet of one reminder, as in Reminders: title, notes, link,
/// date, time, repeat, priority and list.
struct ReminderDetailsSheet: View {
    let itemId: String

    @Environment(RemindersStore.self) private var reminders
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var url = ""
    @State private var hasDate = false
    @State private var hasTime = false
    @State private var date = Date()
    @State private var repeats = Repeat.never
    @State private var priority = Priority.none
    @State private var listId = ""
    @State private var loadedFrom: ReminderItem?
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            if let item = reminders.item(id: itemId) { await save(item) }
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func form(_ item: ReminderItem) -> some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...12)
                TextField("URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Toggle(isOn: $hasDate.animation()) { Label("Date", systemImage: "calendar") }
                if hasDate {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Toggle(isOn: $hasTime.animation()) { Label("Time", systemImage: "clock") }
                    if hasTime {
                        DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                    }
                    Picker(selection: $repeats) {
                        ForEach(Repeat.allCases) { Text($0.label).tag($0) }
                    } label: {
                        Label("Repeat", systemImage: "repeat")
                    }
                }
            }

            Section {
                Picker(selection: $priority) {
                    ForEach(Priority.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("Priority", systemImage: "exclamationmark.circle")
                }
                Picker(selection: $listId) {
                    ForEach(reminders.lists.filter { $0.isWritable || $0.id == item.listId }) { list in
                        Text(list.title).tag(list.id)
                    }
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
                Button("Delete Reminder", role: .destructive) { confirmingDelete = true }
            }

            if let error = reminders.lastError {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .onAppear { load(item) }
        .onChange(of: item) { _, changed in
            // Reload the fields when the reminder changes underneath (an edit by
            // the assistant or in Reminders), unless there are unsaved edits here.
            if !isDirty { load(changed) }
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Reminder", role: .destructive) {
                Task {
                    await reminders.delete(item)
                    dismiss()
                }
            }
        }
    }

    private var dueComponents: DateComponents? {
        DueDate.components(hasDate: hasDate, hasTime: hasTime, date: date)
    }

    private var isDirty: Bool {
        guard let loadedFrom else { return false }
        return title != loadedFrom.title || notes != loadedFrom.notes || priority != loadedFrom.priority
            || url != loadedFrom.url || listId != loadedFrom.listId
            || (hasDate ? repeats : .never) != loadedFrom.repeats
            || DueDate.string(from: dueComponents) != DueDate.string(from: loadedFrom.due)
    }

    private func load(_ item: ReminderItem) {
        title = item.title
        notes = item.notes
        url = item.url
        priority = item.priority
        repeats = item.repeats
        listId = item.listId
        hasDate = item.due != nil
        hasTime = item.hasDueTime
        date = item.dueDate ?? Date()
        loadedFrom = item
    }

    private func save(_ item: ReminderItem) async {
        guard isDirty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await reminders.update(item, title: title, notes: notes, due: dueComponents, priority: priority,
                               repeats: hasDate ? repeats : .never, url: url, listId: listId)
        if let saved = reminders.item(id: itemId) { load(saved) }
    }
}
