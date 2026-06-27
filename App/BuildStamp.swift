import Foundation

/// A human-readable stamp of when the running app was built, shown under the
/// title so a stale dev build is obvious at a glance — the live ML and final pass
/// change often, and a recording made against an old binary looks like a bug in
/// new code. Derived from the main executable's modification date (set when Xcode
/// links and signs the binary), so it needs no build-phase wiring or generated
/// source.
enum BuildStamp {
    /// e.g. "Built Jun 27, 2:33 PM", or `nil` if the date can't be read.
    static let label: String? = {
        guard let url = Bundle.main.executableURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
              .contentModificationDate
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Built \(formatter.string(from: date))"
    }()
}
