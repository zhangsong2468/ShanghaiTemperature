import Foundation

enum AircraftKind: Int, Codable, Sendable {
    case helicopter = 0
    case heavy = 1
    case large = 2
    case other = 3

    static func classify(category: Int, model: String?) -> AircraftKind {
        switch category {
        case 8: return .helicopter
        case 6, 7: return .heavy
        case 4, 5: return .large
        case 0, 1: break
        default: return .other
        }
        // Only explicit ICAO type codes are used for the fallback.
        let code = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        let helicopters: Set<String> = [
            "R22", "R44", "R66", "B06", "B407", "B412", "B429", "B430",
            "B505", "B525", "AS50", "AS55", "AS65", "AS32", "EC20",
            "EC25", "EC30", "EC35", "EC45", "EC55", "EC75", "H160",
            "S76", "S92", "A109", "A119", "A139", "A169", "A189"
        ]
        let heavy: Set<String> = [
            "A306", "A30B", "A310", "A332", "A333", "A338", "A339",
            "A342", "A343", "A345", "A346", "A359", "A35K", "A388",
            "B741", "B742", "B743", "B744", "B748", "B74R",
            "B762", "B763", "B764", "B772", "B773", "B77L", "B77W",
            "B778", "B779", "B788", "B789", "B78X", "MD11"
        ]
        let large: Set<String> = [
            "A318", "A319", "A320", "A321", "A19N", "A20N", "A21N",
            "B731", "B732", "B733", "B734", "B735", "B736", "B737",
            "B738", "B739", "B37M", "B38M", "B39M", "B3XM",
            "B752", "B753", "BCS1", "BCS3", "C919",
            "E170", "E175", "E190", "E195", "E290", "E295",
            "CRJ7", "CRJ9", "CRJX", "ARJ2", "MD80", "MD81",
            "MD82", "MD83", "MD87", "MD88", "MD90"
        ]
        if helicopters.contains(code) { return .helicopter }
        if heavy.contains(code) { return .heavy }
        if large.contains(code) { return .large }
        return .other
    }
}

struct TrackedAircraft: Codable, Sendable {
    let state: AircraftState
    let kind: AircraftKind
    let firstSeen: Date
}

private struct AircraftTrackEntry: Codable {
    var state: AircraftState
    var firstSeen: Date
    var lastSeen: Date
    var unchangedReports: Int
}

private struct AircraftTrackingCache: Codable {
    let schema: Int
    let bounds: AircraftBounds
    let savedAt: Date
    let entries: [String: AircraftTrackEntry]
}

actor AircraftTrackingStore {
    static let shared = AircraftTrackingStore()
    private let directory: URL
    private var entries: [String: AircraftTrackEntry] = [:]
    private var bounds: AircraftBounds?
    private var restored = false
    private var lastUpdate: Date = .distantPast

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent(
            "ShanghaiTemperature/AircraftTracking-v1", isDirectory: true)
    }

    private var file: URL { directory.appendingPathComponent("tracks.json") }

    func update(record: AircraftRecord?, bounds requestedBounds: AircraftBounds,
                models: [String: String] = [:],
                now: Date = Date()) -> [TrackedAircraft] {
        guard requestedBounds.isValid, now.timeIntervalSince1970.isFinite else {
            return []
        }
        restore(now: now)
        if now < lastUpdate { entries.removeAll() }
        lastUpdate = now
        if bounds != requestedBounds {
            entries = entries.filter {
                requestedBounds.contains(
                    longitude: $0.value.state.longitude,
                    latitude: $0.value.state.latitude)
            }
            bounds = requestedBounds
        }

        if let record, record.schema == 1,
           record.bounds == requestedBounds, record.fetchedAt <= now {
            for state in record.visible(at: now) {
                guard state.icao24.range(
                    of: "^[0-9a-f]{6}$", options: .regularExpression
                ) != nil else { continue }
                if var entry = entries[state.icao24] {
                    // Repeated cached reports are not new observations.
                    guard state.positionAt > entry.state.positionAt else {
                        continue
                    }
                    let continuous = state.positionAt.timeIntervalSince(
                        entry.state.positionAt) < 120
                    if continuous && Self.samePosition(entry.state, state) {
                        entry.unchangedReports = min(3, entry.unchangedReports + 1)
                    } else {
                        entry.unchangedReports = 1
                    }
                    entry.state = state
                    entry.lastSeen = now
                    entries[state.icao24] = entry
                } else {
                    entries[state.icao24] = AircraftTrackEntry(
                        state: state, firstSeen: now, lastSeen: now,
                        unchangedReports: 1)
                }
            }
        }

        // Retained identity never extends the position's visibility.
        entries = entries.filter {
            let age = now.timeIntervalSince($0.value.lastSeen)
            return age >= 0 && age < 600
        }
        persist(now: now, bounds: requestedBounds)
        // A successful snapshot is authoritative for current membership.
        // Retained identity must not resurrect a missing or grounded target.
        let reportedIDs: Set<String>?
        if let record, record.schema == 1,
           record.bounds == requestedBounds, record.fetchedAt <= now {
            reportedIDs = Set(record.visible(at: now).map { $0.icao24 })
        } else {
            reportedIDs = nil
        }
        return entries.values.compactMap { entry -> TrackedAircraft? in
            if let reportedIDs,
               !reportedIDs.contains(entry.state.icao24) {
                return nil
            }
            guard entry.unchangedReports < 3,
                  entry.state.isVisible(at: now, bounds: requestedBounds) else {
                return nil
            }
            return TrackedAircraft(state: entry.state,
                kind: AircraftKind.classify(category: entry.state.category,
                    model: models[entry.state.icao24]),
                firstSeen: entry.firstSeen)
        }.sorted {
            if $0.kind != $1.kind {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            if $0.firstSeen != $1.firstSeen {
                return $0.firstSeen < $1.firstSeen
            }
            return $0.state.icao24 < $1.state.icao24
        }
    }

    private static func samePosition(_ a: AircraftState,
                                     _ b: AircraftState) -> Bool {
        a.longitude == b.longitude && a.latitude == b.latitude
    }

    private func restore(now: Date) {
        guard !restored else { return }
        restored = true
        guard let data = try? Data(contentsOf: file),
              data.count <= 5_000_000,
              let saved = try? JSONDecoder().decode(
                AircraftTrackingCache.self, from: data),
              saved.schema == 1, saved.bounds.isValid,
              saved.savedAt <= now,
              now.timeIntervalSince(saved.savedAt) < 600 else { return }
        bounds = saved.bounds
        lastUpdate = saved.savedAt
        entries = saved.entries.filter { key, entry in
            key == entry.state.icao24
                && entry.firstSeen <= entry.lastSeen
                && entry.lastSeen <= now
                && now.timeIntervalSince(entry.lastSeen) < 600
                && entry.unchangedReports >= 1
                && entry.unchangedReports <= 3
                && entry.state.longitude.isFinite
                && entry.state.latitude.isFinite
        }
    }

    private func persist(now: Date, bounds: AircraftBounds) {
        let saved = AircraftTrackingCache(schema: 1, bounds: bounds,
            savedAt: now, entries: entries)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        } catch {
            // Tracking continues in memory if persistence is unavailable.
        }
    }
}
