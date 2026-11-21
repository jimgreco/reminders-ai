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
