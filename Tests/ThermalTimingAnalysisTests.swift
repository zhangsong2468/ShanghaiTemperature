import XCTest
import Foundation
@testable import WeatherCore

final class ThermalTimingAnalysisTests: XCTestCase {
    func testStableCoolingShiftAndInsufficientData() {
        let date=ShanghaiTime.parseDay("2026-11-19")!.addingTimeInterval(15*3600)
        let calendar=ShanghaiTime.calendar
        let observed=(-13...0).map { offset in
            DailyThermalMean(date:calendar.date(byAdding:.day,value:offset,to:date)!,apparentTemperature:20-Double(offset+5)*0.2)
        }
        let profile=Dictionary(uniqueKeysWithValues:(-31...31).map {($0,20-Double($0)*0.2)})
        let profiles=Dictionary(uniqueKeysWithValues:(2015...2025).map {($0,profile)})
        XCTAssertEqual(ThermalTimingAnalysis.seasonalMessage(observed:observed,profiles:profiles,at:date),"近期降温较往年提前约5天")
        XCTAssertNil(ThermalTimingAnalysis.seasonalMessage(observed:Array(observed.prefix(5)),profiles:profiles,at:date))
        let flat=observed.map {DailyThermalMean(date:$0.date,apparentTemperature:15)}
        XCTAssertNil(ThermalTimingAnalysis.seasonalMessage(observed:flat,profiles:profiles,at:date))
    }

    func testDifferentHistoricalYearLevelsCanSuppressTimingClaim() {
        let date=ShanghaiTime.parseDay("2026-11-19")!.addingTimeInterval(15*3600)
        let observed=(-13...0).map { offset in
            DailyThermalMean(date:ShanghaiTime.calendar.date(byAdding:.day,value:offset,to:date)!,apparentTemperature:20-Double(offset+2)*0.2)
        }
        let profiles=Dictionary(uniqueKeysWithValues:(0..<11).map { y in
            (2015+y,Dictionary(uniqueKeysWithValues:(-31...31).map {($0,20-Double($0)*0.2+Double(y-5)*2)}))
        })
        XCTAssertNil(ThermalTimingAnalysis.seasonalMessage(observed:observed,profiles:profiles,at:date))
    }
}
