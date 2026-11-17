import Foundation
import Testing
@testable import VeilCore

/// Regressions for correctness and reliability bugs a user would hit in everyday use.
@Suite("Reliability")
struct ReliabilityTests {
    // MARK: Content filter

    @Test func veryLongMessagesDontTieUpTheModel() throws {
        let f = try FilterHarness()
        // A pasted document: far more than one model batch.
        let huge = String(repeating: "Notes from the long planning call, nothing private here. ", count: 300)
        #expect(huge.count > ContentFilter.maxJudgedChars)
        // Just under the limit: still judged, in pieces.
        let near = String(repeating: "Ordinary words for a longer update. ", count: 200)
        #expect(near.count <= ContentFilter.maxJudgedChars && near.count > ContentFilter.maxModelChars)
        try f.add("huge", huge, hoursAgo: 0.2)
        try f.add("near", near, hoursAgo: 0.1)

        // Fails closed: no verdict, so withheld, without ever being sent to the model.
        #expect(f.text(of: "huge") == "[withheld]")
        #expect(f.text(of: "near") == near.trimmingCharacters(in: .whitespaces))
        #expect(!f.fake.calls.flatMap { $0 }.contains { $0.text.contains("planning call") })

        // Background passes never send it either, so the model isn't kept busy pass after pass.
        f.gate.warmFilterCache()
        let calls = f.fake.calls.count
        f.gate.warmFilterCache()
        #expect(f.fake.calls.count == calls)
        #expect(!f.fake.calls.flatMap { $0 }.contains { $0.text.contains("planning call") })

        // The user sees why in the review screen, and can let it through.
        let item = try #require(try f.gate.filterReview(chatID: ID.alex).first { $0.id == f.ids["huge"] })
        #expect(item.withheld && item.notCleared)
        try f.gate.setFilterAllowed(true, message: try #require(f.ids["huge"]), in: ID.alex)
        #expect(f.text(of: "huge") == huge.trimmingCharacters(in: .whitespaces))
    }

    @Test func veryLongMessagesPassWhenNoTopicNeedsTheModel() throws {
        let f = try FilterHarness()
        var p = FilterPolicy.standard
        for c in FilterCategory.modelCategories { p.set(c, .allow) }
        try f.gate.setChatFilterPolicy(p, for: ID.alex)
        let huge = String(repeating: "Notes from the long planning call, nothing private here. ", count: 300)
        try f.add("huge", huge, hoursAgo: 0.1)
        #expect(f.text(of: "huge") == huge.trimmingCharacters(in: .whitespaces))
        #expect(f.fake.calls.isEmpty)
    }
}
