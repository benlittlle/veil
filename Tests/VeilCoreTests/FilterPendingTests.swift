import Foundation
import Testing
@testable import VeilCore

/// The model judges about one message a second, so right after launch most messages aren't judged
/// yet. The user's review must say "not checked yet" for those, not "couldn't be checked", and the
/// background pass must reach the newest message in every chat before older ones.
@Suite("Content filter: not checked yet")
struct FilterPendingTests {
    @Test func modelStillWorkingIsPendingNotFailed() throws {
        let f = try FilterHarness()
        f.fake.behavior = .hang
        let byID = Dictionary(uniqueKeysWithValues: try f.gate.filterReview(chatID: ID.alex, timeout: 0.3).map { ($0.id, $0) })
        let ordinary = try #require(byID[f.ids["ordinary"]!])
        #expect(ordinary.pending && ordinary.withheld && ordinary.notCleared)
        // The assistant still gets [withheld]: pending is never visible to it.
        f.gate.filter.onDemandTimeout = 0.3
        #expect(f.text(of: "ordinary") == FilterOutcome.withheldMarker)
        #expect(!f.call("read_chat", ["chat_id": .string(ID.alex), "limit": 200]).text.contains("pending"))
    }

    @Test func failuresAndUnsureAreNotPending() throws {
        for b in [FakeClassifier.Behavior.error, .refuse, .dropAnswers, .unavailable, .unsure] {
            let f = try FilterHarness()
            f.fake.behavior = b
            let byID = Dictionary(uniqueKeysWithValues: try f.gate.filterReview(chatID: ID.alex, timeout: 2).map { ($0.id, $0) })
            let o = try #require(byID[f.ids["ordinary"]!], "\(b)")
            #expect(o.notCleared && !o.pending, "\(b)")
        }
    }

    @Test func aLaterAnswerClearsAPendingMessage() throws {
        let f = try FilterHarness()
        f.fake.behavior = .held
        let first = Dictionary(uniqueKeysWithValues: try f.gate.filterReview(chatID: ID.alex, timeout: 0.3).map { ($0.id, $0) })
        #expect(first[f.ids["ordinary"]!]?.pending == true)
        f.fake.release()
        let later = Dictionary(uniqueKeysWithValues: try f.gate.filterReview(chatID: ID.alex, timeout: 5).map { ($0.id, $0) })
        #expect(later[f.ids["ordinary"]!] == nil)                       // cleared, so not in the review
        #expect(later[f.ids["politics"]!]?.reasons == [.politics])      // judged: a real decision, not pending
        #expect(later[f.ids["politics"]!]?.pending == false)
    }

    @Test func aFailureIsForgottenOnceTheModelAnswers() throws {
        let f = try FilterHarness()
        f.fake.behavior = .error
        _ = try f.gate.filterReview(chatID: ID.alex, timeout: 2)
        f.fake.behavior = .hang
        // It failed last time, so it isn't shown as merely waiting.
        let again = Dictionary(uniqueKeysWithValues: try f.gate.filterReview(chatID: ID.alex, timeout: 0.3).map { ($0.id, $0) })
        #expect(again[f.ids["ordinary"]!]?.pending == false)
        f.fake.behavior = .normal
        #expect(try f.gate.filterReview(chatID: ID.alex, timeout: 5).allSatisfy { !$0.notCleared || $0.id == f.ids["unsure"]! })
    }

    @Test func backgroundPassReachesEveryChatsNewestMessageFirst() throws {
        let access = Harness.defaultAccess.merging([
            ID.alex: ChatAccess(read: true, waiting: true, draft: true, filtered: true),
            ID.mom: ChatAccess(read: true, waiting: true, draft: true, filtered: true),
        ]) { $1 }
        let f = try FilterHarness(access: access)
        f.gate.warmFilterCache(newestFirst: 1)
        let calls = f.fake.calls
        // One message from each chat, then the deeper pass.
        #expect(calls.count > 2)
        #expect(calls.prefix(2).map(\.count) == [1, 1])
        #expect(calls[0].first?.text != calls[1].first?.text)
        #expect(calls.prefix(2).flatMap { $0 }.contains { $0.text.contains("biopsy") })   // Alex's newest
        // The second round doesn't ask about those two again.
        let firstTwo = Set(calls.prefix(2).flatMap { $0 }.map(\.text))
        #expect(calls.dropFirst(2).flatMap { $0 }.allSatisfy { !firstTwo.contains($0.text) })
    }
}
