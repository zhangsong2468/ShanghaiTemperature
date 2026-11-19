import XCTest
import Foundation
@testable import WeatherCore

final class NetworkApparentTemperatureTests: XCTestCase {
    private let point=HistoricalWeatherPoint(id:"p000",latitude:31,longitude:120)

    private func body(_ request: URLRequest, unit: String = "°C") throws -> Data {
        let items=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
        let start=ShanghaiTime.parseDay(items.first { $0.name=="start_date" }!.value!)!
        let last=ShanghaiTime.parseDay(items.first { $0.name=="end_date" }!.value!)!
        let end=ShanghaiTime.nextMidnight(after:last)
        let count=Int(end.timeIntervalSince(start)/3600)
        let f=DateFormatter();f.timeZone=ShanghaiTime.zone;f.locale=Locale(identifier:"en_US_POSIX")
        f.dateFormat="yyyy-MM-dd'T'HH:mm"
        let time=(0..<count).map { f.string(from:start.addingTimeInterval(Double($0)*3600)) }
        // Deliberately differs from the local shade formula.
        return try JSONSerialization.data(withJSONObject:["latitude":31,"longitude":120,"timezone":"Asia/Shanghai",
            "hourly_units":["apparent_temperature":unit],
            "hourly":["time":time,"apparent_temperature":Array(repeating:44.4,count:count)]])
    }

    private func fixture(_ handler: @escaping (URLRequest) throws -> (Int,Data)) -> (NetworkApparentTemperature,URL,URLSession) {
        StubWeatherProtocol.lock.lock()
        StubWeatherProtocol.responder=handler;StubWeatherProtocol.count=0
        StubWeatherProtocol.lock.unlock()
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubWeatherProtocol.self]
        let session=URLSession(configuration:config)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (NetworkApparentTemperature(directory:directory,session:session,historyRequestInterval:0),directory,session)
    }

    func testReturnsAPIFieldAndDoesNotCalculateLocalReplacement() async throws {
        let (provider,directory,session)=fixture { request in
            XCTAssertEqual(request.url?.host,"api.open-meteo.com")
            return (200,try self.body(request))
        }
        defer { session.invalidateAndCancel();try? FileManager.default.removeItem(at:directory) }
        let values=try await provider.currentValues(grid:[point],at:ShanghaiTime.parseDay("2026-11-19")!)
        XCTAssertEqual(values,[44.4])
    }

    func testPreparesAndCachesHistoricalAPIFieldWithMatchingDefinition() async throws {
        let (provider,directory,session)=fixture { request in
            XCTAssertEqual(request.url?.host,"archive-api.open-meteo.com")
            return (200,try self.body(request))
        }
        defer { session.invalidateAndCancel();try? FileManager.default.removeItem(at:directory) }
        let date=ShanghaiTime.parseDay("2026-11-19")!
        for ready in 1...3 {
            do {
                _ = try await provider.comparisonYears(grid:[point],years:[2022,2023,2024],around:date,radii:[0])
                XCTFail("Preparation should report incomplete history")
            } catch NetworkThermalError.historyPreparing(let count,let total) {
                XCTAssertEqual(count,ready);XCTAssertEqual(total,3)
            }
        }
        let years=try await provider.comparisonYears(grid:[point],years:[2022,2023,2024],around:date,radii:[0])
        XCTAssertEqual(years.map(\.year),[2022,2023,2024])
        XCTAssertEqual(years[0].anchor,[44.4])
        XCTAssertEqual(StubWeatherProtocol.count,3)
        _ = try await provider.comparisonYears(grid:[point],years:[2022,2023,2024],around:date,radii:[0])
        XCTAssertEqual(StubWeatherProtocol.count,3)
    }

    func testBatchedHistorySuppliesOneElevationPerCoordinate() async throws {
        let grid = [point,
            HistoricalWeatherPoint(id:"p001",latitude:30,longitude:121),
            HistoricalWeatherPoint(id:"p002",latitude:32,longitude:119)]
        let (provider,directory,session)=fixture { request in
            let items=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            let elevation=items.first { $0.name=="elevation" }?.value
            // Match the real API's cardinality rule; scalar nan must fail here.
            guard elevation == "nan,nan,nan" else { return (400,Data()) }
            let template=try JSONSerialization.jsonObject(with:self.body(request)) as! [String:Any]
            let rows=grid.map { point -> [String:Any] in
                var row=template;row["latitude"]=point.latitude;row["longitude"]=point.longitude
                return row
            }
            return (200,try JSONSerialization.data(withJSONObject:rows))
        }
        defer { session.invalidateAndCancel();try? FileManager.default.removeItem(at:directory) }
        let date=ShanghaiTime.parseDay("2026-11-19")!
        for ready in 1...3 {
            do {
                _ = try await provider.comparisonYears(grid:grid,years:[2022,2023,2024],around:date,radii:[0])
                XCTFail("Each request should finish one preparation batch")
            } catch NetworkThermalError.historyPreparing(let count,let total) {
                XCTAssertEqual(count,ready)
                XCTAssertEqual(total,3)
            }
        }
        let years=try await provider.comparisonYears(grid:grid,years:[2022,2023,2024],around:date,radii:[0])
        XCTAssertEqual(years.map(\.year),[2022,2023,2024])
        for year in years {
            XCTAssertEqual(year.anchor,[44.4,44.4,44.4])
        }
    }

    func testRejectsWrongUnitsAndDoesNotFallbackWhenOffline() async throws {
        let (provider,directory,session)=fixture { (200,try self.body($0,unit:"°F")) }
        defer { session.invalidateAndCancel();try? FileManager.default.removeItem(at:directory) }
        do {
            _ = try await provider.currentValues(grid:[point],at:ShanghaiTime.parseDay("2026-11-19")!)
            XCTFail("Wrong units must fail")
        } catch NetworkThermalError.invalidResponse { }
        StubWeatherProtocol.lock.lock()
        StubWeatherProtocol.responder={ _ in throw URLError(.notConnectedToInternet) }
        StubWeatherProtocol.lock.unlock()
        do {
            _ = try await provider.currentValues(grid:[point],at:ShanghaiTime.parseDay("2026-11-19")!)
            XCTFail("Offline must fail, not switch algorithm")
        } catch { XCTAssertTrue(error is URLError) }
    }
}
