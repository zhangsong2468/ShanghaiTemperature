import XCTest
import Foundation
@testable import WeatherCore

final class AircraftServiceTests: XCTestCase {
    private let bounds = AircraftBounds(west: 116, south: 27, east: 124, north: 36)
    private let now = Date(timeIntervalSince1970: 1_795_247_422)

    private func payload(age: Double = 3, grounded: Bool = false,
                         category: Int = 8, track: Any = 343.98) throws -> Data {
        let row: [Any] = ["7804c3", "CES2631 ", "China",
            now.timeIntervalSince1970 - age, now.timeIntervalSince1970,
            118.8173, 32.149, 7802.88, grounded, 169.67, track, 0,
            NSNull(), 7879.08, "6240", false, 0, category]
        return try JSONSerialization.data(withJSONObject: [
            "time": now.timeIntervalSince1970, "states": [row]])
    }

    func testRealResponseFieldsAndExpiry() throws {
        let record = try AircraftDecoder.decode(payload(), bounds: bounds, now: now)
        let state = try XCTUnwrap(record.states.first)
        XCTAssertEqual(state.icao24, "7804c3")
        XCTAssertEqual(state.callsign, "CES2631")
        XCTAssertEqual(state.category, 8)
        XCTAssertEqual(try XCTUnwrap(state.track), 343.98, accuracy: 0.001)
        // The fixture position is already three seconds old.
        XCTAssertEqual(record.visible(at: now.addingTimeInterval(596)).count, 1)
        XCTAssertTrue(record.visible(at: now.addingTimeInterval(597)).isEmpty)
    }

    func testOldGroundedAndFuturePositionsAreHidden() throws {
        for age in [600.0, 601.0, -1.0] {
            XCTAssertTrue(try AircraftDecoder.decode(payload(age: age),
                bounds: bounds, now: now).states.isEmpty)
        }
        XCTAssertTrue(try AircraftDecoder.decode(payload(grounded: true),
            bounds: bounds, now: now).states.isEmpty)
    }

    private func state(id: Int, age: TimeInterval) -> AircraftState {
        AircraftState(
            icao24: String(format: "%06x", id),
            callsign: nil,
            positionAt: now.addingTimeInterval(-age),
            longitude: 118.8173,
            latitude: 32.149,
            track: nil,
            category: 0
        )
    }

    func testDecoderKeepsPositionsWithinTenMinutes() throws {
        for age in [119.0, 120.0, 299.0, 300.0, 599.0] {
            let record = try AircraftDecoder.decode(
                payload(age: age), bounds: bounds, now: now)
            XCTAssertEqual(record.states.count, 1)
            XCTAssertEqual(record.visible(at: now).count, 1)
            XCTAssertEqual(
                try XCTUnwrap(record.states.first).positionAt,
                now.addingTimeInterval(-age)
            )
        }
    }

    func testCandidateEligibilityHasNoCountThreshold() {
        for count in [5, 6, 10, 11, 30] {
            let aircraft = (1...count).map { state(id: $0, age: 599) }
            XCTAssertEqual(
                AircraftDisplayPolicy.choose(
                    aircraft, at: now, bounds: bounds).count,
                count
            )
        }
    }

    func testSelectorShowsUpToTenWithoutPercentageSampling() {
        for count in [1, 5, 6, 10, 11, 30] {
            let candidates = (1...count).map {
                TrackedAircraft(
                    state: state(id: $0, age: 300),
                    kind: .other,
                    firstSeen: now)
            }
            let selected = AircraftSelector.select(
                candidates, bounds: bounds, now: now)
            XCTAssertEqual(selected.aircraft.count, min(count, 10))
            XCTAssertEqual(
                Set(selected.aircraft.map { $0.state.icao24 }).count,
                selected.aircraft.count)
        }
    }

    func testFreshAndOlderPositionsRemainEligibleTogether() {
        let old = (1...5).map { state(id: $0, age: 599) }
        let fresh = state(id: 6, age: 119)
        let selected = AircraftDisplayPolicy.choose(
            old + [fresh], at: now, bounds: bounds)
        XCTAssertEqual(
            Set(selected.map { $0.icao24 }),
            Set((old + [fresh]).map { $0.icao24 }))
    }

    func testDuplicateAircraftUsesNewestObservation() {
        let older = state(id: 1, age: 599)
        let newer = state(id: 1, age: 300)
        let selected = AircraftDisplayPolicy.choose(
            [older, newer, older], at: now, bounds: bounds)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.positionAt, newer.positionAt)
    }

    func testTenMinuteExpiryBoundary() {
        let aircraft = state(id: 1, age: 599)
        XCTAssertEqual(
            AircraftDisplayPolicy.choose(
                [aircraft], at: now, bounds: bounds).count, 1)
        XCTAssertTrue(
            AircraftDisplayPolicy.choose(
                [aircraft], at: now.addingTimeInterval(1), bounds: bounds
            ).isEmpty
        )
    }

    func testMissingHeadingAndUnknownCategoryRemainUsable() throws {
        let record = try AircraftDecoder.decode(payload(category: 0, track: NSNull()),
            bounds: bounds, now: now)
        XCTAssertEqual(record.states.count, 1)
        XCTAssertNil(record.states.first?.track)
        XCTAssertEqual(record.states.first?.category, 0)
    }

    func testNullStatesAndBoundingBoxRequest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "time": now.timeIntervalSince1970, "states": NSNull()])
        XCTAssertTrue(try AircraftDecoder.decode(data, bounds: bounds, now: now).states.isEmpty)
        let url = try AircraftDecoder.url(bounds: bounds)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "opensky-network.org")
        XCTAssertEqual(items.first { $0.name == "extended" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "lomin" }?.value, "116.0")
    }

    func testSingleRoleCanClaimAndLateResponsePreservesDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AircraftSharedFiles(directory: directory)
        let first = try files.claim(role: "app", interval: 600,
            floor: .distantPast, paused: false, now: now)
        let firstID = try XCTUnwrap(first.1)
        XCTAssertEqual(first.0.initializedRoles, Set(["app"]))
        let other = try files.claim(role: "widget", interval: 600,
            floor: .distantPast, paused: false, now: now)
        XCTAssertNil(other.1)
        XCTAssertEqual(other.0.initializedRoles, Set(["app", "widget"]))
        XCTAssertEqual(other.0.nextAllowedAt, now.addingTimeInterval(600))
        let second = try files.claim(role: "widget", interval: 600,
            floor: .distantPast, paused: false, now: first.0.nextAllowedAt)
        let secondID = try XCTUnwrap(second.1)
        let lateDeadline = now.addingTimeInterval(3600)
        let delayed = try files.applyResponse(id: firstID, deadline: lateDeadline, credits: 5)
        XCTAssertEqual(delayed.nextAllowedAt, lateDeadline)
        XCTAssertEqual(delayed.latestRequestID, secondID)
        let newerResponse = try files.applyResponse(id: secondID, deadline: second.0.nextAllowedAt, credits: 4)
        XCTAssertEqual(newerResponse.nextAllowedAt, lateDeadline)

        let old = AircraftRecord(schema: 1, bounds: .acquisition, fetchedAt: now, states: [], batchID: firstID)
        XCTAssertTrue(try files.publish(old, id: firstID).batches.isEmpty)
        let record = AircraftRecord(schema: 1, bounds: .acquisition,
            fetchedAt: second.0.nextAllowedAt, states: [], batchID: secondID)
        let published = try files.publish(record, id: secondID)
        XCTAssertEqual(published.batches.map(\.id), [secondID])
        XCTAssertEqual(try files.publish(record, id: secondID).batches.count, 1)
        let restored = try XCTUnwrap(files.record(for: published.batches[0]))
        XCTAssertEqual(restored.batchID, secondID)
    }

    func testConcurrentSharedClaimsAndUnreadableState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AircraftSharedFiles(directory: directory)
        let lock = NSLock()
        var winners: [UUID] = []
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                let process = AircraftSharedFiles(directory: directory)
                let claim = try process.claim(role: index.isMultiple(of: 2) ? "app" : "widget",
                    interval: 600,
                    floor: .distantPast, paused: false, now: self.now)
                if let id = claim.1 {
                    lock.lock()
                    winners.append(id)
                    lock.unlock()
                }
            } catch {
                lock.lock()
                failures += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(winners.count, 1)
        let snapshot = try files.snapshot()
        XCTAssertEqual(snapshot.nextAllowedAt, now.addingTimeInterval(600))
        XCTAssertEqual(snapshot.initializedRoles, Set(["app", "widget"]))

        let stateURL = directory.appendingPathComponent("request-state.json")
        let invalid = Data("invalid state".utf8)
        try invalid.write(to: stateURL, options: .atomic)
        XCTAssertThrowsError(try files.claim(role: "app", interval: 600, floor: .distantPast, paused: false, now: now))
        XCTAssertEqual(try Data(contentsOf: stateURL), invalid)
    }

    func testExistingSharedDeadlineSurvivesRegistrationAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The registration field is optional; preserve a valid existing manifest.
        let deadline = now.addingTimeInterval(3600)
        let state = AircraftSharedState(nextAllowedAt: deadline)
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("request-state.json"))
        let widget = try AircraftSharedFiles(directory: directory).claim(role: "widget",
            interval: 600, floor: .distantPast, paused: false, now: now)
        XCTAssertNil(widget.1)
        XCTAssertEqual(widget.0.initializedRoles, Set(["widget"]))
        XCTAssertEqual(widget.0.nextAllowedAt, deadline)
        let restarted = try AircraftSharedFiles(directory: directory).claim(role: "app",
            interval: 600, floor: .distantPast, paused: false, now: now)
        XCTAssertNil(restarted.1)
        XCTAssertEqual(restarted.0.initializedRoles, Set(["app", "widget"]))
        XCTAssertEqual(restarted.0.nextAllowedAt, deadline)
    }

    func testResolvedHomeDirectoryMatchesLoginAccount() throws {
        let home = try XCTUnwrap(AircraftSharedFiles.realUserHome())
        XCTAssertTrue(home.path.hasPrefix("/"))
        XCTAssertFalse(home.path.contains("/Library/Containers/"))
        XCTAssertEqual(home.standardizedFileURL.path,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
    }
}
