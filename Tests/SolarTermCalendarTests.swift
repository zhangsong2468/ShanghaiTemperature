import XCTest
import Foundation
@testable import WeatherCore

final class SolarTermCalendarTests: XCTestCase {
    func testBetweenTermsAndWholeTermDay() {
        let ordinary=SolarTermCalendar.status(at:ShanghaiTime.parseDay("2026-11-19")!)
        XCTAssertEqual(ordinary.label,"立冬—小雪")
        XCTAssertFalse(ordinary.isTermDay)
        XCTAssertTrue(ordinary.usesPublishedCalendar)
        let midnight=ShanghaiTime.parseDay("2026-11-22")!
        for seconds in [0.0,12*3600,24*3600-1] {
            let status=SolarTermCalendar.status(at:midnight.addingTimeInterval(seconds))
            XCTAssertEqual(status.label,"小雪")
            XCTAssertTrue(status.isTermDay)
        }
        XCTAssertEqual(SolarTermCalendar.status(at:ShanghaiTime.parseDay("2026-11-23")!).label,"小雪—大雪")
    }

    func testSpringDayAndYearBoundary() {
        XCTAssertEqual(SolarTermCalendar.status(at:ShanghaiTime.parseDay("2026-02-04")!).label,"立春")
        XCTAssertEqual(SolarTermCalendar.status(at:ShanghaiTime.parseDay("2026-02-05")!).label,"立春—雨水")
        XCTAssertEqual(SolarTermCalendar.status(at:ShanghaiTime.parseDay("2026-12-31")!).label,"冬至—小寒")
        XCTAssertEqual(SolarTermCalendar.status(at:ShanghaiTime.parseDay("2027-01-05")!).label,"小寒")
    }

    func testAllTwentyFourPublishedTermDays() {
        let expected=["小寒","大寒","立春","雨水","惊蛰","春分","清明","谷雨","立夏","小满","芒种","夏至",
                      "小暑","大暑","立秋","处暑","白露","秋分","寒露","霜降","立冬","小雪","大雪","冬至"]
        for year in [2025,2026,2027] {
            let days=SolarTermCalendar.publishedDays[year]!
            XCTAssertEqual(days.count,24)
            for i in 0..<24 {
                let date=ShanghaiTime.calendar.date(from:DateComponents(year:year,month:i/2+1,day:days[i],hour:0))!
                XCTAssertEqual(SolarTermCalendar.status(at:date).label,expected[i])
                XCTAssertEqual(SolarTermCalendar.status(at:date.addingTimeInterval(86399)).label,expected[i])
            }
        }
    }
}
