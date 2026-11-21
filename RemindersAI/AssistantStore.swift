import Foundation
import Observation

/// The assistant's side of each reminder: thread state from the server, and
/// the edits it queued, which this class applies to Apple Reminders.
@MainActor
@Observable
final class AssistantStore {
    private(set) var threads: [String: ThreadSummary] = [:]
    private(set) var details: [String: ThreadDetail] = [:]
    private(set) var sending: Set<String> = []
    var lastError: String?

    @ObservationIgnored private var syncTask: Task<Void, Never>?

    var threadIds: Set<String> { Set(threads.keys) }

    var needsYouCount: Int { threads.values.filter { $0.status == .needsInput || $0.unread }.count }

    func summary(for reminderId: String) -> ThreadSummary? { threads[reminderId] }

    func reset() {
        AttachmentImages.shared.clear()
        threads = [:]
        details = [:]
        sending = []
        lastError = nil
    }

    /// Fetches thread states and applies any queued edits. Runs on launch, on
    /// return to the foreground, and when a push arrives. Calls made while one
    /// is running wait for it instead of starting another.
    func sync(session: Session, reminders: RemindersStore) async {
        if let syncTask { return await syncTask.value }
        let task = Task { await runSync(session: session, reminders: reminders) }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func runSync(session: Session, reminders: RemindersStore) async {
        guard session.isSignedIn else { return }
        do {
            let response: SyncResponse = try await session.request("GET", "/api/sync")
            threads = Dictionary(response.threads.map { ($0.reminderId, $0) }, uniquingKeysWith: { a, _ in a })
            lastError = nil
            guard !response.ops.isEmpty, reminders.access == .granted else { return }
            for op in response.ops {
                var failure: String?
                do {
                    try reminders.apply(op)
                } catch {
                    failure = error.localizedDescription
                }
                // Acknowledged either way: an edit that cannot be applied is recorded, not retried forever.
                let _: EmptyResponse? = try? await session.request(
                    "POST", "/api/ops/\(op.id)/ack", body: failure.map { ["error": $0] } ?? [:]
                )
            }
            await reminders.reload()
        } catch APIError.offline {
            // Reminders keep working offline; the next sync catches up.
        } catch APIError.signedOut {
            // The sign-in screen is already showing; nothing to report here.
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func store(_ detail: ThreadDetail) {
        details[detail.reminderId] = detail
        threads[detail.reminderId] = detail.summary
    }

    func load(_ reminderId: String, session: Session) async {
        do {
            let detail: ThreadDetail = try await session.request("GET", APIPath.thread(reminderId))
            store(detail)
        } catch APIError.notFound {
            details[reminderId] = nil
            threads[reminderId] = nil
        } catch APIError.offline {
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Sends a message, with any photos as JPEGs. Returns false when it could not be sent.
    @discardableResult
    func send(_ text: String, photos: [Data] = [], about item: ReminderItem, session: Session) async -> Bool {
        let id = item.externalId
        sending.insert(id)
        defer { sending.remove(id) }
        do {
            var snapshot = item.snapshot()
            snapshot.location = await PlaceFinder.shared.current()
            let images = photos.map { ImageUpload(mediaType: "image/jpeg", data: $0.base64EncodedString()) }
            let detail: ThreadDetail = try await session.request(
                "POST", APIPath.thread(id, "/messages"),
                body: MessageRequest(text: text, reminder: snapshot, images: images)
            )
            store(detail)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func markRead(_ reminderId: String, session: Session) async {
        guard threads[reminderId]?.unread == true else { return }
        threads[reminderId]?.unread = false
        details[reminderId]?.unread = false
        let _: ThreadSummary? = try? await session.request("POST", APIPath.thread(reminderId, "/read"))
    }

    func stop(_ reminderId: String, session: Session) async {
        let _: ThreadSummary? = try? await session.request("POST", APIPath.thread(reminderId, "/stop"))
    }

    /// Carries a conversation over to its reminder's new id after a move between lists.
    func move(_ reminderId: String, to newId: String, session: Session) async {
        guard reminderId != newId else { return }
        if let detail = details.removeValue(forKey: reminderId) { details[newId] = detail }
        if let summary = threads.removeValue(forKey: reminderId) { threads[newId] = summary }
        guard threads[newId] != nil else { return }
        struct Body: Encodable { let to: String }
        do {
            let _: ThreadSummary = try await session.request("POST", APIPath.thread(reminderId, "/move"), body: Body(to: newId))
            await load(newId, session: session)
        } catch {
            lastError = "The conversation couldn't follow the reminder to its new list: \(error.localizedDescription)"
        }
    }

    func delete(_ reminderId: String, session: Session) async {
        let _: EmptyResponse? = try? await session.request("DELETE", APIPath.thread(reminderId))
        details[reminderId] = nil
        threads[reminderId] = nil
    }

    func registerDevice(token: String, session: Session) async {
        struct Body: Encodable { let token: String; let sandbox: Bool }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        let _: EmptyResponse? = try? await session.request("POST", "/api/devices", body: Body(token: token, sandbox: sandbox))
    }
}
