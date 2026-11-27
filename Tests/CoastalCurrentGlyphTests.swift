import XCTest
import Foundation
@testable import WeatherCore

final class CoastalCurrentGlyphTests: XCTestCase {
    func testSlowCurrentHasOnlySmallArrowHead() throws {
        let glyph=try XCTUnwrap(CoastalCurrentGlyph(speed:0.1,direction:90))
        XCTAssertNil(glyph.start)
        XCTAssertNil(glyph.control1)
        XCTAssertNil(glyph.control2)
        XCTAssertEqual(glyph.tip.x,0)
        XCTAssertEqual((glyph.left.x+glyph.right.x)/2,-2.2,accuracy:1e-9)
    }

    func testEntireCurveNeverExceedsThreeHeadLengths() throws {
        for direction in stride(from:0.0,through:360.0,by:15) {
            for speed in [0.01,0.15,0.16,0.5,1.0,1.5,4.0] {
                let glyph=try XCTUnwrap(CoastalCurrentGlyph(speed:speed,direction:direction,coastEast:0.2,coastNorth:1))
                if let start=glyph.start,let a=glyph.control1,let b=glyph.control2 {
                    // A Bezier curve cannot exceed the length of its control polygon.
                    let limit=start.distance(to:a)+a.distance(to:b)+b.distance(to:glyph.tip)
                    XCTAssertLessThanOrEqual(limit,3*CoastalCurrentGlyph.headLength+1e-9)
                }
            }
        }
    }

    func testEastAndWestTerminalDirectionsArePreservedWithBentTails() throws {
        for (direction,east) in [(90.0,1.0),(270.0,-1.0)] {
            let glyph=try XCTUnwrap(CoastalCurrentGlyph(speed:1.0,direction:direction,coastEast:0,coastNorth:1))
            let control=try XCTUnwrap(glyph.control2)
            let start=try XCTUnwrap(glyph.start)
            let dx=glyph.tip.x-control.x,dy=glyph.tip.y-control.y,length=hypot(dx,dy)
            XCTAssertEqual(dx/length,east,accuracy:1e-9)
            XCTAssertEqual(dy/length,0,accuracy:1e-9)
            XCTAssertGreaterThan(abs(start.y),0.1)
        }
    }

    func testBadAndStillCurrentsProduceNoGlyph() {
        XCTAssertNil(CoastalCurrentGlyph(speed:0,direction:90))
        XCTAssertNil(CoastalCurrentGlyph(speed:-1,direction:90))
        XCTAssertNil(CoastalCurrentGlyph(speed:.nan,direction:90))
        XCTAssertNil(CoastalCurrentGlyph(speed:1,direction:.nan))
        XCTAssertNil(CoastalCurrentGlyph(speed:1,direction:361))
    }
}
