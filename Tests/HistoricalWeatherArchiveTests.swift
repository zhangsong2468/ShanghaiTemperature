import XCTest
import Foundation
import CryptoKit
@testable import WeatherCore

final class HistoricalWeatherArchiveTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var data = Data(repeating: 0, count: 8784 * 2 * 6)
        func put(_ hour: Int, point: Int, temperature: Int16, humidity: UInt16, wind: UInt16) {
            let values = [UInt16(bitPattern: temperature), humidity, wind]
            let base = (point * 8784 + hour) * 6
            for (i, value) in values.enumerated() {
                data[base + i*2] = UInt8(value & 255)
                data[base + i*2 + 1] = UInt8(value >> 8)
            }
        }
        put(0, point: 0, temperature: -325, humidity: 7250, wind: 345)
        put(0, point: 1, temperature: 1525, humidity: 6000, wind: 120)
        put(8783, point: 0, temperature: 1234, humidity: 8000, wind: 200)
        try data.write(to: url.appendingPathComponent("2024.bin"))
        let index: [String: Any] = [
            "schema": 1, "model": "era5", "timezone": "Asia/Shanghai", "recordBytes": 6,
            "scales": [100,100,100], "fields": ["temperature_2m","relative_humidity_2m","wind_speed_10m"],
            "units": ["°C","%","m/s"], "ordering": "point-major/hour-major",
            "points": [["id":"p000", "latitude":31.0, "longitude":120.0],
                       ["id":"p001", "latitude":32.0, "longitude":121.0]],
            "years": [["year":2024, "file":"2024.bin", "hours":8784, "bytes":data.count,
                       "sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()]]]
        try JSONSerialization.data(withJSONObject:index).write(to:url.appendingPathComponent("index.json"))
        return url
    }

    func testPointHourSignedTemperatureAndYearEnd() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at:url) }
        let archive = try HistoricalWeatherArchive(directory:url)
        let first = try await archive.samples(at:ShanghaiTime.parseDay("2024-01-01")!.addingTimeInterval(1800))
        XCTAssertEqual(first.count,2)
        XCTAssertEqual(first[0].temperature,-3.25)
        XCTAssertEqual(first[0].relativeHumidity,72.5)
        XCTAssertEqual(first[0].windSpeed,3.45)
        XCTAssertEqual(first[1].point.id,"p001")
        XCTAssertEqual(first[1].temperature,15.25)
        let last = try await archive.sample(pointID:"p000",at:ShanghaiTime.parseDay("2024-12-31")!.addingTimeInterval(23*3600))
        XCTAssertEqual(last.temperature,12.34)
        do {
            _ = try await archive.samples(at:ShanghaiTime.parseDay("2025-01-01")!)
            XCTFail("Must not replace missing year with another year")
        } catch HistoricalArchiveError.outsideArchive { }
    }

    func testRejectsCorruptFile() async throws {
        let url=try fixture()
        defer { try? FileManager.default.removeItem(at:url) }
        var data=try Data(contentsOf:url.appendingPathComponent("2024.bin"))
        data[0] ^= 1
        try data.write(to:url.appendingPathComponent("2024.bin"))
        let archive=try HistoricalWeatherArchive(directory:url)
        do {
            _ = try await archive.samples(at:ShanghaiTime.parseDay("2024-01-01")!)
            XCTFail("Checksum mismatch must be rejected")
        } catch HistoricalArchiveError.invalidFile { }
    }
}
