import XCTest
@testable import RemindersAI

final class RemindersAITests: XCTestCase {
    func testDueDateParsesDaysAndTimes() {
        let day = DueDate.components(from: "2026-12-01")
        XCTAssertEqual(day?.year, 2026)
        XCTAssertEqual(day?.month, 12)
        XCTAssertEqual(day?.day, 1)
        XCTAssertNil(day?.hour)

        let timed = DueDate.components(from: "2026-12-01T09:30")
        XCTAssertEqual(timed?.hour, 9)
        XCTAssertEqual(timed?.minute, 30)

        for bad in ["", "tomorrow", "2026-13-01", "2026-02-30", "2026-12-01T25:00", "2026-12-01T9:30", "2026-12-1"] {
            XCTAssertNil(DueDate.components(from: bad), bad)
        }
    }

    func testDueDateRoundTrips() {
        for value in ["2026-12-01", "2027-01-09T07:05"] {
            XCTAssertEqual(DueDate.string(from: DueDate.components(from: value)), value)
        }
        XCTAssertEqual(DueDate.string(from: nil), "")
    }

    func testPriorityMapsToEventKit() {
        XCTAssertEqual(Priority(eventKit: 0), .none)
        XCTAssertEqual(Priority(eventKit: 1), .high)
        XCTAssertEqual(Priority(eventKit: 4), .high)
        XCTAssertEqual(Priority(eventKit: 5), .medium)
        XCTAssertEqual(Priority(eventKit: 9), .low)
        for priority in Priority.allCases {
            XCTAssertEqual(Priority(eventKit: priority.eventKit), priority)
        }
    }

    func testEditPayloadTellsClearingFromLeavingAlone() throws {
        func payload(_ json: String) throws -> OpPayload {
            try JSONCoding.decoder.decode(OpPayload.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try payload(#"{"title":"A"}"#), OpPayload(title: "A", due: .unchanged))
        XCTAssertEqual(try payload(#"{"due":null}"#), OpPayload(due: .clear))
        XCTAssertEqual(try payload(#"{"due":"2026-12-01","priority":"high","notes":"n"}"#),
                       OpPayload(notes: "n", due: .set("2026-12-01"), priority: "high"))
    }

    func testSyncResponseDecodes() throws {
        let json = #"""
        {"threads":[{"reminderId":"r1","title":"T","status":"needs_input","unread":true,"updatedAt":"2026-11-18T12:00:00.123Z"},
                    {"reminderId":"r2","title":"U","status":"something_new","unread":false,"updatedAt":"2026-11-18T12:00:00Z"}],
         "ops":[{"id":"o1","reminderId":"r1","kind":"complete","payload":{},"createdAt":"2026-11-18T12:00:00.000Z"}]}
        """#
        let sync = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(json.utf8))
        XCTAssertEqual(sync.threads.map(\.status), [.needsInput, .idle])
        XCTAssertEqual(sync.ops.first?.kind, "complete")
        XCTAssertEqual(sync.ops.first?.payload, OpPayload())
    }

    func testSyncResponseCarriesCommitmentsWhenTheServerSendsThem() throws {
        let json = #"""
        {"threads":[],"ops":[],"commitments":[
          {"week":"2026-11-23","id":"c1","text":"Book the dentist","measure":null,"area":"home","active":true,
           "reminderId":null,"done":false,"due":"2026-11-29"}]}
        """#
        let sync = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(json.utf8))
        XCTAssertEqual(sync.commitments, [Commitment(week: "2026-11-23", id: "c1", text: "Book the dentist", measure: nil,
                                                     active: true, reminderId: nil, done: false, due: "2026-11-29")])
        let older = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(#"{"threads":[],"ops":[]}"#.utf8))
        XCTAssertNil(older.commitments)
    }

    func testCommitmentActions() {
        func commitment(active: Bool = true, reminderId: String? = nil, done: Bool = false) -> Commitment {
            Commitment(week: "2026-11-23", id: "c1", text: "Walk", measure: nil, active: active,
                       reminderId: reminderId, done: done, due: "2026-11-29")
        }
        // No reminder yet: make one only while it is wanted.
        XCTAssertEqual(CommitmentSync.action(for: commitment(), reminderCompleted: nil), .create)
        XCTAssertEqual(CommitmentSync.action(for: commitment(active: false), reminderCompleted: nil), .none)
        // A reminder this phone can't find yet is left alone, never made twice.
        XCTAssertEqual(CommitmentSync.action(for: commitment(reminderId: "r"), reminderCompleted: nil), .none)
        XCTAssertEqual(CommitmentSync.action(for: commitment(active: false, reminderId: "r"), reminderCompleted: nil), .none)
        // Checking off, and un-checking, are reported once.
        XCTAssertEqual(CommitmentSync.action(for: commitment(reminderId: "r"), reminderCompleted: true), .report(done: true))
        XCTAssertEqual(CommitmentSync.action(for: commitment(reminderId: "r", done: true), reminderCompleted: true), .none)
        XCTAssertEqual(CommitmentSync.action(for: commitment(reminderId: "r", done: true), reminderCompleted: false), .report(done: false))
        XCTAssertEqual(CommitmentSync.action(for: commitment(reminderId: "r"), reminderCompleted: false), .none)
        // Un-accepted or scored: an open reminder goes, a finished one stays.
        XCTAssertEqual(CommitmentSync.action(for: commitment(active: false, reminderId: "r"), reminderCompleted: false), .remove)
        XCTAssertEqual(CommitmentSync.action(for: commitment(active: false, reminderId: "r"), reminderCompleted: true), .report(done: true))
        XCTAssertEqual(CommitmentSync.action(for: commitment(active: false, reminderId: "r", done: true), reminderCompleted: true), .none)
    }

    func testCommitmentNotesAndReport() throws {
        var commitment = Commitment(week: "2026-11-23", id: "c2", text: "Protein", measure: "Macrovana: 6 Complete days",
                                    active: true, reminderId: nil, done: false, due: "2026-11-29")
        XCTAssertEqual(CommitmentSync.notes(for: commitment), "How it's judged: Macrovana: 6 Complete days\nFrom your weekly review.")
        commitment.measure = nil
        XCTAssertEqual(CommitmentSync.notes(for: commitment), "From your weekly review.")
        // A removed reminder is reported without an id, which the server reads as none.
        let removed = CommitmentReports(items: [CommitmentReport(week: "2026-11-23", id: "c2", reminderId: nil, done: false)])
        let json = String(decoding: try JSONEncoder().encode(removed), as: UTF8.self)
        XCTAssertFalse(json.contains("reminderId"))
        XCTAssertTrue(json.contains("\"done\":false"))
    }

    func testOpenQuestionOnlyWhileWaiting() throws {
        let json = #"""
        {"reminderId":"r1","title":"T","status":"needs_input","unread":false,"updatedAt":"2026-11-18T12:00:00Z",
         "messages":[{"id":"m1","role":"question","text":"Old?","options":null,"createdAt":"2026-11-18T12:00:00Z"},
                     {"id":"m2","role":"user","text":"Yes","options":null,"createdAt":"2026-11-18T12:01:00Z"},
                     {"id":"m3","role":"question","text":"New?","options":["A","B"],"createdAt":"2026-11-18T12:02:00Z"}]}
        """#
        var detail = try JSONCoding.decoder.decode(ThreadDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.openQuestion?.id, "m3")
        XCTAssertEqual(detail.openQuestion?.options, ["A", "B"])
        detail.status = .working
        XCTAssertNil(detail.openQuestion)
    }

    func testThreadPathEncodesReminderIdentifiers() {
        XCTAssertEqual(APIPath.thread("ABC-123"), "/api/threads/ABC-123")
        XCTAssertEqual(APIPath.thread("x-apple-reminderkit://REMCDReminder/A B", "/messages"),
                       "/api/threads/x-apple-reminderkit%3A%2F%2FREMCDReminder%2FA%20B/messages")
    }

    func testPlaceNameIsTheTownOrElseTheCountry() {
        XCTAssertEqual(PlaceFinder.placeName(city: "East Hampton, NY", region: "United States"), "East Hampton, NY")
        XCTAssertEqual(PlaceFinder.placeName(city: " ", region: "Iceland"), "Iceland")
        XCTAssertNil(PlaceFinder.placeName(city: nil, region: nil))
    }

    func testSnapshotCarriesThePlaceOnlyWhenKnown() throws {
        var snapshot = ReminderSnapshot(title: "T", notes: "", list: "", due: "", priority: "none", completed: false, timeZone: "UTC", now: "")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("location"))
        snapshot.location = "New York, NY"
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("\"location\":\"New York, NY\""))
    }
}
