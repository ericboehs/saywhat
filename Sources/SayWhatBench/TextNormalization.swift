import Foundation

/// Folds transcript text to the canonical token stream WER is measured over, so two
/// recognizers aren't penalized for cosmetic disagreements (casing, punctuation,
/// spacing) that a reader wouldn't count as errors.
///
/// The rules are deliberately conservative and ASR-neutral: lowercase, drop
/// punctuation, collapse whitespace. We do **not** expand contractions or spell out
/// numbers — those are opinions a fair WER shouldn't bake in, and they'd flatter one
/// engine's formatting style over another's.
enum TextNormalization {
    /// `text` split into comparable lowercase word tokens, punctuation removed.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
