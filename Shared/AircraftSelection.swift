import Foundation

struct AircraftSelectionResult: Sendable {
    let aircraft: [TrackedAircraft]
    let shanghaiIDs: Set<String>
}

enum AircraftSelector {
    private struct Candidate {
        let aircraft: TrackedAircraft
        let shanghai: Bool
        let x: Double
        let y: Double
        let cell: Int
        let retained: Bool
    }

    static func select(
        _ aircraft: [TrackedAircraft],
        bounds: AircraftBounds,
        previousIDs: Set<String> = [],
        previousShanghaiIDs: Set<String> = [],
        now: Date = Date(),
        targetCount: Int? = nil,
        normalizedPosition: ((TrackedAircraft) -> (Double, Double))? = nil,
        canSelect: (TrackedAircraft, [TrackedAircraft]) -> Bool = { _, _ in true }
    ) -> AircraftSelectionResult {
        guard bounds.isValid else {
            return AircraftSelectionResult(aircraft: [], shanghaiIDs: [])
        }
        let south = mercator(bounds.south)
        let north = mercator(bounds.north)
        var unique: [String: TrackedAircraft] = [:]
        let allowedIDs = Set(AircraftDisplayPolicy.choose(
            aircraft.map { $0.state }, at: now, bounds: bounds
        ).map { $0.icao24 })
        for item in aircraft where allowedIDs.contains(item.state.icao24) {
            let id = item.state.icao24
            if let old = unique[id], old.state.positionAt >= item.state.positionAt {
                continue
            }
            unique[id] = item
        }
        let candidates = unique.values.map { item -> Candidate in
            let state = item.state
            let position = normalizedPosition?(item)
            let x = min(1, max(0, position?.0 ??
                ((state.longitude - bounds.west) / (bounds.east - bounds.west))))
            let y = min(1, max(0, position?.1 ??
                ((north - mercator(state.latitude)) / (north - south))))
            let distance = shanghaiDistance(
                longitude: state.longitude, latitude: state.latitude)
            let shanghai: Bool
            if previousIDs.contains(state.icao24) {
                // Hysteresis prevents repeated group changes near the boundary.
                shanghai = distance <=
                    (previousShanghaiIDs.contains(state.icao24) ? 110 : 90)
            } else {
                shanghai = distance <= 100
            }
            let column = min(9, Int(x * 10))
            let row = min(9, Int(y * 10))
            return Candidate(aircraft: item, shanghai: shanghai,
                x: x, y: y, cell: row * 10 + column,
                retained: previousIDs.contains(state.icao24))
        }
        let target = min(
            candidates.count, min(10, max(0, targetCount ?? 10)))
        guard target > 0 else {
            return AircraftSelectionResult(aircraft: [], shanghaiIDs: [])
        }
        var selected: [Candidate] = []
        var selectedIDs = Set<String>()
        var occupiedCells = Set<Int>()

        func separation(_ candidate: Candidate) -> Double {
            selected.map {
                hypot(candidate.x - $0.x, candidate.y - $0.y)
            }.min() ?? 2
        }

        func preferred(_ a: Candidate, _ b: Candidate) -> Bool {
            let ak = a.aircraft.kind.rawValue
            let bk = b.aircraft.kind.rawValue
            if ak != bk { return ak < bk }
            if a.retained != b.retained { return a.retained }
            let aFree = !occupiedCells.contains(a.cell)
            let bFree = !occupiedCells.contains(b.cell)
            if aFree != bFree { return aFree }
            let ad = separation(a)
            let bd = separation(b)
            if ad != bd { return ad > bd }
            if a.aircraft.firstSeen != b.aircraft.firstSeen {
                return a.aircraft.firstSeen < b.aircraft.firstSeen
            }
            return a.aircraft.state.icao24 < b.aircraft.state.icao24
        }

        func take(group: Bool?, count: Int) {
            guard count > 0 else { return }
            for _ in 0..<count {
                let available = candidates.filter {
                    !selectedIDs.contains($0.aircraft.state.icao24)
                        && (group == nil || $0.shanghai == group!)
                        && canSelect($0.aircraft, selected.map(\.aircraft))
                }
                guard let best = available.sorted(by: preferred).first else {
                    break
                }
                selected.append(best)
                selectedIDs.insert(best.aircraft.state.icao24)
                occupiedCells.insert(best.cell)
            }
        }

        // Odd-numbered allocations give the extra slot to Shanghai.
        take(group: true, count: (target + 1) / 2)
        take(group: false, count: target / 2)
        // Unused allocation can be borrowed by either group.
        take(group: nil, count: target - selected.count)
        return AircraftSelectionResult(
            aircraft: selected.map(\.aircraft),
            shanghaiIDs: Set(selected.filter(\.shanghai).map {
                $0.aircraft.state.icao24
            }))
    }

    private static func mercator(_ latitude: Double) -> Double {
        log(tan(.pi / 4 + latitude * .pi / 360))
    }

    static func shanghaiDistance(
        longitude: Double, latitude: Double
    ) -> Double {
        let radians = Double.pi / 180
        let latitude1 = 31.2304 * radians
        let latitude2 = latitude * radians
        let deltaLatitude = latitude2 - latitude1
        let deltaLongitude = (longitude - 121.4737) * radians
        let a = pow(sin(deltaLatitude / 2), 2)
            + cos(latitude1) * cos(latitude2)
            * pow(sin(deltaLongitude / 2), 2)
        return 6371 * 2 * asin(sqrt(min(1, max(0, a))))
    }
}


// Persist numeric geometry fields. CGPoint and CGSize are reconstructed
// for drawing and do not participate in synthesized Codable.
struct AircraftMapDrawResult: Codable, Sendable {
    struct Icon: Codable, Sendable {
        let id: String
        let symbol: String
        private let anchorX: Double
        private let anchorY: Double
        private let iconWidth: Double
        private let iconHeight: Double
        let angle: Double

        var anchor: CGPoint { CGPoint(x: CGFloat(anchorX), y: CGFloat(anchorY)) }
        var width: CGFloat { CGFloat(iconWidth) }
        var height: CGFloat { CGFloat(iconHeight) }

        init(id: String, symbol: String, anchor: CGPoint,
             width: CGFloat, height: CGFloat, angle: Double) {
            self.id = id
            self.symbol = symbol
            anchorX = Double(anchor.x)
            anchorY = Double(anchor.y)
            iconWidth = Double(width)
            iconHeight = Double(height)
            self.angle = angle
        }
    }

    struct Label: Codable, Sendable {
        let text: String
        private let originX: Double
        private let originY: Double

        var origin: CGPoint { CGPoint(x: CGFloat(originX), y: CGFloat(originY)) }

        init(text: String, origin: CGPoint) {
            self.text = text
            originX = Double(origin.x)
            originY = Double(origin.y)
        }
    }

    private let canvasWidth: Double
    private let canvasHeight: Double
    let renderedAt: Date
    let visibleIDs: Set<String>
    let shanghaiIDs: Set<String>
    let labelPositions: [String: Int]
    let icons: [Icon]
    let labels: [Label]

    var canvasSize: CGSize {
        CGSize(width: CGFloat(canvasWidth), height: CGFloat(canvasHeight))
    }

    init(canvasSize: CGSize, renderedAt: Date, visibleIDs: Set<String>,
         shanghaiIDs: Set<String>, labelPositions: [String: Int],
         icons: [Icon], labels: [Label]) {
        canvasWidth = Double(canvasSize.width)
        canvasHeight = Double(canvasSize.height)
        self.renderedAt = renderedAt
        self.visibleIDs = visibleIDs
        self.shanghaiIDs = shanghaiIDs
        self.labelPositions = labelPositions
        self.icons = icons
        self.labels = labels
    }
}

struct AircraftOverlaySnapshot: Sendable {
    var frozenAt: Date? = nil
    var preparedLayout: AircraftMapDrawResult? = nil
    var labelPositions: [String: Int] = [:]
    let selectedIDs: Set<String>
    let shanghaiIDs: Set<String>
    let aircraft: [TrackedAircraft]
    let metadata: [String: AircraftMetadata]
    let bounds: AircraftBounds
    let refreshAfter: Date

    func visible(at date: Date) -> [TrackedAircraft] {
        if frozenAt != nil {
            return aircraft.filter { selectedIDs.contains($0.state.icao24) }
        }
        let ids = Set(AircraftDisplayPolicy.choose(
            aircraft.map { $0.state }, at: date, bounds: bounds
        ).map { $0.icao24 })
        return aircraft.filter { ids.contains($0.state.icao24) }
    }
}

// Widget-only live position expiry. A held or paused snapshot uses the
// selected IDs and observation time captured when its layout was prepared.
enum WidgetAircraftVisibility {
    static let maximumPositionAge: TimeInterval = 240

    static func visible(
        _ overlay: AircraftOverlaySnapshot?, at date: Date
    ) -> [TrackedAircraft] {
        guard let overlay else { return [] }
        if overlay.frozenAt != nil { return overlay.visible(at: date) }
        return overlay.visible(at: date).filter { item in
            let age = date.timeIntervalSince(item.state.positionAt)
            return age >= 0 && age < maximumPositionAge
                && item.state.isVisible(at: date, bounds: overlay.bounds)
        }
    }

    static func expirationDates(
        _ overlay: AircraftOverlaySnapshot?, after date: Date
    ) -> [Date] {
        guard let overlay, overlay.frozenAt == nil else { return [] }
        return overlay.aircraft.map {
            $0.state.positionAt.addingTimeInterval(maximumPositionAge)
        }.filter { $0 > date }
    }
}

private struct AircraftPreviousSelection: Codable {
    let savedAt: Date
    let ids: Set<String>
    let shanghaiIDs: Set<String>
    var labelPositions: [String: Int]? = nil
}

actor AircraftOverlayStore {
    static let shared = AircraftOverlayStore()
    private var previous: AircraftPreviousSelection?
    private var latestPrepared: AircraftFrozenOverlay?

    private var frozenFile: URL {
        file.deletingLastPathComponent().appendingPathComponent("frozen-overlay.json")
    }

    private func restorePrepared() {
        guard latestPrepared == nil,
              let data = try? Data(contentsOf: frozenFile),
              let saved = try? JSONDecoder().decode(
                AircraftFrozenOverlay.self, from: data) else { return }
        latestPrepared = saved
    }

    func rememberPrepared(
        _ overlay: AircraftOverlaySnapshot, at date: Date, generation: String
    ) -> AircraftOverlaySnapshot {
        guard overlay.frozenAt == nil else { return overlay }
        let pause = AircraftPauseSettings.current
        // Pause can change while the widget prepares a timeline. Return the
        // previous frozen frame instead of publishing the obsolete live one.
        guard !pause.paused, pause.generation == generation else {
            return frozen(bounds: overlay.bounds)
        }
        if let latestPrepared, latestPrepared.date > date { return overlay }
        let saved = AircraftFrozenOverlay(
            overlay: overlay, date: date, generation: pause.generation)
        latestPrepared = saved
        do {
            try FileManager.default.createDirectory(
                at: frozenFile.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(
                to: frozenFile, options: .atomic)
        } catch {
            NSLog("Aircraft frozen snapshot save failed: %@", String(describing: error))
        }
        return overlay
    }

    func frozen(bounds: AircraftBounds) -> AircraftOverlaySnapshot {
        restorePrepared()
        if let latestPrepared {
            return latestPrepared.snapshot
        }
        return AircraftOverlaySnapshot(
            frozenAt: Date(),
            selectedIDs: [], shanghaiIDs: [], aircraft: [],
            metadata: [:], bounds: bounds,
            refreshAfter: Date().addingTimeInterval(3600))
    }

    private var file: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent(
            "ShanghaiTemperature/AircraftTracking-v1/selection.json")
    }

    func load(bounds: AircraftBounds, preparedUpdate: AircraftUpdate? = nil) async -> AircraftOverlaySnapshot {
        restorePrepared()
        let started = AircraftPauseSettings.current
        let update: AircraftUpdate
        if let preparedUpdate { update = preparedUpdate }
        else { update = await AircraftStore.shared.load(bounds: bounds) }
        if started.paused { return frozen(bounds: bounds) }
        let initialDate = Date()
        let current = AircraftPauseSettings.current
        if current.paused || current.generation != started.generation {
            return frozen(bounds: bounds)
        }
        // After resume, preserve the frozen display until a new successful
        // OpenSky response arrives. A successful empty response also qualifies.
        if latestPrepared?.generation != current.generation,
           current.generation != "initial",
           (update.record?.fetchedAt ?? .distantPast) < current.changedAt {
            var held = frozen(bounds: bounds)
            held = AircraftOverlaySnapshot(
                frozenAt: held.frozenAt,
                preparedLayout: held.preparedLayout,
                labelPositions: held.labelPositions,
                selectedIDs: held.selectedIDs, shanghaiIDs: held.shanghaiIDs,
                aircraft: held.aircraft, metadata: held.metadata,
                bounds: held.bounds, refreshAfter: update.refreshAfter)
            return held
        }
        if previous == nil,
           let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(
                AircraftPreviousSelection.self, from: data),
           saved.savedAt <= initialDate,
           initialDate.timeIntervalSince(saved.savedAt) < 600 {
            previous = saved
        }
        if let saved = previous,
           saved.savedAt > initialDate
                || initialDate.timeIntervalSince(saved.savedAt) >= 600 {
            previous = nil
        }

        let tracked = await AircraftTrackingStore.shared.update(
            record: update.record, bounds: bounds, now: initialDate)
        var models = await classificationModels(for: tracked)
        let classified = tracked.map { item in
            TrackedAircraft(state: item.state,
                kind: AircraftKind.classify(category: item.state.category,
                    model: models[item.state.icao24]),
                firstSeen: item.firstSeen)
        }
        let first = AircraftSelector.select(
            classified, bounds: bounds,
            previousIDs: previous?.ids ?? [],
            previousShanghaiIDs: previous?.shanghaiIDs ?? [],
            now: Date())

        var metadata = await Self.lookup(first.aircraft)
        for (id, value) in metadata {
            if let model = value.model { models[id] = model }
        }

        // Reclassify targets after model lookup without counting cached
        // position reports as additional stationary observations.
        let refreshed = await AircraftTrackingStore.shared.update(
            record: update.record, bounds: bounds, models: models,
            now: Date())
        let second = AircraftSelector.select(
            refreshed, bounds: bounds,
            previousIDs: previous?.ids ?? [],
            previousShanghaiIDs: previous?.shanghaiIDs ?? [],
            now: Date())
        let missing = second.aircraft.filter {
            metadata[$0.state.icao24] == nil
        }
        let additional = await Self.lookup(missing)
        metadata.merge(additional) { _, new in new }

        for (id, value) in metadata {
            if let model = value.model { models[id] = model }
        }
        let now = Date()
        let finalCandidates = refreshed.compactMap { item -> TrackedAircraft? in
            guard item.state.isVisible(at: now, bounds: bounds) else {
                return nil
            }
            return TrackedAircraft(
                state: item.state,
                kind: AircraftKind.classify(
                    category: item.state.category,
                    model: models[item.state.icao24]),
                firstSeen: item.firstSeen)
        }
        let finalSelection = AircraftSelector.select(
            finalCandidates, bounds: bounds,
            previousIDs: previous?.ids ?? [],
            previousShanghaiIDs: previous?.shanghaiIDs ?? [],
            now: now)
        let visible = finalSelection.aircraft
        let ids = Set(visible.map { $0.state.icao24 })
        let saved = AircraftPreviousSelection(
            savedAt: now, ids: ids,
            shanghaiIDs: finalSelection.shanghaiIDs.intersection(ids),
            labelPositions: previous?.labelPositions?.filter { entry in
                finalCandidates.contains { item in
                    item.state.icao24 == entry.key
                }
            })
        previous = saved
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        } catch {
            // Selection remains available in memory.
        }
        // Keep valid backup candidates for viewport and collision selection.
        // Put provider-selected targets first to preserve their preference.
        let backup = finalCandidates.filter {
            !ids.contains($0.state.icao24)
        }
        for item in visible + backup {
            let id = item.state.icao24
            if metadata[id] == nil, let model = models[id] {
                metadata[id] = AircraftMetadata(
                    model: model, airline: nil, flightNumber: nil)
            }
        }
        let latestPause = AircraftPauseSettings.current
        if latestPause.paused || latestPause.generation != started.generation {
            return frozen(bounds: bounds)
        }
        let result = AircraftOverlaySnapshot(
            labelPositions: previous?.labelPositions ?? [:],
            selectedIDs: saved.ids, shanghaiIDs: saved.shanghaiIDs,
            aircraft: visible + backup, metadata: metadata, bounds: bounds,
            refreshAfter: update.refreshAfter)
        if let record = update.record {
            await AircraftHistoryStore.shared.rememberPresentation(
                result, record: record)
        }
        // History persistence is an actor hop; recheck pause before returning.
        let completedPause = AircraftPauseSettings.current
        if completedPause.paused
            || completedPause.generation != started.generation {
            return frozen(bounds: bounds)
        }
        return result
    }

    // Call only during current timeline preparation, never from Canvas
    // or while laying out future expiration entries.
    func savePreparedLayout(
        visibleIDs: Set<String>,
        shanghaiIDs: Set<String>,
        labelPositions: [String: Int],
        preparedAt: Date
    ) {
        let now = Date()
        guard preparedAt <= now,
              now.timeIntervalSince(preparedAt) < 120 else { return }
        if let previous, previous.savedAt > preparedAt { return }
        let positions = labelPositions.filter {
            visibleIDs.contains($0.key) && (0..<8).contains($0.value)
        }
        let saved = AircraftPreviousSelection(
            savedAt: preparedAt,
            ids: visibleIDs,
            shanghaiIDs: shanghaiIDs.intersection(visibleIDs),
            labelPositions: positions)
        previous = saved
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        } catch {
            // Preserve the prepared layout in memory if writing fails.
        }
    }

    private func classificationModels(
        for aircraft: [TrackedAircraft]
    ) async -> [String: String] {
        var models: [String: String] = [:]
        var missing: [String] = []
        for item in aircraft.sorted(by: {
            $0.state.icao24 < $1.state.icao24
        }) {
            let id = item.state.icao24
            if let model = await AircraftMetadataStore.shared.cachedModel(icao24: id) {
                models[id] = model
            } else if item.state.category == 0 || item.state.category == 1 {
                missing.append(id)
            }
        }
        guard !missing.isEmpty else { return models }

        // Rotate a bounded batch across refreshes and process restarts.
        let cursorFile = file.deletingLastPathComponent()
            .appendingPathComponent("classification-cursor.json")
        let savedCursor: Int
        if let data = try? Data(contentsOf: cursorFile),
           let value = try? JSONDecoder().decode(Int.self, from: data),
           value >= 0 {
            savedCursor = value
        } else {
            savedCursor = 0
        }
        let start = savedCursor % missing.count
        let count = min(6, missing.count)
        let ids = (0..<count).map { missing[(start + $0) % missing.count] }
        try? FileManager.default.createDirectory(
            at: cursorFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? JSONEncoder().encode((start + count) % missing.count)
            .write(to: cursorFile, options: .atomic)

        let fetched = await withTaskGroup(
            of: (String, String?).self,
            returning: [String: String].self
        ) { group in
            for id in ids {
                group.addTask {
                    let model = await AircraftMetadataStore.shared.loadModel(icao24: id)
                    return (id, model)
                }
            }
            var result: [String: String] = [:]
            for await (id, model) in group {
                if let model { result[id] = model }
            }
            return result
        }
        models.merge(fetched) { _, new in new }
        return models
    }

    private static func lookup(
        _ aircraft: [TrackedAircraft]
    ) async -> [String: AircraftMetadata] {
        await withTaskGroup(
            of: (String, AircraftMetadata).self,
            returning: [String: AircraftMetadata].self
        ) { group in
            for item in aircraft {
                let state = item.state
                group.addTask {
                    let value = await AircraftMetadataStore.shared.load(
                        icao24: state.icao24, callsign: state.callsign)
                    return (state.icao24, value)
                }
            }
            var result: [String: AircraftMetadata] = [:]
            for await (id, value) in group {
                result[id] = value
            }
            return result
        }
    }
}


struct AircraftFrozenOverlay: Codable {
    struct Item: Codable {
        let state: AircraftState
        let kind: Int
        let firstSeen: Date
    }
    struct Metadata: Codable {
        let model: String?
        let airline: String?
        let flightNumber: String?
    }
    let date: Date
    let generation: String
    let preparedLayout: AircraftMapDrawResult?
    let labelPositions: [String: Int]
    let selectedIDs: Set<String>
    let shanghaiIDs: Set<String>
    let items: [Item]
    let metadata: [String: Metadata]
    let bounds: AircraftBounds
    let refreshAfter: Date

    init(overlay: AircraftOverlaySnapshot, date: Date, generation: String) {
        self.date = date
        self.generation = generation
        preparedLayout = overlay.preparedLayout
        labelPositions = overlay.labelPositions
        selectedIDs = overlay.selectedIDs
        shanghaiIDs = overlay.shanghaiIDs
        items = overlay.aircraft.filter {
            overlay.selectedIDs.contains($0.state.icao24)
        }.map {
            Item(state: $0.state, kind: $0.kind.rawValue, firstSeen: $0.firstSeen)
        }
        metadata = overlay.metadata.mapValues {
            Metadata(model: $0.model, airline: $0.airline, flightNumber: $0.flightNumber)
        }
        bounds = overlay.bounds
        refreshAfter = overlay.refreshAfter
    }

    var snapshot: AircraftOverlaySnapshot {
        AircraftOverlaySnapshot(
            frozenAt: date,
            preparedLayout: preparedLayout,
            labelPositions: labelPositions,
            selectedIDs: selectedIDs,
            shanghaiIDs: shanghaiIDs,
            aircraft: items.map {
                TrackedAircraft(
                    state: $0.state,
                    kind: AircraftKind(rawValue: $0.kind) ?? .other,
                    firstSeen: $0.firstSeen)
            },
            metadata: metadata.mapValues {
                AircraftMetadata(
                    model: $0.model, airline: $0.airline, flightNumber: $0.flightNumber)
            },
            bounds: bounds, refreshAfter: refreshAfter)
    }
}
