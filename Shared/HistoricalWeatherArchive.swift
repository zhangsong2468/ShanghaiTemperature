import Foundation
import CryptoKit

struct HistoricalWeatherPoint: Decodable, Identifiable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
}

struct HistoricalWeatherSample: Sendable {
    let point: HistoricalWeatherPoint
    let date: Date
    let temperature: Double
    let relativeHumidity: Double
    let windSpeed: Double // m/s at 10 metres, as supplied by ERA5.
}

enum HistoricalArchiveError: Error {
    case missingBundle, invalidIndex, unknownPoint, outsideArchive, invalidFile
}

// Complete source samples, not daily summaries or fitted thresholds. Files are
// mapped lazily and kept within this actor; callers do not scan the whole archive.
actor HistoricalWeatherArchive {
    private struct Year: Decodable {
        let year: Int
        let file: String
        let hours: Int
        let bytes: Int
        let sha256: String
    }
    private struct Index: Decodable {
        let schema: Int
        let model: String
        let timezone: String
        let recordBytes: Int
        let scales: [Int]
        let fields: [String]
        let units: [String]
        let ordering: String
        let points: [HistoricalWeatherPoint]
        let years: [Year]
    }
    private let directory: URL
    private let index: Index
    private var mapped: [Int: Data] = [:]

    init(directory: URL) throws {
        let index = try JSONDecoder().decode(Index.self,
            from: Data(contentsOf: directory.appendingPathComponent("index.json")))
        guard index.schema == 1, index.model == "era5", index.timezone == "Asia/Shanghai",
              index.recordBytes == 6, index.scales == [100, 100, 100],
              index.fields == ["temperature_2m", "relative_humidity_2m", "wind_speed_10m"],
              index.units == ["°C", "%", "m/s"], index.ordering == "point-major/hour-major",
              !index.points.isEmpty, !index.years.isEmpty,
              Set(index.points.map(\.id)).count == index.points.count,
              Set(index.years.map(\.year)).count == index.years.count else {
            throw HistoricalArchiveError.invalidIndex
        }
        for year in index.years {
            guard (1940...2100).contains(year.year), year.file == "\(year.year).bin",
                  let start = ShanghaiTime.calendar.date(from: DateComponents(year: year.year, month: 1, day: 1)),
                  let end = ShanghaiTime.calendar.date(byAdding: .year, value: 1, to: start),
                  year.hours == Int(end.timeIntervalSince(start) / 3600),
                  year.bytes == year.hours * index.points.count * 6,
                  year.sha256.count == 64 else { throw HistoricalArchiveError.invalidIndex }
        }
        self.directory = directory
        self.index = index
    }

    static func bundled(in bundle: Bundle = .main) throws -> HistoricalWeatherArchive {
        guard let url = bundle.url(forResource: "WeatherHistory", withExtension: nil) else {
            throw HistoricalArchiveError.missingBundle
        }
        return try HistoricalWeatherArchive(directory: url)
    }

    func availableYears() -> [Int] { index.years.map(\.year).sorted() }
    func points() -> [HistoricalWeatherPoint] { index.points }

    func sample(pointID: String, at date: Date) throws -> HistoricalWeatherSample {
        guard let point = index.points.firstIndex(where: { $0.id == pointID }) else {
            throw HistoricalArchiveError.unknownPoint
        }
        let (year, hour) = try location(at: date)
        return try decode(point: point, hour: hour, year: year, data: data(for: year), date: date)
    }

    func samples(at date: Date) throws -> [HistoricalWeatherSample] {
        let (year, hour) = try location(at: date)
        let data = try data(for: year)
        return try index.points.indices.map {
            try decode(point: $0, hour: hour, year: year, data: data, date: date)
        }
    }

    // Runtime lookup from the full local archive. Never includes the target
    // year or later years, including during historical replay validation.
    func comparisonYears(around date: Date, dayRadii: [Int]) throws -> [HistoricalWindowYear] {
        guard !dayRadii.isEmpty, dayRadii.allSatisfy({ (0...31).contains($0) }) else {
            throw ThermalComparisonError.invalidWindow
        }
        let calendar = ShanghaiTime.calendar
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard let targetYear = components.year, let month = components.month,
              let day = components.day, let hour = components.hour else {
            throw ThermalComparisonError.mismatchedHour
        }
        var result: [HistoricalWindowYear] = []
        for entry in index.years.sorted(by: { $0.year < $1.year }) where entry.year < targetYear {
            let yearStart = calendar.date(from: DateComponents(year: entry.year, month: 1, day: 1))!
            let tentative = calendar.date(from: DateComponents(year: entry.year, month: month, day: day, hour: hour))!
            var centres: [Date] = []
            if calendar.component(.month, from: tentative) == month,
               calendar.component(.day, from: tentative) == day {
                centres = [tentative]
            } else if month == 2 && day == 29 {
                // Equal average of the neighbouring dates in non-leap years.
                centres = [28, 29].map {
                    calendar.date(from: DateComponents(year: entry.year, month: 2, day: $0, hour: hour))!
                }
            }
            guard !centres.isEmpty else { throw ThermalComparisonError.mismatchedHour }
            let data = try data(for: entry)
            var valuesByRadius: [Int: [[Double]]] = [:]
            let largest = dayRadii.max()!
            let dates = Set(centres.flatMap { centre in
                (-largest...largest).map { calendar.date(byAdding: .day, value: $0, to: centre)! }
            }).filter { calendar.component(.year, from: $0) == entry.year }.sorted()
            for radius in dayRadii { valuesByRadius[radius] = Array(repeating: [], count: index.points.count) }
            for sampleDate in dates {
                let distance = centres.map { abs(calendar.dateComponents([.day], from: $0, to: sampleDate).day!) }.min()!
                let offset = Int(sampleDate.timeIntervalSince(yearStart) / 3600)
                guard (0..<entry.hours).contains(offset) else { throw HistoricalArchiveError.outsideArchive }
                for point in index.points.indices {
                    let sample = try decode(point: point, hour: offset, year: entry, data: data, date: sampleDate)
                    let apparent = try ShadeApparentTemperature.calculate(temperature: sample.temperature,
                        humidity: sample.relativeHumidity, wind: sample.windSpeed)
                    for radius in dayRadii where distance <= radius {
                        valuesByRadius[radius]![point].append(apparent)
                    }
                }
            }
            let anchor = try index.points.indices.map { point -> Double in
                var sum = 0.0
                for centre in centres {
                    let offset = Int(centre.timeIntervalSince(yearStart) / 3600)
                    let sample = try decode(point: point, hour: offset, year: entry, data: data, date: centre)
                    sum += try ShadeApparentTemperature.calculate(temperature: sample.temperature,
                        humidity: sample.relativeHumidity, wind: sample.windSpeed)
                }
                return sum / Double(centres.count)
            }
            result.append(HistoricalWindowYear(year: entry.year, anchor: anchor, valuesByRadius: valuesByRadius))
        }
        return result
    }

    private func location(at date: Date) throws -> (Year, Int) {
        let y = ShanghaiTime.calendar.component(.year, from: date)
        guard let year = index.years.first(where: { $0.year == y }),
              let start = ShanghaiTime.calendar.date(from: DateComponents(year: y, month: 1, day: 1)) else {
            throw HistoricalArchiveError.outsideArchive
        }
        let hour = Int(floor(date.timeIntervalSince(start) / 3600))
        guard (0..<year.hours).contains(hour) else { throw HistoricalArchiveError.outsideArchive }
        return (year, hour)
    }

    private func data(for year: Year) throws -> Data {
        if let cached = mapped[year.year] { return cached }
        let data = try Data(contentsOf: directory.appendingPathComponent(year.file), options: .mappedIfSafe)
        guard data.count == year.bytes else { throw HistoricalArchiveError.invalidFile }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == year.sha256 else { throw HistoricalArchiveError.invalidFile }
        mapped[year.year] = data
        return data
    }

    private func decode(point: Int, hour: Int, year: Year, data: Data, date: Date) throws -> HistoricalWeatherSample {
        let offset = (point * year.hours + hour) * 6
        guard offset >= 0, offset <= data.count - 6 else { throw HistoricalArchiveError.invalidFile }
        func word(_ delta: Int) -> UInt16 {
            UInt16(data[offset + delta]) | (UInt16(data[offset + delta + 1]) << 8)
        }
        let temperature = Double(Int16(bitPattern: word(0))) / 100
        let humidity = Double(word(2)) / 100
        let wind = Double(word(4)) / 100
        guard (-90...65).contains(temperature), (0...100).contains(humidity),
              (0...150).contains(wind) else { throw HistoricalArchiveError.invalidFile }
        let hourDate = ShanghaiTime.calendar.dateInterval(of: .hour, for: date)!.start
        return HistoricalWeatherSample(point: index.points[point], date: hourDate,
            temperature: temperature, relativeHumidity: humidity, windSpeed: wind)
    }
}
