import Foundation
import Combine
import CoreGraphics

@MainActor
final class AircraftPlaybackModel: ObservableObject {
    @Published private(set) var aircraftImage: CGImage?
    @Published private(set) var overlay: AircraftOverlaySnapshot?
    @Published private(set) var displayedAt: Date?
    @Published private(set) var sliderDate: Date?
    @Published private(set) var rangeStart: Date? =
        Date().addingTimeInterval(-86400)
    @Published private(set) var rangeEnd: Date? = Date()
    @Published private(set) var dragging = false
    @Published private(set) var playing = false
    @Published private(set) var intervalText: String?

    private var records: [AircraftRecord] = []
    private var gestureRecords: [AircraftRecord] = []
    private var rangeLocked = false
    private var gestureStart: Date?
    private var playbackTask: Task<Void, Never>?
    private var generation = UUID()
    private var refreshGeneration = UUID()
    private var followAfter = Date.distantPast
    private var restored = false
    private var refreshingHistory = false
    private var refreshAgain = false
    private var transitionImage: CGImage?

    // Updated by window notifications and sleep/wake events.
    // No observations are skipped while presentation is suspended.
    var presentationActive = true

    private func hour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "H"
        return formatter.string(from: date)
    }

    @discardableResult
    private func publish(
        _ frame: AircraftHistoryPresentation,
        preparedImage: CGImage? = nil
    ) -> Bool {
        guard !frame.selectedIDs.isEmpty,
              let prepared = preparedImage ?? AircraftFrameRenderer.image(for: frame) else {
            return false
        }
        // All icons and labels have been rendered before this single commit.
        // MainActor serialization prevents a gesture from interleaving here.
        aircraftImage = prepared
        transitionImage = nil
        overlay = frame.overlay
        displayedAt = frame.fetchedAt
        sliderDate = frame.fetchedAt
        return true
    }

    // Called after acquisition, and periodically to read shared widget history.
    // Reading history never sends a network request.
    func refreshHistory() async {
        guard !dragging, !playing else { return }
        if refreshingHistory {
            refreshAgain = true
            return
        }
        refreshingHistory = true
        defer { refreshingHistory = false }
        repeat {
            refreshAgain = false
            await loadHistory()
        } while refreshAgain && !Task.isCancelled && !dragging && !playing
    }

    private func loadHistory() async {
        guard !dragging, !playing else { return }
        let refreshID = UUID()
        refreshGeneration = refreshID
        let now = Date()
        let recent = await AircraftHistoryStore.shared.records(
            since: now.addingTimeInterval(-86400), through: now)
        guard refreshGeneration == refreshID, !dragging, !playing else { return }
        records = recent

        if !rangeLocked {
            updateRange(using: recent, now: now)
        }

        if !restored {
            let operation = generation
            var latest = recent.last { !$0.visible(at: $0.fetchedAt).isEmpty }
            if latest == nil { latest = await AircraftHistoryStore.shared.latestNonempty() }
            guard refreshGeneration == refreshID,
                  operation == generation,
                  !dragging, !playing else { return }

            if let latest {
                let frame = await AircraftHistoryStore.shared.presentation(
                    for: latest)
                guard refreshGeneration == refreshID,
                      operation == generation,
                      !dragging, !playing else { return }
                publish(frame)
            }
            restored = true
            return
        }

        guard !(await AircraftSettingsIO.shared.paused()),
              !dragging, !playing,
              let latest = recent.last(where: {
                  $0.fetchedAt > followAfter
                      && $0.fetchedAt > (displayedAt ?? .distantPast)
                      && !$0.visible(at: $0.fetchedAt).isEmpty
              }) else { return }

        let operation = generation
        let frame = await AircraftHistoryStore.shared.presentation(for: latest)
        let paused = await AircraftSettingsIO.shared.paused()
        guard refreshGeneration == refreshID,
              operation == generation,
              !paused, !dragging, !playing else { return }
        guard !frame.selectedIDs.isEmpty,
              publish(frame) else { return }
        rangeLocked = false
        updateRange(using: recent, now: now)
    }

    private func updateRange(
        using recent: [AircraftRecord], now: Date
    ) {
        let start: Date
        let end: Date
        if let first = recent.first,
           let last = recent.last,
           first.fetchedAt < last.fetchedAt {
            start = first.fetchedAt
            end = last.fetchedAt
        } else {
            // Keep the empty ruler stable between minute boundaries.
            end = ShanghaiTime.calendar.dateInterval(of: .minute, for: now)?.start
                ?? now
            start = end.addingTimeInterval(-86400)
        }
        if rangeStart != start { rangeStart = start }
        if rangeEnd != end { rangeEnd = end }
    }

    // A default 24-hour range remains draggable without aircraft history.
    @discardableResult
    func beginDragging() -> Bool {
        guard let start = rangeStart,
              let end = rangeEnd,
              start < end else { return false }
        let available = records.filter {
            $0.fetchedAt >= start && $0.fetchedAt <= end
        }
        playbackTask?.cancel()
        playbackTask = nil
        generation = UUID()
        playing = false
        dragging = true
        restored = true
        intervalText = nil

        gestureRecords = available
        gestureStart = displayedAt ?? sliderDate ?? end

        restoreTransitionImage()

        // Keep exactly the endpoints visible when the gesture began.
        rangeLocked = true
        return true
    }

    func moveSlider(to date: Date) {
        guard dragging, let start = rangeStart, let end = rangeEnd else {
            return
        }
        let target = min(end, max(start, date))
        if sliderDate != target { sliderDate = target }
    }

    // The gesture recognizer decides positioning versus interval selection.
    // Mouse speed never changes playback pacing.
    func finishDragging(positionOnly: Bool) {
        guard dragging, let target = sliderDate else { return }
        dragging = false
        let source = gestureRecords
        let start = gestureStart ?? target
        let operation = generation

        if positionOnly {
            // Block live commits until asynchronous positioning completes.
            playing = true
            playbackTask = Task { [weak self] in
                guard let self else { return }
                for record in source.reversed()
                where record.fetchedAt <= target {
                    if Task.isCancelled || self.generation != operation {
                        return
                    }
                    let frame = await AircraftHistoryStore.shared.presentation(
                        for: record)
                    guard !Task.isCancelled,
                          self.generation == operation else { return }
                    if !frame.selectedIDs.isEmpty,
                       self.publish(frame) {
                        break
                    }
                }
                guard self.generation == operation else { return }
                self.finishOperation()
            }
            return
        }

        let low = min(start, target)
        let high = max(start, target)
        var sequence = source.filter {
            $0.fetchedAt >= low && $0.fetchedAt <= high
        }
        if target < start { sequence.reverse() }

        playing = true
        intervalText = hour(start) + " → " + hour(target)
        playbackTask = Task { [weak self] in
            guard let self else { return }
            var hasPublishedFrame = false
            for record in sequence {
                guard !Task.isCancelled,
                      self.generation == operation else { return }

                let frame = await AircraftHistoryStore.shared.presentation(
                    for: record)
                guard !Task.isCancelled,
                      self.generation == operation else { return }
                guard !frame.selectedIDs.isEmpty,
                      let prepared = AircraftFrameRenderer.image(for: frame) else {
                    continue
                }

                guard await self.waitUntilVisible(operation: operation) else {
                    return
                }
                if hasPublishedFrame {
                    // Prepare the next frame before clearing only the aircraft layer.
                    self.transitionImage = self.aircraftImage
                    self.aircraftImage = nil
                    guard await self.holdFrame(
                        for: 0.5, operation: operation) else { return }
                }
                guard self.publish(frame, preparedImage: prepared) else { continue }
                hasPublishedFrame = true

                // Five seconds of active viewing for each nonempty frame.
                // Slow preparation extends playback rather than skipping frames.
                guard await self.holdFrame(
                    for: 5, operation: operation) else { return }
            }
            guard !Task.isCancelled,
                  self.generation == operation else { return }
            self.finishOperation()
        }
    }

    private func waitUntilVisible(operation: UUID) async -> Bool {
        while !presentationActive {
            guard !Task.isCancelled, generation == operation else {
                return false
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return false }
        }
        return !Task.isCancelled && generation == operation
    }

    private func holdFrame(
        for duration: TimeInterval, operation: UUID
    ) async -> Bool {
        var remaining = duration
        while remaining > 0 {
            guard await waitUntilVisible(operation: operation) else {
                return false
            }
            let before = ProcessInfo.processInfo.systemUptime
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return false }
            guard !Task.isCancelled, generation == operation else {
                return false
            }
            if presentationActive {
                // Cap elapsed time so a sleep/wake gap cannot consume a frame.
                let elapsed = ProcessInfo.processInfo.systemUptime - before
                remaining -= min(0.05, max(0, elapsed))
            }
        }
        return true
    }

    private func restoreTransitionImage() {
        if let transitionImage {
            aircraftImage = transitionImage
            self.transitionImage = nil
        }
    }

    private func finishOperation() {
        restoreTransitionImage()
        playing = false
        intervalText = nil
        if let displayedAt, let start = rangeStart, let end = rangeEnd {
            sliderDate = min(end, max(start, displayedAt))
        } else if let displayedAt {
            sliderDate = displayedAt
        }
        playbackTask = nil

        // Only a successful observation acquired AFTER completion may replace
        // the final historical frame. Empty responses never clear the map.
        followAfter = Date()
    }

    // Used when the owning view is removed; retain its last complete frame.
    func stop() {
        restoreTransitionImage()
        playbackTask?.cancel()
        playbackTask = nil
        generation = UUID()
        dragging = false
        playing = false
        intervalText = nil
        if let displayedAt {
            sliderDate = displayedAt
        }
        followAfter = Date()
    }
}
