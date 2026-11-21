import Foundation

enum JSONCoding {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: value) ?? plain.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(value)"))
        }
        return d
    }()

    static let encoder = JSONEncoder()

    static func timestamp(_ date: Date) -> String { fractional.string(from: date) }
}

// MARK: Assistant threads

enum ThreadStatus: String, Codable, Sendable {
    case idle, working, error
    case needsInput = "needs_input"

    init(from decoder: Decoder) throws {
        self = ThreadStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .idle
    }
}

struct ThreadSummary: Codable, Equatable, Sendable {
    var reminderId: String
    var title: String
    var status: ThreadStatus
    var unread: Bool
    var updatedAt: Date
}

enum MessageRole: String, Codable, Sendable {
    case user, assistant, question, activity, error

    init(from decoder: Decoder) throws {
        self = MessageRole(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .activity
    }
}

/// A photo sent with a message; its image is fetched separately.
struct Attachment: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var mediaType: String
}

struct ThreadMessage: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var role: MessageRole
    var text: String
    var options: [String]?
    var attachments: [Attachment]?
    var createdAt: Date
}

struct ThreadDetail: Codable, Equatable, Sendable {
    var reminderId: String
    var title: String
    var status: ThreadStatus
    var unread: Bool
    var updatedAt: Date
    var messages: [ThreadMessage]

    var summary: ThreadSummary {
        ThreadSummary(reminderId: reminderId, title: title, status: status, unread: unread, updatedAt: updatedAt)
    }

    /// The question waiting for an answer, if the assistant is blocked on one.
    var openQuestion: ThreadMessage? {
        guard status == .needsInput else { return nil }
        return messages.last { $0.role == .question }
    }
}

// MARK: Edits the assistant queued for Apple Reminders

enum DueChange: Equatable, Sendable {
    case unchanged
    case clear
    case set(String)
}

struct OpPayload: Decodable, Equatable, Sendable {
    var title: String?
    var notes: String?
    var due: DueChange
    var priority: String?

    enum CodingKeys: String, CodingKey { case title, notes, due, priority }

    init(title: String? = nil, notes: String? = nil, due: DueChange = .unchanged, priority: String? = nil) {
        self.title = title
        self.notes = notes
        self.due = due
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        // A missing key leaves the due date alone; an explicit null clears it.
        if !c.contains(.due) {
            due = .unchanged
        } else if try c.decodeNil(forKey: .due) {
            due = .clear
        } else {
            due = .set(try c.decode(String.self, forKey: .due))
        }
    }
}

struct PendingOp: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var reminderId: String
    var kind: String
    var payload: OpPayload
}

struct SyncResponse: Decodable, Sendable {
    var threads: [ThreadSummary]
    var ops: [PendingOp]
}

/// The reminder as it is on this iPhone, sent along with each message.
struct ReminderSnapshot: Encodable, Sendable {
    var title: String
    var notes: String
    var list: String
    var due: String
    var priority: String
    var completed: Bool
    var timeZone: String
    var now: String
    /// The town the phone is in, when location is allowed.
    var location: String?
}

struct ImageUpload: Encodable, Sendable {
    var mediaType: String
    /// Base64 of the image bytes.
    var data: String
}

struct MessageRequest: Encodable, Sendable {
    var text: String
    var reminder: ReminderSnapshot
    var images: [ImageUpload] = []
}

// MARK: Due dates and priorities

/// Due dates travel as `YYYY-MM-DD` (all day) or `YYYY-MM-DDTHH:MM`, in the
/// phone's own time zone, which is how Reminders stores them.
enum DueDate {
    static func components(from value: String) -> DateComponents? {
        let parts = value.split(separator: "T", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return nil }
        let day = first.split(separator: "-").compactMap { Int($0) }
        guard first.count == 10, day.count == 3, (1...12).contains(day[1]), (1...31).contains(day[2]) else { return nil }
        var components = DateComponents(year: day[0], month: day[1], day: day[2])
        if parts.count == 2 {
            let time = parts[1].split(separator: ":").compactMap { Int($0) }
            guard parts[1].count == 5, time.count == 2, (0..<24).contains(time[0]), (0..<60).contains(time[1]) else { return nil }
            components.hour = time[0]
            components.minute = time[1]
        }
        components.calendar = Calendar.current
        guard components.isValidDate else { return nil }
        return components
    }

    /// The due date a date picker and its two switches describe.
    static func components(hasDate: Bool, hasTime: Bool, date: Date) -> DateComponents? {
        guard hasDate else { return nil }
        let units: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        var components = Calendar.current.dateComponents(units, from: date)
        components.calendar = Calendar.current
        return components
    }

    static func string(from components: DateComponents?) -> String {
        guard let c = components, let year = c.year, let month = c.month, let day = c.day else { return "" }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour = c.hour else { return date }
        return date + String(format: "T%02d:%02d", hour, c.minute ?? 0)
    }
}

enum Priority: String, CaseIterable, Identifiable, Sendable {
    case none, low, medium, high

    var id: String { rawValue }

    /// EventKit priorities: 0 none, 1-4 high, 5 medium, 6-9 low.
    init(eventKit value: Int) {
        switch value {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    var eventKit: Int {
        switch self {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }

    var label: String { rawValue.capitalized }

    var marks: String {
        switch self {
        case .none: ""
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }
}

enum APIPath {
    /// Reminder identifiers can hold `/` and `:`; only letters, digits and `-._~` go through as they are.
    static func thread(_ reminderId: String, _ suffix: String = "") -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = reminderId.addingPercentEncoding(withAllowedCharacters: allowed) ?? reminderId
        return "/api/threads/\(encoded)\(suffix)"
    }
}
