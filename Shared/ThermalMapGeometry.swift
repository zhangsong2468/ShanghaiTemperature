import Foundation

struct ThermalMapGeometry: Decodable, Sendable {
    struct Region: Decodable, Sendable { let name: String; let polygons: [[[[Double]]]] }
    struct Label: Decodable, Sendable { let name: String; let latitude: Double; let longitude: Double }
    let schema: Int
    let regions: [Region]
    let bounds: [Double] // west, south, east, north; WGS84
    let labels: [Label]

    static func bundled(in bundle: Bundle = .main) throws -> ThermalMapGeometry {
        guard let folder = bundle.url(forResource: "ThermalMap", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: folder.appendingPathComponent("geometry.json")))
        guard value.schema == 1, value.bounds.count == 4, !value.labels.isEmpty,
              Set(value.labels.map(\.name)).count == value.labels.count,
              value.labels.allSatisfy({ !$0.name.isEmpty && $0.latitude.isFinite && $0.longitude.isFinite }),
              Set(value.regions.map(\.name)) == Set(["jiangsu","zhejiang","shanghai"]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func contains(longitude x: Double, latitude y: Double) -> Bool {
        func ringContains(_ ring: [[Double]]) -> Bool {
            guard ring.count >= 3 else { return false }
            var inside = false
            for i in ring.indices {
                let a=ring[i],b=ring[(i+1)%ring.count]
                if (a[1]>y) != (b[1]>y), x < a[0]+(y-a[1])*(b[0]-a[0])/(b[1]-a[1]) { inside.toggle() }
            }
            return inside
        }
        return regions.contains { region in region.polygons.contains { polygon in
            guard let outer=polygon.first,ringContains(outer) else { return false }
            return !polygon.dropFirst().contains { ringContains($0) }
        } }
    }
}

enum SolarTermPhase {
    // Meeus-style approximate apparent solar longitude. No fixed month/day
    // seasons. Exact term-time boundary validation remains a release check.
    static func longitude(at date: Date) -> Double {
        let jd=date.timeIntervalSince1970/86400+2440587.5,t=(jd-2451545)/36525
        func sinDegrees(_ degrees: Double) -> Double { sin(degrees * .pi / 180) }
        let l0=280.46646+t*(36000.76983+0.0003032*t)
        let m=357.52911+t*(35999.05029-0.0001537*t)
        let c = (1.914602-t*(0.004817+0.000014*t)) * sinDegrees(m) +
            (0.019993-0.000101*t) * sinDegrees(2*m) + 0.000289 * sinDegrees(3*m)
        let value=l0+c-0.00569-0.00478*sinDegrees(125.04-1934.136*t)
        return (value.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360)
    }
    static func phase(at date: Date) -> Double {
        ((longitude(at:date)-315+360).truncatingRemainder(dividingBy:360))/15
    }
    static func name(at date: Date) -> String {
        let names=["立春","雨水","惊蛰","春分","清明","谷雨","立夏","小满","芒种","夏至","小暑","大暑",
                   "立秋","处暑","白露","秋分","寒露","霜降","立冬","小雪","大雪","冬至","小寒","大寒"]
        return names[min(23,Int(phase(at:date)))]
    }
}
