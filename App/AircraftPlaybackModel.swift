import Foundation
import Combine
import CoreGraphics

@MainActor
final class AircraftPlaybackModel: ObservableObject {
    @Published private(set) var aircraftImage: CGImage?
    @Published private(set) var overlay: AircraftOverlaySnapshot?
    @Published private(set) var displayedAt: Date?
    @Published private(set) var sliderDate: Date?
    @Published private(set) var rangeStart: Date?
    @Published private(set) var rangeEnd: Date?
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

    // Updated by the view when its window is inactive, hidden or sleeping.
    // No observations are skipped while presentation is suspended.
    var presentationActive = true

    private func hour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "H"
        return formatter.string(from: date)
    }

    @discardableResult
    private func publish(_ frame: AircraftHistoryPresentation) -> Bool {
        guard !frame.selectedIDs.isEmpty,
              let prepared = AircraftFrameRenderer.image(for: frame) else {
            return false
        }
        // All icons and labels have been rendered before this single commit.
        // MainActor serialization prevents a gesture from interleaving here.
        aircraftImage = prepared
        overlay = frame.overlay
        displayedAt = frame.fetchedAt
        sliderDate = frame.fetchedAt
        return true
    }

    // Called after acquisition, and periodically to read shared widget history.
    // Reading history never sends a network request.
    func refreshHistory() async {
        let refreshID = UUID()
        refreshGeneration = refreshID
        let now = Date()
        let recent = await AircraftHistoryStore.shared.records(
            since: now.addingTimeInterval(-86400), through: now)
        guard refreshGeneration == refreshID else { return }
        records = recent

        if !rangeLocked {
            rangeStart = recent.first?.fetchedAt
            rangeEnd = recent.last?.fetchedAt
        }

        if !restored {
            let operation = generation
            let latest = await AircraftHistoryStore.shared.latestNonempty()
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

        guard !AircraftPauseSettings.current.paused,
              !dragging, !playing,
              let latest = recent.last(where: {
                  $0.fetchedAt > followAfter
                      && $0.fetchedAt > (displayedAt ?? .distantPast)
                      && !$0.visible(at: $0.fetchedAt).isEmpty
              }) else { return }

        let operation = generation
        let frame = await AircraftHistoryStore.shared.presentation(for: latest)
        guard refreshGeneration == refreshID,
              operation == generation,
              !AircraftPauseSettings.current.paused,
              !dragging, !playing else { return }
        guard !frame.selectedIDs.isEmpty,
              publish(frame) else { return }
        rangeLocked = false
        rangeStart = recent.first?.fetchedAt
        rangeEnd = recent.last?.fetchedAt
    }

    // Returns false when there is no historical range to manipulate.
    @discardableResult
    func beginDragging() -> Bool {
        guard let start = rangeStart,
              let end = rangeEnd,
              start < end else { return false }
        let available = records.filter {
            $0.fetchedAt >= start && $0.fetchedAt <= end
        }
        guard !available.isEmpty else { return false }

        playbackTask?.cancel()
        playbackTask = nil
        generation = UUID()
        playing = false
        dragging = true
        restored = true
        intervalText = nil

        gestureRecords = available
        gestureStart = displayedAt ?? end

        // Keep exactly the endpoints visible when the gesture began.
        rangeStart = start
        rangeEnd = end
        rangeLocked = true
        return true
    }

    func moveSlider(to date: Date) {
        guard dragging, let start = rangeStart, let end = rangeEnd else {
            return
        }
        sliderDate = min(end, max(start, date))
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
            for record in sequence {
                guard !Task.isCancelled,
                      self.generation == operation else { return }

                let frame = await AircraftHistoryStore.shared.presentation(
                    for: record)
                guard !Task.isCancelled,
                      self.generation == operation else { return }
                guard !frame.selectedIDs.isEmpty else { continue }

                guard await self.waitUntilVisible(operation: operation) else {
                    return
                }
                guard self.publish(frame) else { continue }

                // A full second of active viewing for each nonempty frame.
                // Slow preparation extends playback rather than skipping frames.
                guard await self.holdFrame(operation: operation) else { return }
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

    private func holdFrame(operation: UUID) async -> Bool {
        var remaining: TimeInterval = 1
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

    private func finishOperation() {
        playing = false
        intervalText = nil
        if let displayedAt, let start = rangeStart, let end = rangeEnd {
            sliderDate = min(end, max(start, displayedAt))
        } else {
            sliderDate = displayedAt
        }
        playbackTask = nil

        // Only a successful observation acquired AFTER completion may replace
        // the final historical frame. Empty responses never clear the map.
        followAfter = Date()
    }

    // Used when the owning view is removed; retain its last complete frame.
    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        generation = UUID()
        dragging = false
        playing = false
        intervalText = nil
        sliderDate = displayedAt
        followAfter = Date()
    }
}
