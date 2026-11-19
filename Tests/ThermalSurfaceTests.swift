import XCTest
@testable import WeatherCore

final class ThermalSurfaceTests: XCTestCase {
    private func points(constant: Bool = false) -> [ThermalBandPoint] {
        (0..<9).map { i in ThermalBandPoint(id:"p\(i)",latitude:30+Double(i/3),longitude:119+Double(i%3),
            apparentTemperature:constant ? 12 : Double(i)*2,bandIndex:0) }
    }
    func testContinuousSurfaceDoesNotJumpAcrossNeighbourMembership() throws {
        let surface=try XCTUnwrap(ThermalSurface(points:points(),neighbourCount:4))
        let a=try XCTUnwrap(surface.temperature(latitude:30.5,longitude:119.5-0.000001))
        let b=try XCTUnwrap(surface.temperature(latitude:30.5,longitude:119.5+0.000001))
        XCTAssertLessThan(abs(a-b),0.0001)
    }
    func testConstantAndSampleValuesArePreserved() throws {
        let constant=try XCTUnwrap(ThermalSurface(points:points(constant:true),neighbourCount:4))
        XCTAssertEqual(try XCTUnwrap(constant.temperature(latitude:30.4,longitude:119.7)),12,accuracy:0.00000001)
        let surface=try XCTUnwrap(ThermalSurface(points:points(),neighbourCount:4))
        for p in points() { XCTAssertEqual(try XCTUnwrap(surface.temperature(latitude:p.latitude,longitude:p.longitude)),p.apparentTemperature,accuracy:0.000001) }
    }
    func testPositiveWeightsPreventOvershoot() throws {
        let surface=try XCTUnwrap(ThermalSurface(points:points(),neighbourCount:4))
        for i in 0..<20 {
            let value=try XCTUnwrap(surface.temperature(latitude:30+Double(i)/10,longitude:119.8))
            XCTAssertTrue((0...16).contains(value))
        }
    }
}
