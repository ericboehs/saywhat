import SwiftUI

/// A horizontal input-level meter driven by a `0...1` level, green→red as it
/// approaches clipping.
struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level < 0.85 ? Color.green : Color.red)
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(min(max(level, 0), 1) * 100)) percent")
    }
}

/// One track's label, meter, and frame/sample counters.
struct TrackRow: View {
    var title: String
    var level: Float
    var frames: Int
    var samples: Int
    var active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            LevelMeter(level: level)
                .opacity(active ? 1 : 0.35)
            Text("\(frames) frames · \(samples) samples")
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
