import Foundation

struct ThermalBand: Codable, Sendable {
    let index: Int
    let lower: Double
    let upper: Double
    let representative: Double
    let pointCount: Int
}

struct ThermalBandPoint: Codable, Identifiable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let apparentTemperature: Double
    let bandIndex: Int
}

struct ThermalBandSnapshot: Codable, Sendable {
    let algorithmVersion: Int
    let source: ThermalSource
    let date: Date
    let bands: [ThermalBand]
    let cuts: [Double]
    let baseCuts: [Double]?
    let points: [ThermalBandPoint]
    let historicalSpatialError: Double
    let selectedNeighbourCount: Int
    let criterionScore: Double
    let retainedPreviousCuts: Bool
}

enum ThermalBandError: Error { case invalidInput, insufficientHistory }

// A penalised quantisation model, not a fixed-degree scale. The historical
// interpolation error sets the useful resolution. This is an engineering
// criterion, not a claim of an exact Gaussian-mixture likelihood/BIC test.
enum DynamicThermalBands {
    private struct Candidate {
        let cuts: [Double]
        let labels: [Int]
        let means: [Double]
        let score: Double
    }

    static func build(from comparison: ThermalComparison,
                      previous: ThermalBandSnapshot? = nil) throws -> ThermalBandSnapshot {
        let points = comparison.points
        guard points.count >= 2, Set(points.map { $0.point.id }).count == points.count,
              points.allSatisfy({ $0.apparentTemperature.isFinite && $0.point.latitude.isFinite && $0.point.longitude.isFinite }) else {
            throw ThermalBandError.invalidInput
        }
        let n = points.count
        let neighbours = points.indices.map { i in
            points.indices.filter { $0 != i }.sorted {
                distance(points[i].point, points[$0].point) < distance(points[i].point, points[$1].point)
            }
        }
        guard neighbours.allSatisfy({ !($0.isEmpty) }),
              points.indices.allSatisfy({ distance(points[$0].point, points[neighbours[$0][0]].point) > 0 }) else {
            throw ThermalBandError.invalidInput
        }
        let resolution = try historicalResolution(points: points, neighbours: neighbours)
        let values = points.map(\.apparentTemperature)
        let partitions = optimalCuts(values: values, maximumBands: min(5, n))
        var best = evaluate(cuts: [], values: values, neighbours: neighbours,
                            neighbourCount: resolution.count, sigma: resolution.sigma)
        for cuts in partitions {
            let candidate = evaluate(cuts: cuts, values: values, neighbours: neighbours,
                                     neighbourCount: resolution.count, sigma: resolution.sigma)
            if candidate.score < best.score { best = candidate }
        }
        var retained = false
        if let previous, previous.algorithmVersion == 2, previous.source == comparison.source,
           Set(previous.points.map(\.id)) == Set(points.map { $0.point.id }),
           previous.points.allSatisfy({ old in
               points.contains { $0.point.id == old.id && $0.point.latitude == old.latitude && $0.point.longitude == old.longitude }
           }), comparison.date > previous.date,
           comparison.date.timeIntervalSince(previous.date) <= 2 * 3600,
           let priorCuts = previous.baseCuts, priorCuts.allSatisfy(\.isFinite), priorCuts.count < 5,
           zip(priorCuts, priorCuts.dropFirst()).allSatisfy({ $0.0 < $0.1 }) {
            let old = evaluate(cuts: priorCuts, values: values, neighbours: neighbours,
                               neighbourCount: resolution.count, sigma: resolution.sigma)
            // Retain only near-ties within one parameter's complexity cost.
            // A meaningful new cold/warm feature can immediately override it.
            if old.means.allSatisfy(\.isFinite), old.score <= best.score + log(Double(n)) {
                best = old; retained = true
            }
        }
        let low = values.min()!, high = values.max()!
        // Display constraint: retain data-driven boundaries, subdivide only
        // oversized intervals. Empty sample bands may still contain interpolated
        // map temperatures, so they remain part of the continuous colour scale.
        let edges = [low] + best.cuts + [high]
        var finalCuts: [Double] = []
        for i in 0..<(edges.count-1) {
            let lower = edges[i], upper = edges[i+1]
            let pieces = max(1,Int(ceil((upper-lower)/3.0)))
            if pieces>1 {
                for piece in 1..<pieces { finalCuts.append(lower+(upper-lower)*Double(piece)/Double(pieces)) }
            }
            if i<edges.count-2 { finalCuts.append(upper) }
        }
        let finalLabels = values.map { value in finalCuts.filter { value >= $0 }.count }
        let bands = (0...finalCuts.count).map { i -> ThermalBand in
            let lower = i == 0 ? low : finalCuts[i-1]
            let upper = i == finalCuts.count ? high : finalCuts[i]
            let members = values.indices.filter { finalLabels[$0] == i }.map { values[$0] }
            return ThermalBand(index: i, lower: lower, upper: upper,
                representative: members.isEmpty ? (lower+upper)/2 : members.reduce(0,+)/Double(members.count),
                pointCount: members.count)
        }
        return ThermalBandSnapshot(algorithmVersion: 2, source: comparison.source, date: comparison.date,
            bands: bands, cuts: finalCuts, baseCuts: best.cuts, points: points.indices.map { i in
                ThermalBandPoint(id: points[i].point.id, latitude: points[i].point.latitude,
                    longitude: points[i].point.longitude, apparentTemperature: values[i], bandIndex: finalLabels[i])
            }, historicalSpatialError: resolution.sigma, selectedNeighbourCount: resolution.count,
            criterionScore: best.score, retainedPreviousCuts: retained)
    }

    private static func distance(_ a: HistoricalWeatherPoint, _ b: HistoricalWeatherPoint) -> Double {
        let dx = (a.longitude-b.longitude) * cos((a.latitude+b.latitude) / 2 * .pi / 180)
        let dy = a.latitude-b.latitude
        return sqrt(dx*dx+dy*dy)
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted(); let mid = s.count/2
        return s.count % 2 == 0 ? (s[mid-1]+s[mid])/2 : s[mid]
    }

    private static func historicalResolution(points: [ThermalPointComparison], neighbours: [[Int]]) throws -> (sigma: Double, count: Int) {
        guard let first = points.first, first.historicalYears.count >= 3 else { throw ThermalBandError.insufficientHistory }
        let ids = first.historicalYears.map(\.year)
        guard Set(ids).count == ids.count, points.allSatisfy({ $0.historicalYears.map(\.year) == ids }) else {
            throw ThermalBandError.insufficientHistory
        }
        for y in ids.indices {
            let count = first.historicalYears[y].apparentTemperatures.count
            guard count > 0, points.allSatisfy({
                $0.historicalYears[y].apparentTemperatures.count == count
                && $0.historicalYears[y].apparentTemperatures.allSatisfy(\.isFinite)
            }) else { throw ThermalBandError.insufficientHistory }
        }
        let choices = Set([3,4,6,8].map { min($0,points.count-1) }).sorted()
        var best: (sigma: Double, count: Int, error: Double)?
        for k in choices {
            var yearlyErrors: [Double] = []
            var yearlyMedians: [Double] = []
            for y in ids.indices {
                var residuals: [Double] = []
                for p in points.indices {
                    let near = Array(neighbours[p].prefix(k))
                    let weights = near.map { 1 / pow(distance(points[p].point,points[$0].point),2) }
                    let weightSum = weights.reduce(0,+)
                    for sample in points[p].historicalYears[y].apparentTemperatures.indices {
                        let prediction = zip(near,weights).map { index,weight in
                            points[index].historicalYears[y].apparentTemperatures[sample]*weight
                        }.reduce(0,+)/weightSum
                        residuals.append(abs(points[p].historicalYears[y].apparentTemperatures[sample]-prediction))
                    }
                }
                yearlyErrors.append(residuals.reduce(0,+)/Double(residuals.count))
                yearlyMedians.append(median(residuals))
            }
            let error = yearlyErrors.reduce(0,+)/Double(yearlyErrors.count)
            // 1.4826 converts median absolute Gaussian residual to a sigma-scale.
            // The tiny floor is numerical only, not a physical Celsius threshold.
            let sigma = max(0.000001,median(yearlyMedians)*1.4826)
            if best == nil || error < best!.error { best = (sigma,k,error) }
        }
        guard let best else { throw ThermalBandError.insufficientHistory }
        return (best.sigma,best.count)
    }

    private static func optimalCuts(values: [Double], maximumBands: Int) -> [[Double]] {
        let sorted = values.sorted(), n = values.count, origin = values.min()!
        var sums = [0.0], squares = [0.0]
        for v in sorted { let x=v-origin;sums.append(sums.last!+x);squares.append(squares.last!+x*x) }
        func cost(_ start: Int,_ end: Int) -> Double {
            let sum=sums[end]-sums[start]
            return max(0,squares[end]-squares[start]-sum*sum/Double(end-start))
        }
        var dp=Array(repeating:Array(repeating:Double.infinity,count:n+1),count:maximumBands+1)
        var back=Array(repeating:Array(repeating:0,count:n+1),count:maximumBands+1)
        dp[0][0]=0
        for k in 1...maximumBands {
            for end in k...n {
                for start in (k-1)..<end {
                    // A boundary must not split equal temperature values.
                    if start>0 && sorted[start-1]==sorted[start] { continue }
                    let candidate=dp[k-1][start]+cost(start,end)
                    if candidate<dp[k][end] { dp[k][end]=candidate;back[k][end]=start }
                }
            }
        }
        var result:[[Double]]=[]
        for k in 1...maximumBands where dp[k][n].isFinite {
            var cuts:[Double]=[],end=n
            if k>1 {
                for level in stride(from:k,through:2,by:-1) {
                    let start=back[level][end]
                    cuts.append((sorted[start-1]+sorted[start])/2);end=start
                }
            }
            result.append(cuts.sorted())
        }
        return result
    }

    private static func evaluate(cuts: [Double],values: [Double],neighbours: [[Int]],neighbourCount: Int,sigma: Double) -> Candidate {
        let labels=values.map { value in cuts.filter { value >= $0 }.count }
        let k=cuts.count+1,n=values.count
        var sums=Array(repeating:0.0,count:k),counts=Array(repeating:0,count:k)
        for i in values.indices { sums[labels[i]]+=values[i];counts[labels[i]]+=1 }
        guard counts.allSatisfy({ $0>0 }) else { return Candidate(cuts:cuts,labels:labels,means:[],score:.infinity) }
        let means=(0..<k).map { sums[$0]/Double(counts[$0]) }
        let sse=values.indices.map { pow(values[$0]-means[labels[$0]],2) }.reduce(0,+)
        let islands=values.indices.filter { i in
            !neighbours[i].prefix(neighbourCount).contains { labels[$0]==labels[i] }
        }.count
        let score=Double(n)*log(max(sse/Double(n),sigma*sigma))+Double(2*k-1+islands)*log(Double(n))
        return Candidate(cuts:cuts,labels:labels,means:means,score:score)
    }
}
