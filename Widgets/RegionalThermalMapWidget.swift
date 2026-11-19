import SwiftUI
import WidgetKit

struct RegionalThermalMapEntry: TimelineEntry {
    let date: Date
    let display: ThermalMapDisplay
}

struct RegionalThermalMapProvider: TimelineProvider {
    private func replay() -> ThermalMapDisplay? {
        guard let folder=Bundle.main.url(forResource:"ThermalMap",withExtension:nil),
              let data=try? Data(contentsOf:folder.appendingPathComponent("replay.json")) else { return nil }
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        guard let snapshot=try? decoder.decode(ThermalBandSnapshot.self,from:data) else { return nil }
        return ThermalMapDisplay(snapshot:snapshot,date:snapshot.date,message:"历史回放",isReplay:true)
    }

    func placeholder(in context: Context) -> RegionalThermalMapEntry {
        let display=replay() ?? waiting()
        return RegionalThermalMapEntry(date:Date(),display:display)
    }
    func getSnapshot(in context: Context,completion: @escaping (RegionalThermalMapEntry) -> Void) {
        if context.isPreview { completion(placeholder(in:context));return }
        Task {
            let update=await RegionalThermalStore.shared.load()
            let now=Date()
            completion(RegionalThermalMapEntry(date:now,display:display(update,at:now)))
        }
    }
    func getTimeline(in context: Context,completion: @escaping (Timeline<RegionalThermalMapEntry>) -> Void) {
        Task {
            let update=await RegionalThermalStore.shared.load()
            let now=Date()
            let nextHour=ShanghaiTime.calendar.dateInterval(of:.hour,for:now)!.end
            var dates=[now]
            dates += (0..<49).map {nextHour.addingTimeInterval(Double($0)*3600)}
            dates += [ShanghaiTime.nextMidnight(after:now)]
            if let record=update.record {
                dates += [record.fetchedAt.addingTimeInterval(ForecastRecord.maximumCacheAge+1)]
            }
            let entries=Array(Set(dates.filter {$0>=now})).sorted().map { date in
                RegionalThermalMapEntry(date:date,display:date==now ? display(update,at:now) : update.projected(at:date))
            }
            completion(Timeline(entries:entries,policy:.after(max(now.addingTimeInterval(60),update.refreshAfter))))
        }
    }

    private func display(_ update: ThermalMapUpdate,at date: Date) -> ThermalMapDisplay {
        if !ShanghaiTime.calendar.isDate(update.display.date,equalTo:date,toGranularity:.hour) {
            return update.projected(at:date)
        }
        return ThermalMapDisplay(snapshot:update.display.snapshot,date:date,message:update.display.message,
            isReplay:false,seasonalMessage:update.display.seasonalMessage)
    }
    private func waiting() -> ThermalMapDisplay {
        ThermalMapDisplay(snapshot:nil,date:Date(),message:"等待地图数据更新",isReplay:false)
    }
}

struct RegionalThermalMapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:"ShanghaiTemperature.RegionalThermalMap",provider:RegionalThermalMapProvider()) { entry in
            ThermalMapView(display:entry.display).containerBackground(for:.widget) { Color.clear }
        }
        .configurationDisplayName(Text(verbatim:"江浙沪 · 体感地图"))
        .description(Text(verbatim:"江浙沪体感温度分布，温度带跨度不超过3°C。"))
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

struct AdditionalTemperatureWidgets: WidgetBundle {
    var body: some Widget {
        HangzhouRollingMonthWidget()
        RegionalThermalMapWidget()
    }
}
