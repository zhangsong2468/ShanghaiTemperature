import Foundation

// Continuous normalised Gaussian-tapered Shepard surface. All samples have
// continuous weights; no abrupt k-nearest-neighbour membership changes occur.
struct ThermalSurface: Sendable {
    private let points: [ThermalBandPoint]
    private let bandwidthSquared: Double

    init?(points: [ThermalBandPoint], neighbourCount: Int) {
        guard points.count >= 2, Set(points.map(\.id)).count == points.count,
              points.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite && $0.apparentTemperature.isFinite }) else { return nil }
        let k=max(1,min(neighbourCount,points.count-1))
        let distances=points.map { point -> Double in
            points.filter { $0.id != point.id }.map { other in
                let dx=(point.longitude-other.longitude)*cos((point.latitude+other.latitude)/2 * .pi/180)
                let dy=point.latitude-other.latitude
                return dx*dx+dy*dy
            }.sorted()[k-1]
        }.sorted()
        let mid=distances.count/2
        let bandwidth=distances.count%2 == 0 ? (distances[mid-1]+distances[mid])/2 : distances[mid]
        guard bandwidth>0 else { return nil }
        self.points=points;self.bandwidthSquared=bandwidth
    }

    func temperature(latitude: Double, longitude: Double) -> Double? {
        guard latitude.isFinite,longitude.isFinite else { return nil }
        let cosine=cos(latitude * .pi/180)
        var numerator=0.0,denominator=0.0
        for point in points {
            let dx=(longitude-point.longitude)*cosine,dy=latitude-point.latitude
            let squared=dx*dx+dy*dy
            let weight=exp(-squared/(2*bandwidthSquared))/max(squared,1e-12)
            numerator+=point.apparentTemperature*weight;denominator+=weight
        }
        guard denominator>0 else { return nil }
        return numerator/denominator
    }
}
