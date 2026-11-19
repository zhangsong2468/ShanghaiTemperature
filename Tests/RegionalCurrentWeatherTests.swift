import XCTest
import Foundation
@testable import WeatherCore

final class RegionalCurrentWeatherTests: XCTestCase {
    func testFourteenDayHourlyInputsAndSameHourRegionalMeans() async throws {
        let date=ShanghaiTime.parseDay("2026-11-19")!.addingTimeInterval(15*3600)
        let start=ShanghaiTime.calendar.date(byAdding:.day,value:-13,to:ShanghaiTime.calendar.startOfDay(for:date))!
        let formatter=DateFormatter();formatter.timeZone=ShanghaiTime.zone;formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.dateFormat="yyyy-MM-dd'T'HH:mm"
        let times=(0..<336).map {formatter.string(from:start.addingTimeInterval(Double($0)*3600))}
        let row:[String:Any]=["latitude":31,"longitude":120,"timezone":"Asia/Shanghai",
            "hourly_units":["temperature_2m":"°C","relative_humidity_2m":"%","wind_speed_10m":"m/s"],
            "hourly":["time":times,"temperature_2m":Array(repeating:25,count:336),
                      "relative_humidity_2m":Array(repeating:50,count:336),"wind_speed_10m":Array(repeating:2,count:336)]]
        let data=try JSONSerialization.data(withJSONObject:row)
        StubWeatherProtocol.lock.lock()
        StubWeatherProtocol.responder={ request in
            let items=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            XCTAssertEqual(items.first {$0.name=="wind_speed_unit"}?.value,"ms")
            return (200,data)
        }
        StubWeatherProtocol.lock.unlock()
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubWeatherProtocol.self]
        let session=URLSession(configuration:config)
        defer {session.invalidateAndCancel()}
        let client=RegionalCurrentWeather(session:session)
        let result=try await client.fetch(grid:[HistoricalWeatherPoint(id:"p000",latitude:31,longitude:120)],at:date)
        XCTAssertEqual(result.samples.count,1)
        XCTAssertEqual(result.samples[0].date,date)
        XCTAssertEqual(result.recentMeans.count,14)
        XCTAssertEqual(result.recentMeans.last?.date,date)
        XCTAssertEqual(result.recentMeans.last!.apparentTemperature,24.81118881589751,accuracy:0.000001)
    }
}
