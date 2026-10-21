import SwiftUI

/// A one-shot countdown using the caller's monotonic deadline, including time spent before presentation.
struct DeadlineCountdown: View {
    let deadline: ContinuousClock.Instant
    let duration: Duration

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = max(0, ContinuousClock.now.duration(to: deadline) / .seconds(1))
            let seconds = Int(remaining.rounded(.up))
            let fraction = min(1, remaining / max(1, duration / .seconds(1)))
            let label: LocalizedStringKey = seconds == 0 ? "Request expired" : "seconds left"

            HStack(spacing: 8) {
                CountdownRing(fraction: fraction, seconds: seconds, size: 28, digits: 0.4, lively: false)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(seconds <= 5 ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Approval request"))
            .accessibilityValue(seconds == 0 ? Text("Expired") : Text("\(seconds) seconds remaining"))
        }
    }
}
