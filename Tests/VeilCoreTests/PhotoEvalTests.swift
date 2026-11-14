import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VeilCore

/// Opt-in evaluation of photo checking with the real on-device engines (Apple's model looking at
/// the image, Vision text recognition, and the text model on what it reads). Not part of the
/// default run. To run it (needs Apple Intelligence turned on, macOS 27):
///
///     VEIL_EVAL=1 swift test --filter PhotoEval
///     VEIL_EVAL_DEBUG=1 also prints every verdict.
///     VEIL_EVAL_DUMP=/some/dir also writes the synthetic images there, to look at.
///     VEIL_EVAL_PHOTOS=n uses at most n ordinary photos (default 70).
///
/// Sensitive images are drawn with CoreGraphics (test card numbers, invented names). Ordinary
/// photos are the pictures that ship with macOS. Nothing explicit is generated or used: the
/// nudity path is covered by the unit tests with a fake model that refuses.
@Suite("Photo check: eval (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["VEIL_EVAL"] == "1"))
struct PhotoEval {
    struct Row { let name: String; let group: String; let expect: Set<FilterCategory>; let verdict: PhotoVerdict?; let seconds: Double }

    @Test func recallFalseWithholdsAndLatency() throws {
        let env = ProcessInfo.processInfo.environment
        let debug = env["VEIL_EVAL_DEBUG"] == "1"
        let text = AppleOnDeviceClassifier()
        let filter = ContentFilter(classifier: text)
        let checker = PhotoChecker(classifier: AppleOnDeviceImageClassifier(), recognizer: VisionTextRecognizer(),
                                   nudity: SensitiveContentDetector(), textFilter: filter)
        print("Image engine: \(checker.classifier!.engineID), status: \(checker.status)")
        print("Text engine: \(text.engineID), status: \(text.status)")
        print("SensitiveContentAnalysis enabled: \(checker.nudity!.isEnabled)")
        guard checker.status.isAvailable else { print("Skipping: \(checker.status)"); return }

        var inputs: [(String, String, Set<FilterCategory>, Data)] = []
        let dump = env["VEIL_EVAL_DUMP"].map { URL(fileURLWithPath: $0) }
        if let dump { try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
        for (i, s) in PhotoFixtures.sensitive.enumerated() {
            // Mix formats the way Messages does: JPEG photos, PNG screenshots, the odd HEIC.
            let type: UTType = s.name.contains("screenshot") ? .png : (i % 4 == 0 ? .heic : .jpeg)
            let data = PhotoFixtures.encode(s.image, as: type)
            if let dump { try data.write(to: dump.appendingPathComponent("\(s.name).\(type.preferredFilenameExtension ?? "img")")) }
            inputs.append((s.name, "sensitive", s.expect, data))
        }
        for s in PhotoFixtures.harmlessText {
            let data = PhotoFixtures.encode(s.image, as: .png)
            if let dump { try data.write(to: dump.appendingPathComponent("\(s.name).png")) }
            inputs.append((s.name, "harmless text", [], data))
        }
        // VEIL_EVAL_PHOTOS=n limits the ordinary photos (0 for a quick prompt check).
        for (name, url) in PhotoFixtures.systemPhotos(limit: env["VEIL_EVAL_PHOTOS"].flatMap(Int.init) ?? 70) {
            inputs.append((name, "ordinary photo", [], try Data(contentsOf: url)))
        }

        var rows: [Row] = []
        for (n, (name, group, expect, data)) in inputs.enumerated() {
            let start = Date()
            let result = checker.analyze(PhotoChecker.Request(id: Int64(n + 1), url: URL(fileURLWithPath: "/dev/null"), data: data))
            let row = Row(name: name, group: group, expect: expect, verdict: result?.1, seconds: Date().timeIntervalSince(start))
            rows.append(row)
            if debug { print(describe(row)) }
        }

        let times = rows.map(\.seconds).sorted()
        func pct(_ p: Double) -> Double { times[min(times.count - 1, Int(Double(times.count - 1) * p))] }
        print(String(format: "\nPhotos: %d. Latency per photo: median %.2fs, p95 %.2fs, max %.2fs", rows.count, pct(0.5), pct(0.95), times.last ?? 0))
        print("No verdict (error or timeout, would be withheld): \(rows.filter { $0.verdict == nil }.count)")
        print("Refused by the model: \(rows.filter { $0.verdict?.problem == .refused }.count)")

        for strictness in FilterStrictness.allCases {
            var p = FilterPolicy.standard
            p.strictness = strictness
            func outcome(_ r: Row) -> PhotoOutcome { PhotoChecker.decide(r.verdict, policy: p, isPhoto: true) }
            print("\n== \(strictness.title) (standard settings otherwise)")
            print("category              recall   right-reason  n")
            let cats = Set(rows.flatMap(\.expect)).sorted()
            for c in cats {
                let mine = rows.filter { $0.expect.contains(c) }
                let withheld = mine.filter { outcome($0).withheld }.count
                let right = mine.filter { outcome($0).reasons.contains(c) }.count
                print(c.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)
                      + String(format: " %6.2f  %10.2f  %3d", Double(withheld) / Double(mine.count), Double(right) / Double(mine.count), mine.count))
            }
            let sensitive = rows.filter { !$0.expect.isEmpty }
            print("Sensitive images withheld: \(sensitive.filter { outcome($0).withheld }.count) of \(sensitive.count)")
            for g in ["harmless text", "ordinary photo"] {
                let clean = rows.filter { $0.group == g }
            guard !clean.isEmpty else { continue }
                let wrong = clean.filter { outcome($0).withheld }
                print("False withholds, \(g): \(wrong.count) of \(clean.count)"
                      + (wrong.isEmpty ? "" : "  [" + wrong.map { "\($0.name): \(why(outcome($0)))" }.joined(separator: "; ") + "]"))
            }
            let missed = sensitive.filter { !outcome($0).withheld }
            if !missed.isEmpty { print("Missed: " + missed.map(\.name).joined(separator: ", ")) }
        }
    }

    func why(_ o: PhotoOutcome) -> String {
        (o.reasons.sorted().map(\.rawValue) + (o.notCleared ? ["not cleared"] : [])).joined(separator: ",")
    }

    func describe(_ r: Row) -> String {
        guard let v = r.verdict else { return String(format: "%-34@ %5.2fs  NO VERDICT", r.name as NSString, r.seconds) }
        let seen = (FilterCategory.photoCategories + FilterCategory.modelCategories)
            .map { "\($0.rawValue.prefix(5))=\(v.seen.levels[$0]?.rawValue ?? "-")" }.joined(separator: " ")
        let text = v.textVerdict.map { tv in FilterCategory.modelCategories.filter { tv.level($0) != ConcernLevel.none }.map { "\($0.rawValue)=\(tv.level($0).rawValue)" }.joined(separator: ",") } ?? "-"
        return String(format: "%-34@ %5.2fs ", r.name as NSString, r.seconds)
            + "\(v.problem.map { "PROBLEM=\($0.rawValue) " } ?? "")seen[\(seen)] ocr[\(v.textFound.sorted().map(\.rawValue).joined(separator: ","))] text[\(text)] sca=\(v.flaggedSensitive)"
    }
}
