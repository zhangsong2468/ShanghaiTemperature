import SwiftUI
import WidgetKit

struct RegionalThermalMapEntry: TimelineEntry {
    let date: Date
    let display: ThermalMapDisplay
    var aircraftOverlay: AircraftOverlaySnapshot? = nil
    var aircraftCanvasSize: CGSize? = nil
}

private final class AircraftPreparedLayoutCapture {
    var layout: AircraftMapDrawResult?
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
            async let temperature = RegionalThermalStore.shared.load()
            async let aircraft = loadAircraft(size: context.displaySize)
            let (update, loadedOverlay) = await (temperature, aircraft)
            let canvas = Self.canvasSize(widgetSize: context.displaySize)
            let preparedAt = Date()
            let currentDisplay = display(update,at:preparedAt)
            let overlay = await prepareOverlay(
                loadedOverlay, display:currentDisplay,
                canvas:canvas, preparedAt:preparedAt)
            completion(RegionalThermalMapEntry(
                date:preparedAt,display:currentDisplay,
                aircraftOverlay:overlay,aircraftCanvasSize:canvas))
        }
    }
    func getTimeline(in context: Context,completion: @escaping (Timeline<RegionalThermalMapEntry>) -> Void) {
        Task {
            async let temperature = RegionalThermalStore.shared.load()
            async let aircraft = loadAircraft(size: context.displaySize)
            let (update, loadedOverlay) = await (temperature, aircraft)
            let canvas = Self.canvasSize(widgetSize: context.displaySize)
            let preparedAt = Date()
            let overlay = await prepareOverlay(
                loadedOverlay,display:display(update,at:preparedAt),
                canvas:canvas,preparedAt:preparedAt)
            let now=preparedAt
            let nextHour=ShanghaiTime.calendar.dateInterval(of:.hour,for:now)!.end
            var dates=[now]
            dates += (0..<49).map {nextHour.addingTimeInterval(Double($0)*3600)}
            dates += [ShanghaiTime.nextMidnight(after:now)]
            if let record=update.record {
                dates += [record.fetchedAt.addingTimeInterval(ForecastRecord.maximumCacheAge+1)]
            }
            if let overlay {
                // Re-evaluate when fresh positions become stale and when
                // the five-minute fallback expires. Preserve observation times.
                dates += overlay.aircraft.flatMap { item in
                    [item.state.positionAt.addingTimeInterval(120),
                     item.state.positionAt.addingTimeInterval(300)]
                }.filter { $0 > now }
            }
            let entries=Array(Set(dates.filter {$0>=now})).sorted().map { date in
                RegionalThermalMapEntry(
                    date:date,
                    display:date==now ? display(update,at:now) : update.projected(at:date),
                    aircraftOverlay:overlay,
                    aircraftCanvasSize:canvas)
            }
            let refresh = min(
                update.refreshAfter,
                overlay?.refreshAfter ?? update.refreshAfter)
            completion(Timeline(entries:entries,
                policy:.after(max(now.addingTimeInterval(60),refresh))))
        }
    }

    static func canvasSize(widgetSize: CGSize) -> CGSize {
        // Reserve space for padding, title, footer and seasonal text.
        CGSize(width:max(1,widgetSize.width-26),
               height:max(1,widgetSize.height-100))
    }

    @MainActor
    private func prepareOverlay(
        _ overlay: AircraftOverlaySnapshot?,
        display: ThermalMapDisplay,
        canvas: CGSize,
        preparedAt: Date
    ) async -> AircraftOverlaySnapshot? {
        guard var overlay, !display.isReplay,
              canvas.width.isFinite,canvas.height.isFinite,
              canvas.width > 4,canvas.height > 4 else { return overlay }
        let view = ThermalMapView(
            display:display,
            aircraft:overlay.visible(at:preparedAt),
            aircraftMetadata:overlay.metadata,
            aircraftBounds:overlay.bounds,
            previousAircraftLabelPositions:overlay.labelPositions,
            preferredAircraftIDs:overlay.selectedIDs,
            preferredShanghaiAircraftIDs:overlay.shanghaiIDs)

        // SwiftUI supplies GraphicsContext through Canvas.
        // Render synchronously offscreen; persistence occurs only afterward.
        let capture = AircraftPreparedLayoutCapture()
        let content = Canvas { context, size in
            var graphics = context
            capture.layout = view.prepareAircraftLayout(
                context:&graphics,size:size)
        }
        .frame(width:canvas.width,height:canvas.height)
        let renderer = ImageRenderer(content:content)
        renderer.proposedSize = ProposedViewSize(
            width:canvas.width,height:canvas.height)
        renderer.scale = 1
        guard renderer.cgImage != nil,
              let layout = capture.layout else { return overlay }
        overlay = AircraftOverlaySnapshot(
            labelPositions:layout.labelPositions,
            selectedIDs:layout.visibleIDs,
            shanghaiIDs:layout.shanghaiIDs,
            aircraft:overlay.aircraft,
            metadata:overlay.metadata,
            bounds:overlay.bounds,
            refreshAfter:overlay.refreshAfter)
        await AircraftOverlayStore.shared.savePreparedLayout(
            visibleIDs:layout.visibleIDs,
            shanghaiIDs:layout.shanghaiIDs,
            labelPositions:layout.labelPositions,
            preparedAt:preparedAt)
        return overlay
    }

    private func loadAircraft(size: CGSize) async -> AircraftOverlaySnapshot? {
        guard let geometry = try? ThermalMapGeometry.bundled(),
              geometry.bounds.count == 4,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 160 else { return nil }
        let b = geometry.bounds
        guard b.allSatisfy({ $0.isFinite }),
              b[0] < b[2], b[1] < b[3],
              b[1] > -85, b[3] < 85 else { return nil }
        func mercator(_ latitude: Double) -> Double {
            log(tan(.pi / 4 + latitude * .pi / 360))
        }
        func latitude(_ value: Double) -> Double {
            (2 * atan(exp(value)) - .pi / 2) * 180 / .pi
        }
        // Match ThermalMapView's actual Canvas and projection rectangle.
        let canvas = Self.canvasSize(widgetSize: size)
        let width = Double(canvas.width)
        let height = max(1, Double(canvas.height) - 18)
        let west = b[0] * .pi / 180
        let east = b[2] * .pi / 180
        let south = mercator(b[1])
        let north = mercator(b[3])
        let scale = min(width * 0.64 / (east - west),
                        height / (north - south))
        guard scale.isFinite, scale > 0 else { return nil }
        let middleX = (west + east) / 2
        let middleY = (south + north) / 2
        let halfWidth = width / (2 * scale)
        let halfHeight = Double(canvas.height) / (2 * scale)
        let bounds = AircraftBounds(
            west:max(-180,(middleX-halfWidth)*180 / .pi),
            south:max(-85,latitude(middleY-halfHeight)),
            east:min(180,(middleX+halfWidth)*180 / .pi),
            north:min(85,latitude(middleY+halfHeight)))
        guard bounds.isValid else { return nil }
        return await AircraftOverlayStore.shared.load(bounds: bounds)
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
            ThermalMapView(
                display:entry.display,
                preparedCanvasSize:entry.aircraftCanvasSize,
                aircraft:entry.aircraftOverlay?.visible(at:entry.date) ?? [],
                aircraftMetadata:entry.aircraftOverlay?.metadata ?? [:],
                aircraftBounds:entry.aircraftOverlay?.bounds,
                previousAircraftLabelPositions:
                    entry.aircraftOverlay?.labelPositions ?? [:],
                preferredAircraftIDs:entry.aircraftOverlay?.selectedIDs ?? [],
                preferredShanghaiAircraftIDs:entry.aircraftOverlay?.shanghaiIDs ?? []
            ).containerBackground(for:.widget) { Color.clear }
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
