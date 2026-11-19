import Foundation

// Shade apparent temperature (Steadman/BOM form), computed identically for
// historical and current weather. No historical anomaly is added to this value.
enum ShadeApparentTemperature {
    static func calculate(temperature: Double, humidity: Double, wind: Double) throws -> Double {
        guard temperature.isFinite, humidity.isFinite, wind.isFinite,
              (-90...65).contains(temperature), (0...100).contains(humidity), (0...150).contains(wind) else {
            throw ThermalComparisonError.invalidWeather
        }
        let vapourPressure = humidity / 100 * 6.105 * exp(17.27 * temperature / (237.7 + temperature))
        let apparent = temperature + 0.33 * vapourPressure - 0.70 * wind - 4
        guard apparent.isFinite else { throw ThermalComparisonError.invalidWeather }
        return apparent
    }
}

enum ThermalComparisonError: Error {
    case invalidWeather, mismatchedGrid, mismatchedHour, insufficientHistory, invalidWindow
}

struct HistoricalWindowYear: Sendable {
    let year: Int
    let anchor: [Double] // Same date/hour, before window smoothing.
    let valuesByRadius: [Int: [[Double]]] // radius -> point -> hourly AT samples.
}

struct ThermalReferenceYear: Sendable {
    let year: Int
    let apparentTemperatures: [Double]
    var mean: Double { apparentTemperatures.reduce(0, +) / Double(apparentTemperatures.count) }
}

struct ThermalPointComparison: Sendable {
    let point: HistoricalWeatherPoint
    let date: Date
    let apparentTemperature: Double
    let historicalMean: Double
    let historicalYears: [ThermalReferenceYear]
    var anomaly: Double { apparentTemperature - historicalMean }

    // Each year contributes equal probability, independent of sample counts.
    var historicalPercentile: Double {
        historicalYears.map { year in
            year.apparentTemperatures.reduce(0.0) { sum, value in
                sum + (value < apparentTemperature ? 1 : value == apparentTemperature ? 0.5 : 0)
            } / Double(year.apparentTemperatures.count)
        }.reduce(0, +) / Double(historicalYears.count)
    }
}

struct ThermalComparison: Sendable {
    let source: ThermalSource
    let date: Date
    let points: [ThermalPointComparison]
    let historicalYears: [Int]
    let selectedDayRadius: Int
    let validationMeanAbsoluteError: Double
    var regionalAnomaly: Double { points.map(\.anomaly).reduce(0, +) / Double(points.count) }
}

actor ThermalComparisonEngine {
    private let archive: HistoricalWeatherArchive
    private let network: NetworkApparentTemperature
    init(archive: HistoricalWeatherArchive, network: NetworkApparentTemperature = NetworkApparentTemperature()) {
        self.archive = archive
        self.network = network
    }

    func compare(current: [HistoricalWeatherSample]? = nil, at date: Date,
                 source: ThermalSource = ThermalSourceSettings.current) async throws -> ThermalComparison {
        let grid = await archive.points()
        var currentValues: [Double] = []
        if source == .local {
            guard let current, current.count == grid.count,
                  Set(current.map { $0.point.id }).count == grid.count else {
                throw ThermalComparisonError.mismatchedGrid
            }
            let ordered = Dictionary(uniqueKeysWithValues: current.map { ($0.point.id, $0) })
            for point in grid {
                guard let sample = ordered[point.id],
                      abs(sample.point.latitude-point.latitude)<0.000001,
                      abs(sample.point.longitude-point.longitude)<0.000001 else {
                    throw ThermalComparisonError.mismatchedGrid
                }
                guard ShanghaiTime.calendar.isDate(sample.date,equalTo:date,toGranularity:.hour) else {
                    throw ThermalComparisonError.mismatchedHour
                }
                currentValues.append(try ShadeApparentTemperature.calculate(temperature:sample.temperature,
                    humidity:sample.relativeHumidity,wind:sample.windSpeed))
            }
        }
        // Search candidates, not fixed temperature thresholds or activity weights.
        // Select using historical leave-one-year-out error; today's values do not
        // influence the historical reference or the selection of its window.
        let radii = [0, 3, 7, 14, 21]
        let years: [HistoricalWindowYear]
        if source == .local {
            years = try await archive.comparisonYears(around: date, dayRadii: radii)
        } else {
            years = try await network.comparisonYears(grid: grid,
                years: await archive.availableYears(), around: date, radii: radii)
            currentValues = try await network.currentValues(grid: grid, at: date)
        }
        guard years.count >= 3 else { throw ThermalComparisonError.insufficientHistory }
        let selection = try Self.selectWindow(years: years, radii: radii)
        let points = grid.indices.map { index -> ThermalPointComparison in
            let references = years.map { year in
                ThermalReferenceYear(year: year.year,
                    apparentTemperatures: year.valuesByRadius[selection.radius]![index])
            }
            return ThermalPointComparison(point: grid[index], date: date,
                apparentTemperature: currentValues[index],
                historicalMean: references.map(\.mean).reduce(0, +) / Double(references.count),
                historicalYears: references)
        }
        return ThermalComparison(source: source, date: date, points: points,
            historicalYears: years.map(\.year), selectedDayRadius: selection.radius,
            validationMeanAbsoluteError: selection.error)
    }

    // Regional historical curves for the timing comparison only. This does
    // not replace the dynamically selected same-date window used by the map.
    func seasonalProfiles(at date: Date, source: ThermalSource) async throws -> [Int: [Int: Double]] {
        let grid=await archive.points()
        let years: [HistoricalWindowYear]
        if source == .local { years=try await archive.comparisonYears(around:date,dayRadii:[31]) }
        else { years=try await network.comparisonYears(grid:grid,years:await archive.availableYears(),around:date,radii:[31]) }
        let calendar=ShanghaiTime.calendar
        let components=calendar.dateComponents([.month,.day,.hour],from:date)
        var result: [Int: [Int: Double]] = [:]
        for year in years {
            let centre=calendar.date(from:DateComponents(year:year.year,month:components.month,day:components.day,hour:components.hour))!
            // Do not guess a timing shift from leap-day interpolation.
            guard calendar.component(.month,from:centre)==components.month,
                  calendar.component(.day,from:centre)==components.day else { continue }
            let offsets=(-31...31).filter { offset in
                calendar.component(.year,from:calendar.date(byAdding:.day,value:offset,to:centre)!)==year.year
            }
            guard let values=year.valuesByRadius[31],values.count==grid.count,
                  values.allSatisfy({$0.count==offsets.count}) else { continue }
            result[year.year]=Dictionary(uniqueKeysWithValues:offsets.indices.map { index in
                (offsets[index],values.map {$0[index]}.reduce(0,+)/Double(values.count))
            })
        }
        return result
    }

    static func selectWindow(years: [HistoricalWindowYear], radii: [Int]) throws -> (radius: Int, error: Double) {
        guard years.count >= 3, let count = years.first?.anchor.count, count > 0,
              years.allSatisfy({ $0.anchor.count == count }) else { throw ThermalComparisonError.insufficientHistory }
        var best: (radius: Int, error: Double)?
        for radius in radii.sorted() {
            guard years.allSatisfy({ year in
                guard let values = year.valuesByRadius[radius] else { return false }
                return values.count == count && values.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isFinite) }
            }) else { throw ThermalComparisonError.invalidWindow }
            let means = years.map { year in
                year.valuesByRadius[radius]!.map { $0.reduce(0, +) / Double($0.count) }
            }
            var error = 0.0
            for held in years.indices {
                for point in 0..<count {
                    let predicted = means.indices.filter { $0 != held }.map { means[$0][point] }.reduce(0, +)
                        / Double(years.count - 1)
                    error += abs(predicted - years[held].anchor[point])
                }
            }
            error /= Double(years.count * count)
            if best == nil || error < best!.error { best = (radius, error) }
        }
        guard let best else { throw ThermalComparisonError.invalidWindow }
        return best
    }
}
