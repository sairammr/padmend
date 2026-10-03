import Foundation

/// A deliberately tiny test harness.
///
/// This machine has Command Line Tools without Xcode, which ships neither
/// XCTest nor swift-testing. Rather than add a package dependency for the sake
/// of assertions, the suite runs as a plain executable: `swift run padmend-tests`.
/// Everything it needs is a counter, a comparison, and an exit code.
enum Check {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var currentTest = "<none>"
    nonisolated(unsafe) static var currentSuite = "<none>"

    static func fail(_ message: String, _ file: StaticString, _ line: UInt) {
        let where_ = "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
        failures.append("\(currentSuite) › \(currentTest)\n      \(message)\n      at \(where_)")
    }
}

func suite(_ name: String, _ body: () throws -> Void) {
    Check.currentSuite = name
    print("\n\u{1B}[1m\(name)\u{1B}[0m")
    do {
        try body()
    } catch {
        Check.currentTest = "<suite body>"
        Check.fail("suite threw: \(error)", #filePath, #line)
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    Check.currentTest = name
    let before = Check.failures.count
    do {
        try body()
    } catch {
        Check.fail("threw: \(error)", #filePath, #line)
    }
    if Check.failures.count == before {
        Check.passed += 1
        print("  \u{1B}[32m✓\u{1B}[0m \(name)")
    } else {
        print("  \u{1B}[31m✗\u{1B}[0m \(name)")
    }
}

func expect(_ condition: Bool,
            _ detail: @autoclosure () -> String = "",
            file: StaticString = #filePath,
            line: UInt = #line) {
    guard !condition else { return }
    let note = detail()
    Check.fail(note.isEmpty ? "expectation failed" : note, file, line)
}

func expectEq<T: Equatable>(_ actual: T,
                            _ expected: T,
                            _ detail: @autoclosure () -> String = "",
                            file: StaticString = #filePath,
                            line: UInt = #line) {
    guard actual != expected else { return }
    var message = "expected \(expected), got \(actual)"
    let note = detail()
    if !note.isEmpty { message += " — \(note)" }
    Check.fail(message, file, line)
}

func expectClose(_ actual: Double,
                 _ expected: Double,
                 _ tolerance: Double = 1e-9,
                 _ detail: @autoclosure () -> String = "",
                 file: StaticString = #filePath,
                 line: UInt = #line) {
    guard abs(actual - expected) > tolerance else { return }
    var message = "expected \(expected) ± \(tolerance), got \(actual)"
    let note = detail()
    if !note.isEmpty { message += " — \(note)" }
    Check.fail(message, file, line)
}

/// Prints the tally and returns a process exit code.
func report() -> Int32 {
    print("")
    if Check.failures.isEmpty {
        print("\u{1B}[32m\(Check.passed) passed\u{1B}[0m")
        return 0
    }
    print("\u{1B}[31m\(Check.failures.count) failed\u{1B}[0m, \(Check.passed) passed\n")
    for failure in Check.failures {
        print("  \u{1B}[31m✗\u{1B}[0m \(failure)")
    }
    return 1
}
