import SwiftUI

/// The lists screen, laid out like Reminders: search, smart lists, My Lists,
/// and New Reminder / Add List along the bottom.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant
    @State private var showingSettings = false
    @State private var showingNewReminder = false
    @State private var showingNewList = false
    @State private var editingList: ReminderList?
    @State private var deletingList: ReminderList?
    @State private var searchText = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            List {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    smartLists
                    myLists
                } else {
                    searchResults
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Reminders")
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItemGroup(placement: .addBar) {
                    Button {
                        showingNewReminder = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("New Reminder")
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                    }
                    Spacer()
                    Button("Add List") { showingNewList = true }.foregroundStyle(.blue)
                }
            }
            .refreshable { await model.refresh() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .list(let filter): ReminderListView(filter: filter)
                case .thread(let externalId): ThreadView(reminderId: externalId)
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingNewReminder) { NewReminderSheet(listId: reminders.defaultListId) }
            .sheet(isPresented: $showingNewList) { ListEditor(list: nil) }
            .sheet(item: $editingList) { ListEditor(list: $0) }
            .confirmationDialog(
                "Delete \u{201C}\(deletingList?.title ?? "")\u{201D}?",
                isPresented: Binding(get: { deletingList != nil }, set: { if !$0 { deletingList = nil } }),
                titleVisibility: .visible, presenting: deletingList
            ) { list in
                Button("Delete List", role: .destructive) {
                    Task { await reminders.deleteList(list) }
                }
            } message: { _ in
                Text("This deletes all reminders in this list, in Reminders too.")
            }
        }
    }

    private var smartLists: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                SmartCard(title: "Today", symbol: "calendar", color: .blue,
                          count: reminders.openCount(.today), filter: .today)
                SmartCard(title: "Scheduled", symbol: "calendar.badge.clock", color: .red,
                          count: reminders.openCount(.scheduled), filter: .scheduled)
                SmartCard(title: "All", symbol: "tray.fill", color: Color(.darkGray),
                          count: reminders.openCount(.all), filter: .all)
                SmartCard(title: "Assistant", symbol: "sparkles", color: .purple,
                          count: reminders.openCount(.assistant, threadIds: assistant.threadIds),
                          filter: .assistant, alert: assistant.needsYouCount)
                SmartCard(title: "Completed", symbol: "checkmark", color: .gray, count: nil, filter: .completed)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var myLists: some View {
        Section {
            ForEach(reminders.lists) { list in
                NavigationLink(value: Route.list(.list(list.id))) {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet")
                            .font(.footnote.bold())
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(list.color, in: Circle())
                        Text(list.title)
                        Spacer()
                        Text("\(reminders.openCount(.list(list.id)))").foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if list.isEditable {
                        Button("Delete", systemImage: "trash") { deletingList = list }.tint(.red)
                        Button("Info", systemImage: "info.circle") { editingList = list }.tint(.gray)
                    }
                }
                .contextMenu {
                    if list.isEditable {
                        Button("Show List Info", systemImage: "info.circle") { editingList = list }
                        Button("Delete List", systemImage: "trash", role: .destructive) { deletingList = list }
                    }
                }
            }
        } header: {
            Text("My Lists").font(.title2.bold()).foregroundStyle(Color.primary).textCase(nil)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = reminders.search(searchText)
        if results.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ForEach(results) { item in
                ReminderRow(item: item, showsList: true)
            }
        }
    }
}

private struct SmartCard: View {
    let title: String
    let symbol: String
    let color: Color
    /// Nil hides the number, as Reminders does for Completed.
    let count: Int?
    let filter: ReminderFilter
    var alert = 0

    @Environment(AppModel.self) private var model

    var body: some View {
        // A button, not a NavigationLink: inside a List a link adds a disclosure arrow beside the card.
        Button {
            model.path.append(.list(filter))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.body.bold())
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(color, in: Circle())
                    Spacer()
                    if let count {
                        Text("\(count)").font(.title2.bold()).fontDesign(.rounded).foregroundStyle(.primary)
                    }
                }
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    if alert > 0 {
                        Text("\(alert)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange, in: Capsule())
                            .accessibilityLabel("\(alert) waiting for you")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// New List, or a list's name and colour.
struct ListEditor: View {
    let list: ReminderList?

    @Environment(RemindersStore.self) private var reminders
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: ListColor?
    @FocusState private var nameFocused: Bool

    private var shown: Color { color?.color ?? list?.color ?? ListColor.blue.color }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "list.bullet")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 88)
                            .background(shown, in: Circle())
                        TextField("List Name", text: $name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(shown)
                            .padding(.vertical, 12)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            .focused($nameFocused)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(ListColor.allCases) { choice in
                            Button {
                                color = choice
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 38, height: 38)
                                    .overlay {
                                        if choice == color {
                                            Circle().stroke(Color(.systemGray2), lineWidth: 3).padding(-5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.rawValue.capitalized)
                            .accessibilityAddTraits(choice == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(list == nil ? "New List" : "List Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            if let list {
                                await reminders.updateList(list, title: name, color: color)
                            } else {
                                await reminders.createList(title: name, color: color ?? .blue)
                            }
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = list?.title ?? ""
                if list == nil {
                    color = .blue
                    nameFocused = true
                }
            }
        }
    }
}

/// The New Reminder sheet: title, notes, an optional date, and the list.
struct NewReminderSheet: View {
    let listId: String?

    @Environment(RemindersStore.self) private var reminders
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDate = false
    @State private var hasTime = false
    @State private var date = Date()
    @State private var selectedList = ""
    @FocusState private var titleFocused: Bool

    private var writableLists: [ReminderList] { reminders.lists.filter(\.isWritable) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical).focused($titleFocused)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8)
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
                    Picker(selection: $selectedList) {
                        ForEach(writableLists) { Text($0.title).tag($0.id) }
                    } label: {
                        Label("List", systemImage: "list.bullet")
                    }
                }
            }
            .navigationTitle("New Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await reminders.add(title: title, notes: notes, listId: selectedList.isEmpty ? listId : selectedList,
                                                due: DueDate.components(hasDate: hasDate, hasTime: hasTime, date: date))
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || writableLists.isEmpty)
                }
            }
            .onAppear {
                selectedList = listId ?? writableLists.first?.id ?? ""
                titleFocused = true
            }
        }
    }
}

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: session.email ?? "")
                    Button("Sign Out", role: .destructive) {
                        Task {
                            await session.signOut()
                            dismiss()
                        }
                    }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String ?? "")
                } footer: {
                    Text("Your tasks live in Apple Reminders. When you ask the assistant to work on one, that reminder's title, notes and dates are sent to the server and to Claude.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
