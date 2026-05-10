import SwiftUI

struct MicLevelMeter: View {
    let monitor: MicLevelMonitor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.5))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(2, geo.size.width * CGFloat(monitor.level)))
                    .animation(.easeOut(duration: 0.08), value: monitor.level)
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(monitor.level * 100)) percent")
    }
}
