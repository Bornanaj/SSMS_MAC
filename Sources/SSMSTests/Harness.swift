import Foundation

/// A very small assertion harness. XCTest ships with Xcode, and this project is
/// built with the Command Line Tools alone, so the regression suite is a plain
/// executable: `swift run ssms-tests`.
final class TestRunner {
    private var failures: [String] = []
    private var passed = 0
    private var currentSuite = ""

    func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("\n▸ \(name)")
        do {
            try body()
        } catch {
            record(false, "threw \(error)")
        }
    }

    func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        record(condition, label, detail())
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        record(actual == expected, label, actual == expected ? "" : "got \(actual), want \(expected)")
    }

    private func record(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok {
            passed += 1
            print("  ✓ \(label)")
        } else {
            let message = "\(currentSuite) / \(label)\(detail.isEmpty ? "" : " — \(detail)")"
            failures.append(message)
            print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    func finish() -> Int32 {
        print("\n\(passed) passed, \(failures.count) failed")
        for failure in failures { print("  FAILED: \(failure)") }
        return failures.isEmpty ? 0 : 1
    }
}
