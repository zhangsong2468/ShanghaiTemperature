import SwiftUI

struct AircraftHistoryRuler: View {
    @ObservedObject var model: AircraftPlaybackModel

    @State private var gestureActive = false
    @State private var intervalSelection = false
    @State private var lastX: CGFloat = 0
    @State private var lastTime: TimeInterval = 0
    @State private var slowDuration: TimeInterval = 0
    @State private var moved = false
    @State private var pauseTask: Task<Void, Never>?
    @State private var movementGeneration = UUID()

    private let inset: CGFloat = 7

    private func text(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func fraction(
        _ date: Date, start: Date, end: Date
    ) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - inset * 2)

            if let start = model.rangeStart,
               let end = model.rangeEnd,
               start < end {
                let selected = model.sliderDate ?? end
                let x = inset + width * CGFloat(
                    fraction(selected, start: start, end: end))

                ZStack(alignment: .topLeading) {
                    HStack {
                        Text(text(start, format: "MM/dd"))
                        Spacer(minLength: 4)
                        Text(text(end, format: "MM/dd"))
                    }
                    .font(.system(size: 8))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .padding(.horizontal, inset)
                    .offset(y: 11)
                    .allowsHitTesting(false)

                    Canvas { context, size in
                        let baseline: CGFloat = 30
                        let calendar = ShanghaiTime.calendar
                        guard var hour = calendar.dateInterval(
                            of: .hour, for: start)?.start else { return }

                        if hour < start {
                            hour = hour.addingTimeInterval(3600)
                        }

                        var ticks = Path()
                        while hour <= end {
                            let position = inset + width * CGFloat(
                                fraction(hour, start: start, end: end))
                            let hourNumber = calendar.component(.hour, from: hour)
                            let height: CGFloat = hourNumber % 6 == 0 ? 2 : 1
                            ticks.move(to: CGPoint(
                                x: position, y: baseline))
                            ticks.addLine(to: CGPoint(
                                x: position, y: baseline - height))
                            hour = hour.addingTimeInterval(3600)
                        }
                        context.stroke(
                            ticks,
                            with: .color(.black.opacity(0.20)),
                            lineWidth: 0.5)
                    }
                    .allowsHitTesting(false)

                    Circle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .position(x: x, y: 29)
                        .allowsHitTesting(false)

                    if model.dragging {
                        Text(text(selected, format: "H"))
                            .font(.system(size: 4))
                            .foregroundStyle(Color.black.opacity(0.55))
                            .fixedSize()
                            .position(
                                x: min(
                                    geometry.size.width - 7,
                                    max(7, x)),
                                y: 17)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(
                        minimumDistance: 0,
                        coordinateSpace: .local)
                    .onChanged { value in
                        updateGesture(
                            value, width: width,
                            start: start, end: end)
                    }
                    .onEnded { _ in
                        finishGesture()
                    }
                )
            }
        }
        .frame(height: 38)
        .onDisappear {
            pauseTask?.cancel()
            pauseTask = nil
            movementGeneration = UUID()
            if gestureActive {
                model.stop()
            }
            gestureActive = false
        }
        .accessibilityLabel("飞机历史时间尺")
    }

    private func updateGesture(
        _ value: DragGesture.Value,
        width: CGFloat,
        start: Date,
        end: Date
    ) {
        let now = ProcessInfo.processInfo.systemUptime

        if !gestureActive {
            // Grab the visible knob rather than jumping from an arbitrary
            // click elsewhere on the ruler.
            let selected = model.sliderDate ?? end
            let knobX = inset + width * CGFloat(
                fraction(selected, start: start, end: end))
            guard abs(value.startLocation.x - knobX) <= 16 else {
                return
            }
            guard model.beginDragging() else { return }

            gestureActive = true
            intervalSelection = false
            slowDuration = 0
            moved = false
            lastX = value.startLocation.x
            lastTime = now
        }

        let delta = abs(value.location.x - lastX)
        let elapsed = now - lastTime

        if delta >= 0.5 {
            moved = true
            if elapsed > 0 {
                let normalizedSpeed = Double(delta / width) / elapsed
                if normalizedSpeed < 0.2 {
                    slowDuration += min(elapsed, 0.45)
                    if slowDuration >= 0.15 {
                        intervalSelection = true
                    }
                } else {
                    slowDuration = 0
                }
            }

            lastX = value.location.x
            lastTime = now
            armPauseDetection()
        }

        let progress = min(
            1, max(0, Double((value.location.x - inset) / width)))
        let target = start.addingTimeInterval(
            end.timeIntervalSince(start) * progress)
        model.moveSlider(to: target)
    }

    private func armPauseDetection() {
        pauseTask?.cancel()
        let token = UUID()
        movementGeneration = token
        pauseTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  movementGeneration == token,
                  gestureActive, moved else { return }
            intervalSelection = true
        }
    }

    private func finishGesture() {
        guard gestureActive else { return }
        pauseTask?.cancel()
        pauseTask = nil
        movementGeneration = UUID()
        gestureActive = false
        if moved {
            model.finishDragging(positionOnly: !intervalSelection)
        } else {
            model.stop()
        }
    }
}
