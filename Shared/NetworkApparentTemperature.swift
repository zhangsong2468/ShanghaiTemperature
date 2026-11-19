import Foundation
import CryptoKit

enum NetworkThermalError: Error {
    case invalidResponse, missingData, historyPreparing(ready: Int, total: Int), rateLimited
}

// API apparent_temperature includes the provider's radiation term. Historical
// and current values are taken from that field; no local AT fallback is hidden.
actor NetworkApparentTemperature {
    private struct Hourly: Codable {
        let time: [String]
        let apparent_temperature: [Double?]
    }
    private struct Response: Codable {
        let latitude: Double
        let longitude: Double
        let timezone: String
        let hourly_units: [String: String]
        let hourly: Hourly
    }
    private let directory: URL
    private let session: URLSession
    private let historyRequestInterval: TimeInterval

    init(directory: URL? = nil, session: URLSession? = nil, historyRequestInterval: TimeInterval = 65) {
        self.historyRequestInterval = max(0, historyRequestInterval)
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShanghaiTemperature/NetworkApparent-v1", isDirectory: true)
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 18
            self.session = URLSession(configuration: config)
        }
    }

    private func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = ShanghaiTime.calendar
        f.timeZone = ShanghaiTime.zone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.isLenient = false
        return f
    }

    private func day(_ date: Date) -> String { String(formatter().string(from: date).prefix(10)) }

    private func validate(_ rows: [Response], grid: [HistoricalWeatherPoint], start: Date, end: Date) throws {
        guard rows.count == grid.count else { throw NetworkThermalError.invalidResponse }
        let hours = Int(end.timeIntervalSince(start) / 3600)
        let f = formatter()
        let times = (0..<hours).map { f.string(from: start.addingTimeInterval(Double($0) * 3600)) }
        for (row, point) in zip(rows, grid) {
            guard row.timezone == "Asia/Shanghai", row.hourly_units["apparent_temperature"] == "°C",
                  abs(row.latitude - point.latitude) < 0.5, abs(row.longitude - point.longitude) < 0.5,
                  row.hourly.time == times, row.hourly.apparent_temperature.count == hours,
                  row.hourly.apparent_temperature.allSatisfy({ value in
                      guard let value else { return false }; return value.isFinite && (-150...150).contains(value)
                  }) else { throw NetworkThermalError.invalidResponse }
        }
    }

    private func request(grid: [HistoricalWeatherPoint], start: Date, end: Date, historical: Bool) -> URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = historical ? "archive-api.open-meteo.com" : "api.open-meteo.com"
        url.path = historical ? "/v1/archive" : "/v1/forecast"
        url.queryItems = [URLQueryItem(name: "latitude", value: grid.map { String($0.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: grid.map { String($0.longitude) }.joined(separator: ",")),
            URLQueryItem(name: "start_date", value: day(start)),
            URLQueryItem(name: "end_date", value: day(end.addingTimeInterval(-1))),
            URLQueryItem(name: "hourly", value: "apparent_temperature"),
            URLQueryItem(name: "timezone", value: "Asia/Shanghai"),
            URLQueryItem(name: "temperature_unit", value: "celsius")]
        if historical {
            url.queryItems? += [URLQueryItem(name: "models", value: "era5"),
                URLQueryItem(name: "cell_selection", value: "nearest"), URLQueryItem(name: "elevation", value: Array(repeating: "nan", count: grid.count).joined(separator: ","))]
        }
        return url.url!
    }

    private func fetch(grid: [HistoricalWeatherPoint], start: Date, end: Date, historical: Bool) async throws -> [Response] {
        let (data, response) = try await session.data(from: request(grid: grid, start: start, end: end, historical: historical))
        guard let response = response as? HTTPURLResponse else { throw NetworkThermalError.invalidResponse }
        if response.statusCode == 429 { throw NetworkThermalError.rateLimited }
        guard (200..<300).contains(response.statusCode), data.count < 30_000_000 else {
            throw NetworkThermalError.invalidResponse
        }
        let decoder = JSONDecoder()
        let rows: [Response]
        if grid.count == 1, let single = try? decoder.decode(Response.self, from: data) { rows = [single] }
        else { rows = try decoder.decode([Response].self, from: data) }
        try validate(rows, grid: grid, start: start, end: end)
        return rows
    }

    private var recentCache: (key: String, hour: Date, values: [Double], means: [DailyThermalMean])?

    func currentValues(grid: [HistoricalWeatherPoint], at date: Date) async throws -> [Double] {
        let hour=ShanghaiTime.calendar.dateInterval(of:.hour,for:date)!.start
        let key=gridKey(grid)
        if let cached=recentCache,cached.key==key,cached.hour==hour { return cached.values }
        let today=ShanghaiTime.calendar.startOfDay(for:date)
        let start=ShanghaiTime.calendar.date(byAdding:.day,value:-13,to:today)!
        let end=ShanghaiTime.nextMidnight(after:date)
        let rows=try await fetch(grid:grid,start:start,end:end,historical:false)
        let currentHour=Int(hour.timeIntervalSince(start)/3600)
        let values=try rows.map { row -> Double in
            guard let value=row.hourly.apparent_temperature[currentHour] else { throw NetworkThermalError.missingData }
            return value
        }
        let timeOfDay=ShanghaiTime.calendar.component(.hour,from:date)
        let means=(0..<14).map { day -> DailyThermalMean in
            let dayDate=ShanghaiTime.calendar.date(byAdding:.day,value:day,to:start)!.addingTimeInterval(Double(timeOfDay)*3600)
            let value=rows.map {$0.hourly.apparent_temperature[day*24+timeOfDay]!}.reduce(0,+)/Double(rows.count)
            return DailyThermalMean(date:dayDate,apparentTemperature:value)
        }
        recentCache=(key,hour,values,means)
        return values
    }

    func recentRegionalMeans(grid: [HistoricalWeatherPoint], at date: Date) async throws -> [DailyThermalMean] {
        _ = try await currentValues(grid:grid,at:date)
        return recentCache!.means
    }

    private struct Cache: Codable {
        let schema: Int
        let gridKey: String
        let start: Date
        let end: Date
        let rows: [Response]
    }
    private struct Usage: Codable {
        var day: String
        var charged: Int
        var lastRequest: Date
    }

    private func gridKey(_ grid: [HistoricalWeatherPoint]) -> String {
        let text = grid.map { "\($0.id):\($0.latitude):\($0.longitude)" }.joined(separator: ";")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func comparisonYears(grid: [HistoricalWeatherPoint], years: [Int], around date: Date,
                         radii: [Int]) async throws -> [HistoricalWindowYear] {
        let calendar = ShanghaiTime.calendar
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard let targetYear = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let largest = radii.max(), (0...31).contains(largest),
              radii.allSatisfy({ (0...31).contains($0) }) else { throw ThermalComparisonError.invalidWindow }
        let eligible = years.filter { $0 < targetYear }.sorted()
        guard eligible.count >= 3 else { throw ThermalComparisonError.insufficientHistory }
        let key = gridKey(grid)
        var caches: [Int: Cache] = [:]
        var centresByYear: [Int: [Date]] = [:]
        var missing: [(Int, Date, Date)] = []
        for year in eligible {
            let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            let last = calendar.date(byAdding: .year, value: 1, to: first)!
            let tentative = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
            let centres: [Date]
            if month == 2 && day == 29 && calendar.component(.month, from: tentative) != 2 {
                centres = [28, 29].map { calendar.date(from: DateComponents(year: year, month: 2, day: $0, hour: hour))! }
            } else { centres = [tentative] }
            centresByYear[year] = centres
            let neededStart = max(first, calendar.startOfDay(for: calendar.date(byAdding: .day, value: -max(31,largest), to: centres.first!)!))
            let neededEnd = min(last, ShanghaiTime.nextMidnight(after: calendar.date(byAdding: .day, value: max(31,largest), to: centres.last!)!))
            let file = directory.appendingPathComponent("\(key)-\(year).json")
            if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Cache.self, from: data),
               cached.schema == 1, cached.gridKey == key, cached.start <= neededStart, cached.end >= neededEnd,
               (try? validate(cached.rows, grid: grid, start: cached.start, end: cached.end)) != nil {
                caches[year] = cached
            } else {
                // Three days of cache margin: re-use all hours and nearby update dates.
                let start = max(first, calendar.date(byAdding: .day, value: -3, to: neededStart)!)
                let end = min(last, calendar.date(byAdding: .day, value: 3, to: neededEnd)!)
                missing.append((year, start, end))
            }
        }
        if let item = missing.first {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let usageFile = directory.appendingPathComponent("usage.json")
            let now = Date()
            let utcDay = String(ISO8601DateFormatter().string(from: now).prefix(10))
            var usage = (try? JSONDecoder().decode(Usage.self, from: Data(contentsOf: usageFile)))
                ?? Usage(day: utcDay, charged: 0, lastRequest: .distantPast)
            if usage.day != utcDay { usage.day = utcDay; usage.charged = 0 }
            let cost = Int(ceil(item.2.timeIntervalSince(item.1) / (14 * 86400))) * grid.count
            guard now.timeIntervalSince(usage.lastRequest) >= historyRequestInterval else {
                throw NetworkThermalError.historyPreparing(ready: caches.count, total: eligible.count)
            }
            guard usage.charged + cost <= 7500 else { throw NetworkThermalError.rateLimited }
            usage.charged += cost; usage.lastRequest = now
            try JSONEncoder().encode(usage).write(to: usageFile, options: .atomic)
            // Warm at most one historical year per invocation/minute. Widget
            // providers later show preparation progress, never a different source.
            let rows = try await fetch(grid: grid, start: item.1, end: item.2, historical: true)
            let cached = Cache(schema: 1, gridKey: key, start: item.1, end: item.2, rows: rows)
            try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent("\(key)-\(item.0).json"), options: .atomic)
            caches[item.0] = cached
            // Even the last warm-up returns progress: defer the current-weather
            // request to the next refresh to avoid a minute-level quota burst.
            throw NetworkThermalError.historyPreparing(ready: caches.count, total: eligible.count)
        }
        return try eligible.map { year in
            guard let cache = caches[year], let centres = centresByYear[year] else { throw NetworkThermalError.missingData }
            func read(_ point: Int, _ sampleDate: Date) throws -> Double {
                let offset = Int(sampleDate.timeIntervalSince(cache.start) / 3600)
                guard cache.rows[point].hourly.apparent_temperature.indices.contains(offset),
                      let value = cache.rows[point].hourly.apparent_temperature[offset] else { throw NetworkThermalError.missingData }
                return value
            }
            let dates = Set(centres.flatMap { centre in
                (-largest...largest).map { calendar.date(byAdding: .day, value: $0, to: centre)! }
            }).filter { calendar.component(.year, from: $0) == year }.sorted()
            var windows: [Int: [[Double]]] = [:]
            for radius in radii {
                let selected = dates.filter { sampleDate in
                    centres.map { abs(calendar.dateComponents([.day], from: $0, to: sampleDate).day!) }.min()! <= radius
                }
                windows[radius] = try grid.indices.map { point in try selected.map { try read(point, $0) } }
            }
            let anchors = try grid.indices.map { point in
                try centres.map { try read(point, $0) }.reduce(0, +) / Double(centres.count)
            }
            return HistoricalWindowYear(year: year, anchor: anchors, valuesByRadius: windows)
        }
    }
}
