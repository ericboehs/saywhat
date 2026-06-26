import Foundation
import Testing
@testable import SayWhatCore

@Suite("withTimeout")
struct TimeoutTests {
    @Test("returns the operation's value when it finishes within budget")
    func completesInTime() async throws {
        let value = try await withTimeout(.seconds(10), label: "fast") {
            42
        }
        #expect(value == 42)
    }

    @Test("throws TimeoutError when the operation outlasts the budget")
    func timesOut() async throws {
        await #expect(throws: TimeoutError(label: "slow")) {
            try await withTimeout(.milliseconds(20), label: "slow") {
                try await Task.sleep(for: .seconds(3600))
            }
        }
    }

    @Test("propagates the operation's own error rather than timing out")
    func propagatesOperationError() async throws {
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom()) {
            try await withTimeout(.seconds(10), label: "boom") {
                throw Boom()
            }
        }
    }
}
