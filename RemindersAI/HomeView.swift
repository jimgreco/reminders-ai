import SwiftUI

/// The lists screen, laid out like Reminders: smart lists on top, then My Lists.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @Environment(RemindersStore.self) private var reminders
    @Environment(AssistantStore.self) private var assistant
    @State private var showingSettings = false

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        SmartCard(title: "Today", symbol: "calendar", color: .blue,
                                  count: reminders.openCount(.today), filter: .today)
                        SmartCard(title: "Scheduled", symbol: "calendar.badge.clock", color: .red,
                                  count: reminders.openCount(.scheduled), filter: .scheduled)
                        SmartCard(title: "All", symbol: "tray.fill", color: .gray,
                                  count: reminders.openCount(.all), filter: .all)
                        SmartCard(title: "Assistant", symbol: "sparkles", color: .purple,
                                  count: reminders.openCount(.assistant, threadIds: assistant.threadIds),
                                  filter: .assistant, alert: assistant.needsYouCount)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("My Lists") {
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
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Reminders")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .refreshable { await model.refresh() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .list(let filter): ReminderListView(filter: filter)
                case .detail(let id): ReminderDetailView(itemId: id)
                case .thread(let externalId): ThreadView(reminderId: externalId)
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }
}

private struct SmartCard: View {
    let title: String
    let symbol: String
    let color: Color
    let count: Int
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
                    Text("\(count)").font(.title2.bold()).foregroundStyle(.primary)
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
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
