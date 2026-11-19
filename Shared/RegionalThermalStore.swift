import Foundation

struct ThermalMapDisplay: Sendable {
    let snapshot: ThermalBandSnapshot?
    let date: Date // Display/solar-calendar date; snapshot.date remains data time.
    let message: String
    let isReplay: Bool
    var seasonalMessage: String? = nil
}

struct ThermalMapCacheRecord: Codable, Sendable {
    let schema: Int
    let fetchedAt: Date
    let snapshot: ThermalBandSnapshot
    let anomalyMessage: String
    let seasonalMessage: String?

    func isValid(source: ThermalSource,at date: Date) -> Bool {
        let age=date.timeIntervalSince(fetchedAt),s=snapshot
        guard schema==1,s.source==source,s.algorithmVersion==2,age>=0,age<=ForecastRecord.maximumCacheAge,
              s.date<=fetchedAt,s.date<=date,fetchedAt.timeIntervalSince(s.date)<3600,!s.bands.isEmpty,s.points.count>=2,
              Set(s.points.map(\.id)).count==s.points.count,s.cuts.count+1==s.bands.count,
              zip(s.cuts,s.cuts.dropFirst()).allSatisfy({$0.0<$0.1}),s.cuts.allSatisfy(\.isFinite),
              s.bands.enumerated().allSatisfy({i,b in b.index==i && b.lower.isFinite && b.upper.isFinite &&
                  b.representative.isFinite && b.upper>=b.lower && b.upper-b.lower<=3.00000001}),
              s.points.allSatisfy({$0.apparentTemperature.isFinite && $0.latitude.isFinite && $0.longitude.isFinite &&
                  s.bands.indices.contains($0.bandIndex)}) else { return false }
        return true
    }
    func isFresh(at date: Date) -> Bool {
        date.timeIntervalSince(fetchedAt)<3600 && ShanghaiTime.calendar.isDate(snapshot.date,equalTo:date,toGranularity:.hour)
    }
    func display(at date: Date,reason: String? = nil) -> ThermalMapDisplay {
        let source=snapshot.source == .local ? "本地" : "网络"
        let text=reason.map { "旧缓存 · "+$0 } ?? (isFresh(at:date) ? source+" · "+anomalyMessage : "旧缓存 · "+anomalyMessage)
        return ThermalMapDisplay(snapshot:snapshot,date:date,message:text,isReplay:false,
                                 seasonalMessage:reason == nil && isFresh(at:date) ? seasonalMessage : nil)
    }
}

struct ThermalMapUpdate: Sendable {
    let display: ThermalMapDisplay
    let refreshAfter: Date
    let record: ThermalMapCacheRecord?
    func projected(at date: Date) -> ThermalMapDisplay {
        if let record,record.isValid(source:record.snapshot.source,at:date) { return record.display(at:date) }
        return ThermalMapDisplay(snapshot:nil,date:date,message:record == nil ? display.message : "缓存已过期，等待联网",isReplay:false)
    }
}

actor RegionalThermalStore {
    static let shared=RegionalThermalStore()
    private let directory: URL
    private let network: NetworkApparentTemperature
    private let weather: RegionalCurrentWeather
    private let sourceProvider: @Sendable () -> ThermalSource
    private var archive: HistoricalWeatherArchive?
    private var engine: ThermalComparisonEngine?
    private var records: [ThermalSource:ThermalMapCacheRecord]=[:]
    private var retryAfter: [ThermalSource:Date]=[:]
    private var lastMessage: [ThermalSource:String]=[:]
    private var inFlight: [ThermalSource:Task<ThermalMapUpdate,Never>]=[:]

    init(archive: HistoricalWeatherArchive? = nil,directory: URL? = nil,session: URLSession? = nil,
         sourceProvider: @escaping @Sendable () -> ThermalSource = {ThermalSourceSettings.current}) {
        self.archive=archive
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("ShanghaiTemperature/RegionalMap-v1",isDirectory:true)
        self.network=NetworkApparentTemperature(session:session)
        self.weather=RegionalCurrentWeather(session:session)
        self.sourceProvider=sourceProvider
    }
    private func file(_ source: ThermalSource) -> URL { directory.appendingPathComponent("map-\(source.rawValue).json") }
    private func cached(_ source: ThermalSource,at date: Date) -> ThermalMapCacheRecord? {
        if let record=records[source],record.isValid(source:source,at:date) { return record }
        guard let data=try? Data(contentsOf:file(source)),let record=try? JSONDecoder().decode(ThermalMapCacheRecord.self,from:data),
              record.isValid(source:source,at:date) else { return nil }
        records[source]=record;return record
    }
    private func persist(_ record: ThermalMapCacheRecord) {
        records[record.snapshot.source]=record
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONEncoder().encode(record).write(to:file(record.snapshot.source),options:.atomic)
        } catch { /* A successful network result remains available in memory. */ }
    }
    func load(now: Date = Date()) async -> ThermalMapUpdate {
        let source=sourceProvider()
        if let record=cached(source,at:now),record.isFresh(at:now) {
            return ThermalMapUpdate(display:record.display(at:now),refreshAfter:nextHour(now),record:record)
        }
        if let retry=retryAfter[source],retry>now {
            return failure(source:source,now:now,message:lastMessage[source] ?? "等待重试",retry:retry)
        }
        let task: Task<ThermalMapUpdate,Never>
        if let existing=inFlight[source] { task=existing } else {
            task=Task { await self.perform(source:source,now:now) };inFlight[source]=task
        }
        let result=await task.value
        inFlight[source]=nil
        guard sourceProvider()==source else {
            return ThermalMapUpdate(display:ThermalMapDisplay(snapshot:nil,date:now,message:"体感来源已切换，等待更新",isReplay:false),
                                    refreshAfter:now.addingTimeInterval(60),record:nil)
        }
        return result
    }
    private func nextHour(_ date: Date) -> Date { ShanghaiTime.calendar.dateInterval(of:.hour,for:date)!.end }
    private func failure(source: ThermalSource,now: Date,message: String,retry: Date) -> ThermalMapUpdate {
        let record=cached(source,at:now)
        return ThermalMapUpdate(display:record?.display(at:now,reason:message)
            ?? ThermalMapDisplay(snapshot:nil,date:now,message:message,isReplay:false),refreshAfter:retry,record:record)
    }
    private func perform(source: ThermalSource,now: Date) async -> ThermalMapUpdate {
        do {
            if archive == nil { archive=try HistoricalWeatherArchive.bundled() }
            let archive=self.archive!
            if engine == nil { engine=ThermalComparisonEngine(archive:archive,network:network) }
            let engine=self.engine!,grid=await archive.points()
            let hour=ShanghaiTime.calendar.dateInterval(of:.hour,for:now)!.start
            let comparison: ThermalComparison
            let recent: [DailyThermalMean]
            if source == .local {
                let raw=try await weather.fetch(grid:grid,at:hour)
                comparison=try await engine.compare(current:raw.samples,at:hour,source:.local);recent=raw.recentMeans
            } else {
                comparison=try await engine.compare(at:hour,source:.network)
                recent=try await network.recentRegionalMeans(grid:grid,at:hour)
            }
            let previous=cached(source,at:now)?.snapshot
            let snapshot=try DynamicThermalBands.build(from:comparison,previous:previous)
            let profiles=(try? await engine.seasonalProfiles(at:hour,source:source)) ?? [:]
            let seasonal=ThermalTimingAnalysis.seasonalMessage(observed:recent,profiles:profiles,at:hour)
            let record=ThermalMapCacheRecord(schema:1,fetchedAt:now,snapshot:snapshot,
                anomalyMessage:ThermalTimingAnalysis.anomalyMessage(comparison),seasonalMessage:seasonal)
            persist(record);retryAfter[source]=nil;lastMessage[source]=nil
            return ThermalMapUpdate(display:record.display(at:now),refreshAfter:nextHour(now),record:record)
        } catch {
            let message: String,delay: TimeInterval
            switch error {
            case NetworkThermalError.historyPreparing(let ready,let total):
                message="网络同期数据准备中 \(ready)/\(total)";delay=120
            case NetworkThermalError.rateLimited:
                message="网络限流，稍后重试";delay=1800
            default:
                message="联网更新失败，稍后重试";delay=900
            }
            let retry=now.addingTimeInterval(delay);retryAfter[source]=retry;lastMessage[source]=message
            return failure(source:source,now:now,message:message,retry:retry)
        }
    }
}
