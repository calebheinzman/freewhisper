import SwiftUI

/// Twin level meters shown while recording.
///
/// This is the app's honesty indicator. Background recording that might silently
/// be capturing nothing is the failure mode users fear most, so both channels
/// get a visible, independently-moving bar and a dead channel is called out in
/// words rather than just sitting at zero.
struct LevelMeters: View {
    let micLevel: Float
    let systemLevel: Float
    let micActive: Bool
    let systemActive: Bool

    var body: some View {
        VStack(spacing: 5) {
            MeterRow(label: "You", level: micLevel, active: micActive, tint: .blue)
            MeterRow(label: "Them", level: systemLevel, active: systemActive, tint: .purple)
        }
    }
}

private struct MeterRow: View {
    let label: String
    let level: Float
    let active: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(active ? tint : Color.clear)
                        .frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
                        // Fast attack, slow release: matches how a hardware
                        // meter behaves and stops the bar looking jittery.
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(height: 5)

            if !active {
                Text("off")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .frame(width: 20, alignment: .trailing)
            } else {
                Spacer().frame(width: 20)
            }
        }
    }
}
