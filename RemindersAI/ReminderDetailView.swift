import SwiftUI

/// A reminder's details, shown on its page above the conversation: date, time,
/// repeat, priority, list and link. Each change is saved to Reminders as it is
/// made; there is no Done button.
struct ReminderDetailsCard: View {
    let item: ReminderItem

    @Environment(RemindersStore.self) private var reminders

    @State private var url = ""
    @State private var hasDate = false
    @State private var hasTime = false
    @State private var date = Date()
    @State private var repeats = Repeat.never
    @State private var priority = Priority.none
    @State private var listId = ""
    @State private var loadedFrom: ReminderItem?
    @FocusState private var urlFocused: Bool

    private var tint: Color { reminders.color(for: item) }

    var body: some View {
        VStack(spacing: 0) {
            row("Date", symbol: "calendar") {
                if hasDate {
                    DatePicker("Date", selection: $date, displayedComponents: .date).labelsHidden()
                }
                Toggle("Date", isOn: $hasDate.animation()).labelsHidden()
            }
            if hasDate {
                Divider().padding(.leading, 44)
                row("Time", symbol: "clock") {
                    if hasTime {
                        DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute).labelsHidden()
                    }
                    Toggle("Time", isOn: $hasTime.animation()).labelsHidden()
                }
                Divider().padding(.leading, 44)
                row("Repeat", symbol: "repeat") {
                    Picker("Repeat", selection: $repeats) {
                        ForEach(Repeat.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            Divider().padding(.leading, 44)
            row("Priority", symbol: "exclamationmark.circle") {
                Picker("Priority", selection: $priority) {
                    ForEach(Priority.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            Divider().padding(.leading, 44)
            row("List", symbol: "list.bullet") {
                Picker("List", selection: $listId) {
                    ForEach(reminders.lists.filter { $0.isWritable || $0.id == item.listId }) { list in
                        Text(list.title).tag(list.id)
                    }
                }
                .labelsHidden()
            }
            Divider().padding(.leading, 44)
            HStack(spacing: 12) {
                Image(systemName: "link").foregroundStyle(tint).frame(width: 20)
                TextField("URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($urlFocused)
                    .onSubmit(save)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .tint(tint)
        .onAppear { load(item) }
        .onChange(of: item) { _, changed in
            // Pick up changes made elsewhere (the assistant, Reminders) unless
            // something here is still unsaved.
            if !isDirty { load(changed) }
        }
        .onChange(of: hasDate) { _, _ in save() }
        .onChange(of: hasTime) { _, on in
            // A newly added time starts at the next full hour, not midnight.
            if on, loadedFrom?.hasDueTime != true { date = Self.nextHour(on: date) }
            save()
        }
        .onChange(of: date) { _, _ in save() }
        .onChange(of: repeats) { _, _ in save() }
        .onChange(of: priority) { _, _ in save() }
        .onChange(of: listId) { _, _ in save() }
        .onChange(of: urlFocused) { _, focused in if !focused { save() } }
        .onDisappear(perform: save)
    }

    private func row(_ title: String, symbol: String, @ViewBuilder controls: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            Text(title)
            Spacer(minLength: 8)
            controls()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }

    static func nextHour(on day: Date, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let hour = (calendar.component(.hour, from: now) + 1) % 24
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    private var dueComponents: DateComponents? {
        DueDate.components(hasDate: hasDate, hasTime: hasTime, date: date)
    }

    private var isDirty: Bool {
        guard let loadedFrom else { return false }
        return priority != loadedFrom.priority || url != loadedFrom.url || listId != loadedFrom.listId
            || (hasDate ? repeats : .never) != loadedFrom.repeats
            || DueDate.string(from: dueComponents) != DueDate.string(from: loadedFrom.due)
    }

    private func load(_ item: ReminderItem) {
        url = item.url
        priority = item.priority
        repeats = item.repeats
        listId = item.listId
        hasDate = item.due != nil
        hasTime = item.hasDueTime
        date = item.dueDate ?? Date()
        loadedFrom = item
    }

    private func save() {
        guard isDirty, let current = reminders.item(id: item.id) else { return }
        let (due, newRepeats, newPriority, newURL, newList) = (dueComponents, hasDate ? repeats : .never, priority, url, listId)
        // Mark these values as the saved ones first, so the reload that follows
        // the save does not look like a change made elsewhere.
        loadedFrom?.due = due
        loadedFrom?.repeats = newRepeats
        loadedFrom?.priority = newPriority
        loadedFrom?.url = newURL
        loadedFrom?.listId = newList
        Task {
            await reminders.update(current, title: current.title, notes: current.notes, due: due, priority: newPriority,
                                   repeats: newRepeats, url: newURL, listId: newList)
            if let saved = reminders.item(id: item.id), !isDirty { load(saved) }
        }
    }
}
