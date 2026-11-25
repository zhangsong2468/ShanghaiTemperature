import Foundation
import CoreFoundation
import OSLog

// New observations live in immutable shared batch files. Old preference keys
// remain readable until their normal retention deadline.
actor AircraftHistoryStore {
    static let shared = AircraftHistoryStore()
    static let retention: TimeInterval = 8 * 86400
    private static let prefix = "aircraftHistoryV1."
    private static let presentationPrefix = "aircraftPresentationV1."
    private let logger = Logger(
        subsystem: "com.songa.ShanghaiTemperature",
        category: "AircraftHistory")
    private var lastPruned: Date = .distantPast
    private let files = AircraftSharedFiles()
    private var legacyRecords: [String: AircraftRecord] = [:]
    private var sharedRecords: [UUID: AircraftRecord] = [:]

    private var domain: CFString {
        ThermalSourceSettings.domain as CFString
    }

    private func synchronize() -> Bool {
        CFPreferencesSynchronize(
            domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func keys() -> [String] {
        (CFPreferencesCopyKeyList(
            domain, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost) as? [String] ?? [])
            .filter { $0.hasPrefix(Self.prefix) }
    }

    private func timestamp(for key: String) -> Date? {
        let suffix = key.dropFirst(Self.prefix.count)
        guard let seconds = Double(suffix),
              seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // Returns actual successful observations, including successful empty frames.
    // No synthetic ten-minute records are inserted into gaps.
    func records(
        since start: Date,
        through end: Date = Date()
    ) -> [AircraftRecord] {
        guard start <= end else { return [] }
        _ = synchronize()
        prune(at: Date())
        let earliest = max(start, Date().addingTimeInterval(-Self.retention))
        var result: [AircraftRecord] = []
        let savedKeys = keys()
        let retainedKeys = Set(savedKeys)
        legacyRecords = legacyRecords.filter { retainedKeys.contains($0.key) }
        for savedKey in savedKeys {
            guard let date = timestamp(for: savedKey), date >= earliest, date <= end else { continue }
            if let cached = legacyRecords[savedKey] {
                result.append(cached)
                continue
            }
            guard let text = CFPreferencesCopyValue(
                savedKey as CFString, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String,
                let data = text.data(using: .utf8),
                let record = try? JSONDecoder().decode(AircraftRecord.self, from: data),
                record.schema == 1, record.bounds.isValid, record.fetchedAt == date else { continue }
            legacyRecords[savedKey] = record
            result.append(record)
        }
        if let state = try? files.snapshot(),
           let bounds = AircraftBounds.viewport(canvas: AircraftBounds.appCanvas) {
            let retained = Set(state.batches.map(\.id))
            sharedRecords = sharedRecords.filter { retained.contains($0.key) }
            for batch in state.batches where batch.fetchedAt >= earliest && batch.fetchedAt <= end {
                if let cached = sharedRecords[batch.id] {
                    result.append(cached)
                    continue
                }
                if let raw = try? files.record(for: batch) {
                    let record = raw.scoped(to: bounds, at: raw.fetchedAt)
                    sharedRecords[batch.id] = record
                    result.append(record)
                }
            }
        } else {
            result += sharedRecords.values.filter { $0.fetchedAt >= earliest && $0.fetchedAt <= end }
        }
        return result.sorted { $0.fetchedAt < $1.fetchedAt }
    }

    func latestNonempty() -> AircraftRecord? {
        records(since: Date().addingTimeInterval(-Self.retention))
            .last { record in
                !record.visible(at: record.fetchedAt).isEmpty
            }
    }

    private func prune(at now: Date) {
        // Avoid repeatedly enumerating and rewriting preferences on UI reads.
        guard now < lastPruned ||
                now.timeIntervalSince(lastPruned) >= 3600 else { return }
        lastPruned = now
        let cutoff = now.addingTimeInterval(-Self.retention)
        var removed = false
        let allKeys = CFPreferencesCopyKeyList(
            domain, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost) as? [String] ?? []
        for savedKey in allKeys {
            let prefix: String
            if savedKey.hasPrefix(Self.prefix) {
                prefix = Self.prefix
            } else if savedKey.hasPrefix(Self.presentationPrefix) {
                prefix = Self.presentationPrefix
            } else {
                continue
            }
            guard let seconds = Double(savedKey.dropFirst(prefix.count)),
                  seconds.isFinite,
                  Date(timeIntervalSince1970: seconds) < cutoff else {
                continue
            }
            CFPreferencesSetValue(
                savedKey as CFString, nil, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            removed = true
        }
        if removed && !synchronize() {
            logger.error("History retention cleanup could not be synchronized")
        }
    }
}


// Presentation is stored separately from the original successful response.
// A cached response must never acquire a newer observation timestamp.
struct AircraftHistoryPresentation: Codable, Sendable {
    let schema: Int
    let fetchedAt: Date
    let bounds: AircraftBounds
    let aircraft: [TrackedAircraft]
    let metadata: [String: AircraftMetadata]
    let selectedIDs: Set<String>
    let shanghaiIDs: Set<String>
    let labelPositions: [String: Int]

    var overlay: AircraftOverlaySnapshot {
        AircraftOverlaySnapshot(
            frozenAt: fetchedAt,
            labelPositions: labelPositions,
            selectedIDs: selectedIDs,
            shanghaiIDs: shanghaiIDs,
            aircraft: aircraft,
            metadata: metadata,
            bounds: bounds,
            refreshAfter: .distantFuture)
    }
}

extension AircraftHistoryStore {
    func rememberPresentation(
        _ overlay: AircraftOverlaySnapshot,
        record: AircraftRecord
    ) {
        let now = Date()
        guard overlay.frozenAt == nil,
              record.schema == 1,
              record.bounds == overlay.bounds,
              record.fetchedAt <= now,
              now.timeIntervalSince(record.fetchedAt) < Self.retention else {
            return
        }

        guard let id = record.batchID,
              let url = files.presentationURL(id, role: AircraftSharedFiles.role) else { return }

        // Freeze the first completed presentation for this observation.
        // Later cache reads must not rewrite its labels or selected targets.
        if FileManager.default.fileExists(atPath: url.path) { return }

        let reported = Set(record.visible(at: record.fetchedAt).map(\.icao24))
        var seen = Set<String>()
        let eligible = overlay.aircraft.filter {
            reported.contains($0.state.icao24)
                && $0.state.isVisible(at: record.fetchedAt, bounds: record.bounds)
                && seen.insert($0.state.icao24).inserted
        }
        let available = Set(eligible.map { $0.state.icao24 })
        let ids = Set(overlay.aircraft.filter {
            overlay.selectedIDs.contains($0.state.icao24)
                && available.contains($0.state.icao24)
        }.prefix(10).map { $0.state.icao24 })

        let saved = AircraftHistoryPresentation(
            schema: 1,
            fetchedAt: record.fetchedAt,
            bounds: record.bounds,
            aircraft: eligible,
            metadata: overlay.metadata.filter { available.contains($0.key) },
            selectedIDs: ids,
            shanghaiIDs: overlay.shanghaiIDs.intersection(ids),
            labelPositions: overlay.labelPositions.filter {
                ids.contains($0.key) && (0...1).contains($0.value)
            })
        do {
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        } catch {
            logger.error("History presentation save failed: \(String(describing: error), privacy: .public)")
        }
    }

    func presentation(
        for record: AircraftRecord
    ) -> AircraftHistoryPresentation {
        let saved: AircraftHistoryPresentation?
        if let id = record.batchID, let url = files.presentationURL(id, role: "app") {
            saved = try? AircraftSharedFiles.readIfPresent(AircraftHistoryPresentation.self, at: url)
        } else {
            _ = synchronize()
            let key = Self.presentationPrefix + String(record.fetchedAt.timeIntervalSince1970)
            if let text = CFPreferencesCopyValue(key as CFString, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String,
               let data = text.data(using: .utf8) {
                saved = try? JSONDecoder().decode(AircraftHistoryPresentation.self, from: data)
            } else {
                saved = nil
            }
        }
        let reported = Set(record.visible(at: record.fetchedAt).map(\.icao24))

        if let saved,
           saved.schema == 1,
           saved.fetchedAt == record.fetchedAt,
           saved.bounds == record.bounds,
           saved.selectedIDs.count <= 10,
           saved.selectedIDs.isSubset(of: reported),
           saved.selectedIDs.isSubset(of: Set(saved.aircraft.map {
               $0.state.icao24
           })),
           saved.aircraft.allSatisfy({
               reported.contains($0.state.icao24)
                   && $0.state.isVisible(
                       at: record.fetchedAt, bounds: record.bounds)
           }) {
            return saved
        }

        // Position history remains usable if metadata was unavailable or its
        // presentation could not be saved. Never make network requests here.
        // When the app was closed, reuse metadata recorded by the widget,
        // but select and lay out the targets for the app's own viewport.
        var metadata: [String: AircraftMetadata] = [:]
        if let id = record.batchID, let url = files.presentationURL(id, role: "widget"),
           let widget = try? AircraftSharedFiles.readIfPresent(AircraftHistoryPresentation.self, at: url),
           widget.schema == 1, widget.fetchedAt == record.fetchedAt {
            metadata = widget.metadata.filter { reported.contains($0.key) }
        }
        let candidates = record.visible(at: record.fetchedAt).map {
            TrackedAircraft(
                state: $0,
                kind: AircraftKind.classify(category: $0.category, model: metadata[$0.icao24]?.model),
                firstSeen: record.fetchedAt)
        }
        let selection = AircraftSelector.select(
            candidates, bounds: record.bounds, now: record.fetchedAt)
        return AircraftHistoryPresentation(
            schema: 1,
            fetchedAt: record.fetchedAt,
            bounds: record.bounds,
            aircraft: candidates,
            metadata: metadata,
            selectedIDs: Set(selection.aircraft.map { $0.state.icao24 }),
            shanghaiIDs: selection.shanghaiIDs,
            labelPositions: [:])
    }
}
