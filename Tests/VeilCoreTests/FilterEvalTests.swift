import Foundation
import Testing
@testable import VeilCore

/// Opt-in evaluation of the real on-device model over synthetic, labelled messages.
/// Not part of the default run. To run it (needs Apple Intelligence turned on):
///
///     VEIL_EVAL=1 swift test --filter FilterEval
///     VEIL_EVAL=1 VEIL_EVAL_ENGINE=contentTagging swift test --filter FilterEval
///     VEIL_EVAL=1 VEIL_EVAL_BATCH=1 swift test --filter FilterEval    (messages per model call)
///     VEIL_EVAL_DEBUG=1 also prints each verdict and any engine errors.
///
/// Prints precision and recall per category at each strictness, so engines can be compared.
/// Every message below is made up for this test; no real data is involved.
@Suite("Content filter: model eval (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["VEIL_EVAL"] == "1"))
struct FilterEval {
    /// (text, categories it should be withheld for)
    static let samples: [(String, Set<FilterCategory>)] = [
        // politics
        ("Honestly the prime minister is a liar and anyone who votes for that party is an idiot", [.politics, .conflict]),
        ("Are you voting in the election on Thursday? I'm going Green this time", [.politics]),
        ("That senator's immigration bill is cruel, I'm so angry about it", [.politics]),
        ("The new tax policy from the government is going to wreck small businesses", [.politics]),
        ("Can't believe they rigged the vote count, democracy is dead", [.politics]),
        ("Did you see the debate last night? The candidate totally lost it on healthcare", [.politics]),
        // health
        ("The biopsy came back and they want to start chemo next month", [.health]),
        ("My therapist upped my antidepressant dose, feeling a bit flat", [.health]),
        ("Can you pick up my insulin prescription from the pharmacy?", [.health]),
        ("I've been having panic attacks every night this week", [.health]),
        ("The scan showed a small lump, waiting on the consultant", [.health]),
        ("We're 10 weeks pregnant! Don't tell anyone yet", [.health]),
        // sexual
        ("Last night was amazing, I can't stop thinking about you naked in bed", [.sexual]),
        ("Send me a sexy pic before you go to sleep 😉", [.sexual]),
        ("I want to rip your clothes off the second you walk in", [.sexual]),
        ("We should try that thing from the video in the bedroom tonight", [.sexual]),
        // conflict
        ("You're a selfish pathetic excuse for a brother and I'm done with you", [.conflict]),
        ("Don't you dare speak to me like that again, you absolute idiot", [.conflict]),
        ("I can't believe you lied to me AGAIN. We are finished.", [.conflict]),
        ("If you touch my car one more time I swear I'll make you regret it", [.conflict]),
        ("Stop ignoring me, you're being so childish and spiteful", [.conflict]),
        // money worries
        ("I'm £2000 overdrawn and rent is due Friday, I don't know what to do", [.moneyWorries]),
        ("The bailiffs sent another letter, I can't keep up with the debt", [.moneyWorries]),
        ("Can you lend me £50 until payday? I literally can't afford food this week", [.moneyWorries]),
        ("My credit card got declined again, I'm so stressed about money", [.moneyWorries]),
        ("We might lose the house if I can't make the mortgage payment", [.moneyWorries]),
        // none
        ("Are you coming for dinner Sunday?", []),
        ("Climbing Thursday? Can you book the 7pm slot?", []),
        ("The package arrived, it's on the doorstep", []),
        ("Happy birthday!! Hope you have the best day 🎉", []),
        ("Running 10 minutes late, start without me", []),
        ("What time is the film? I'll grab popcorn", []),
        ("Can you send me the photos from the hike?", []),
        ("Traffic is awful on the M25, taking the back roads", []),
        ("Don't forget to water the plants while I'm away", []),
        ("Nice one, see you at the gym tomorrow", []),
        ("The new route at the wall is a proper V5", []),
        ("Mum says hi and wants to know if you got her email", []),
    ]

    @Test func precisionAndRecall() throws {
        let mode = AppleOnDeviceClassifier.Mode(rawValue: ProcessInfo.processInfo.environment["VEIL_EVAL_ENGINE"] ?? "general") ?? .general
        let engine = AppleOnDeviceClassifier(mode: mode)
        print("Engine: \(engine.engineID), on-device: \(engine.isOnDevice), status: \(engine.status)")
        guard engine.status.isAvailable else {
            print("Skipping: \(engine.status)")
            return
        }
        if ProcessInfo.processInfo.environment["VEIL_EVAL_DEBUG"] == "1" {
            for (i, s) in Self.samples.enumerated() {
                let done = DispatchSemaphore(value: 0)
                engine.classify([ClassifierItem(id: Int64(i), text: s.0)]) { r in
                    if case .failure(let e) = r { print("#\(i) failed: \(String(describing: e).prefix(160))") }
                    done.signal()
                }
                done.wait()
            }
        }
        let filter = ContentFilter(classifier: engine)
        if let b = ProcessInfo.processInfo.environment["VEIL_EVAL_BATCH"].flatMap(Int.init) { filter.batchSize = max(1, b) }
        print("Batch size: \(filter.batchSize)")
        let items = Self.samples.enumerated().map { ContentFilter.Item(id: Int64($0.offset + 1), text: $0.element.0) }
        let start = Date()
        let verdicts = filter.classify(items, timeout: 600)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "Classified %d of %d messages in %.1fs (%.2fs per message)", verdicts.count, items.count, elapsed, elapsed / Double(max(items.count, 1))))
        if ProcessInfo.processInfo.environment["VEIL_EVAL_DEBUG"] == "1" {
            for (i, s) in Self.samples.enumerated() {
                let v = verdicts[Int64(i + 1)]
                let levels = FilterCategory.modelCategories.map { "\($0.rawValue.prefix(4))=\(v?.level($0).rawValue ?? "-")" }.joined(separator: " ")
                print("#\(i) [\(s.1.map(\.rawValue).sorted().joined(separator: ","))] \(levels) | \(s.0.prefix(50))")
            }
        }
        let missing = items.filter { verdicts[$0.id] == nil }.count
        print("No answer (would be withheld): \(missing)")

        for strictness in FilterStrictness.allCases {
            print("\n== \(strictness.title)")
            print("category        precision  recall   tp  fp  fn")
            for c in FilterCategory.modelCategories {
                var tp = 0, fp = 0, fn = 0
                for (i, (_, labels)) in Self.samples.enumerated() {
                    // Missing or unsure answers withhold, so they count as "flagged".
                    let level = verdicts[Int64(i + 1)]?.level(c) ?? .unsure
                    let flagged = level == .unsure || level.rank >= strictness.threshold.rank
                    let truth = labels.contains(c)
                    if flagged && truth { tp += 1 } else if flagged && !truth { fp += 1 } else if !flagged && truth { fn += 1 }
                }
                let p = tp + fp == 0 ? 1 : Double(tp) / Double(tp + fp)
                let r = tp + fn == 0 ? 1 : Double(tp) / Double(tp + fn)
                print(c.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0) + String(format: " %9.2f %7.2f  %3d %3d %3d", p, r, tp, fp, fn))
            }
            let clean = Self.samples.enumerated().filter { $0.element.1.isEmpty }
            let wrongly = clean.filter { i, _ in
                let v = verdicts[Int64(i + 1)]
                return FilterCategory.modelCategories.contains { c in
                    let l = v?.level(c) ?? .unsure
                    return l == .unsure || l.rank >= strictness.threshold.rank
                }
            }.count
            print("Ordinary messages withheld: \(wrongly) of \(clean.count)")
        }
    }
}
