import Foundation

struct RegionalWeatherResult: Sendable {
    let samples: [HistoricalWeatherSample]
    let recentMeans: [DailyThermalMean]
}

actor RegionalCurrentWeather {
    private struct Row: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let relative_humidity_2m: [Double?]
            let wind_speed_10m: [Double?]
        }
        let latitude: Double
        let longitude: Double
        let timezone: String
        let hourly_units: [String:String]
        let hourly: Hourly
    }
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session=session } else {
            let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=12;c.timeoutIntervalForResource=18
            self.session=URLSession(configuration:c)
        }
    }
    func fetch(grid: [HistoricalWeatherPoint],at date: Date) async throws -> RegionalWeatherResult {
        let calendar=ShanghaiTime.calendar,today=calendar.startOfDay(for:date)
        let start=calendar.date(byAdding:.day,value:-13,to:today)!
        let hour=calendar.component(.hour,from:date)
        let formatter=DateFormatter();formatter.timeZone=ShanghaiTime.zone;formatter.calendar=calendar
        formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM-dd"
        var url=URLComponents();url.scheme="https";url.host="api.open-meteo.com";url.path="/v1/forecast"
        url.queryItems=[URLQueryItem(name:"latitude",value:grid.map {String($0.latitude)}.joined(separator:",")),
            URLQueryItem(name:"longitude",value:grid.map {String($0.longitude)}.joined(separator:",")),
            URLQueryItem(name:"hourly",value:"temperature_2m,relative_humidity_2m,wind_speed_10m"),
            URLQueryItem(name:"start_date",value:formatter.string(from:start)),URLQueryItem(name:"end_date",value:formatter.string(from:today)),
            URLQueryItem(name:"timezone",value:"Asia/Shanghai"),URLQueryItem(name:"temperature_unit",value:"celsius"),
            URLQueryItem(name:"wind_speed_unit",value:"ms")]
        let (data,response)=try await session.data(from:url.url!)
        guard let http=response as? HTTPURLResponse else { throw NetworkThermalError.invalidResponse }
        if http.statusCode==429 { throw NetworkThermalError.rateLimited }
        guard (200..<300).contains(http.statusCode),data.count<30_000_000 else { throw NetworkThermalError.invalidResponse }
        let decoder=JSONDecoder(),rows:[Row]
        if grid.count==1,let row=try? decoder.decode(Row.self,from:data) { rows=[row] }
        else { rows=try decoder.decode([Row].self,from:data) }
        guard rows.count==grid.count else { throw NetworkThermalError.invalidResponse }
        formatter.dateFormat="yyyy-MM-dd'T'HH:mm"
        let expected=(0..<(14*24)).map {formatter.string(from:start.addingTimeInterval(Double($0)*3600))}
        for (point,row) in zip(grid,rows) {
            guard row.timezone=="Asia/Shanghai",row.hourly_units["temperature_2m"]=="°C",
                  row.hourly_units["relative_humidity_2m"]=="%",row.hourly_units["wind_speed_10m"]=="m/s",
                  abs(row.latitude-point.latitude)<0.5,abs(row.longitude-point.longitude)<0.5,
                  row.hourly.time==expected,row.hourly.temperature_2m.count==expected.count,
                  row.hourly.relative_humidity_2m.count==expected.count,row.hourly.wind_speed_10m.count==expected.count else {
                throw NetworkThermalError.invalidResponse
            }
        }
        func sample(_ point: Int,_ day: Int) throws -> HistoricalWeatherSample {
            let row=rows[point],i=day*24+hour
            guard let t=row.hourly.temperature_2m[i],let h=row.hourly.relative_humidity_2m[i],let w=row.hourly.wind_speed_10m[i] else {
                throw NetworkThermalError.missingData
            }
            _ = try ShadeApparentTemperature.calculate(temperature:t,humidity:h,wind:w)
            return HistoricalWeatherSample(point:grid[point],date:start.addingTimeInterval(Double(i)*3600),temperature:t,relativeHumidity:h,windSpeed:w)
        }
        let current=try grid.indices.map {try sample($0,13)}
        let means=try (0..<14).map { day -> DailyThermalMean in
            let values=try grid.indices.map { p -> Double in
                let s=try sample(p,day)
                return try ShadeApparentTemperature.calculate(temperature:s.temperature,humidity:s.relativeHumidity,wind:s.windSpeed)
            }
            return DailyThermalMean(date:start.addingTimeInterval(Double(day*24+hour)*3600),apparentTemperature:values.reduce(0,+)/Double(values.count))
        }
        return RegionalWeatherResult(samples:current,recentMeans:means)
    }
}
