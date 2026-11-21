import SwiftUI
import CoreGraphics
import CryptoKit

private struct MapProjection {
    let bounds: [Double]
    let rect: CGRect
    init(bounds: [Double], rect: CGRect) {
        self.bounds = bounds
        let west = bounds[0] * Double.pi / 180, east = bounds[2] * Double.pi / 180
        let south = log(tan(Double.pi / 4 + bounds[1] * Double.pi / 360))
        let north = log(tan(Double.pi / 4 + bounds[3] * Double.pi / 360))
        let scale = min(rect.width / CGFloat(east-west), rect.height / CGFloat(north-south))
        let width = CGFloat(east-west) * scale, height = CGFloat(north-south) * scale
        self.rect = CGRect(x:rect.midX-width/2, y:rect.midY-height/2, width:width, height:height)
    }
    private func mercator(_ latitude: Double) -> Double { log(tan(.pi/4+latitude * .pi/360)) }
    func point(longitude: Double, latitude: Double) -> CGPoint {
        let west=bounds[0] * .pi/180,east=bounds[2] * .pi/180
        let south=mercator(bounds[1]),north=mercator(bounds[3])
        return CGPoint(x:rect.minX+CGFloat((longitude * .pi/180-west)/(east-west))*rect.width,
                       y:rect.minY+CGFloat((north-mercator(latitude))/(north-south))*rect.height)
    }
    func coordinate(x: Double, y: Double) -> (longitude: Double,latitude: Double) {
        let north=mercator(bounds[3]),south=mercator(bounds[1])
        return (bounds[0]+x*(bounds[2]-bounds[0]),(2 * atan(exp(north-y*(north-south))) - Double.pi / 2) * 180 / Double.pi)
    }
    func path(_ regions: [ThermalMapGeometry.Region]) -> Path {
        var path=Path()
        for region in regions { for polygon in region.polygons { for ring in polygon {
            guard let first=ring.first else { continue }
            path.move(to:point(longitude:first[0],latitude:first[1]))
            for vertex in ring.dropFirst() { path.addLine(to:point(longitude:vertex[0],latitude:vertex[1])) }
            path.closeSubpath()
        } } }
        return path
    }
}

private enum ThermalMapColour {
    static func components(_ temperature: Double, date: Date) -> (Double,Double,Double) {
        // The same absolute apparent temperature sets the principal hue.
        // Solar-term phase gently adjusts seasonal saturation, never normalises
        // a heatwave into a "cool" colour because summer is normally hot.
        let stops:[(Double,Double,Double,Double)]=[
            (-15,0.18,0.30,0.61),(0,0.25,0.48,0.76),(10,0.52,0.76,0.87),
            (20,0.94,0.82,0.53),(30,0.91,0.44,0.24),(40,0.69,0.13,0.16),(55,0.46,0.06,0.16)]
        let t=min(55,max(-15,temperature))
        let i=(0..<stops.count-1).first { t<=stops[$0+1].0 } ?? stops.count-2
        let a=stops[i],b=stops[i+1],f=(t-a.0)/(b.0-a.0)
        var rgb=(a.1+(b.1-a.1)*f,a.2+(b.2-a.2)*f,a.3+(b.3-a.3)*f)
        let phase=SolarTermPhase.phase(at:date) * .pi/12
        let warmth=0.025*cos(phase - Double.pi / 2) // continuous through all 24 terms
        if temperature>0 && temperature<30 { rgb.0=min(1,max(0,rgb.0+warmth));rgb.2=min(1,max(0,rgb.2-warmth)) }
        return rgb
    }
    static func colour(_ temperature: Double,date: Date) -> Color {
        let c=components(temperature,date:date);return Color(red:c.0,green:c.1,blue:c.2)
    }
}

private struct ThermalMapRasterResult {
    let image: CGImage
    let edgeAnchors: [Int: [CGPoint]] // Largest visible connected part of each band.
    let interiorAnchors: [Int: [CGPoint]]
    let bandField: [Int]
    let width: Int
    let height: Int

    func band(at point: CGPoint, in rect: CGRect) -> Int {
        guard rect.contains(point),rect.width>0,rect.height>0 else { return -1 }
        let x=min(width-1,max(0,Int((point.x-rect.minX)/rect.width*CGFloat(width))))
        let y=min(height-1,max(0,Int((point.y-rect.minY)/rect.height*CGFloat(height))))
        return bandField[y*width+x]
    }
}

private final class ThermalMapRasterBox: NSObject {
    let value: ThermalMapRasterResult
    init(_ value: ThermalMapRasterResult) { self.value=value }
}

private enum ThermalMapRaster {
    private static let cache: NSCache<NSString,ThermalMapRasterBox> = {
        let value=NSCache<NSString,ThermalMapRasterBox>();value.countLimit=3;value.totalCostLimit=2_000_000;return value
    }()
    static func image(snapshot: ThermalBandSnapshot, geometry: ThermalMapGeometry) -> ThermalMapRasterResult? {
        guard !snapshot.points.isEmpty,!snapshot.bands.isEmpty,
              let encoded=try? JSONEncoder().encode(snapshot) else { return nil }
        let key=(SHA256.hash(data:encoded).map {String(format:"%02x",$0)}.joined()+geometry.bounds.description) as NSString
        if let existing=cache.object(forKey:key) { return existing.value }
        let width=320,height=448
        let projection=MapProjection(bounds:geometry.bounds,rect:CGRect(x:0,y:0,width:320,height:448))
        let outline=projection.path(geometry.regions)
        guard let surface=ThermalSurface(points:snapshot.points,neighbourCount:snapshot.selectedNeighbourCount) else { return nil }
        let colours=snapshot.bands.map { ThermalMapColour.components($0.representative,date:snapshot.date) }
        var field=[Double](repeating:.nan,count:width*height)
        var bandField=[Int](repeating:-1,count:width*height)
        var pixels=[UInt8](repeating:0,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let p=projection.coordinate(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height))
            guard outline.contains(projection.point(longitude:p.longitude,latitude:p.latitude),eoFill:true),
                  let temperature=surface.temperature(latitude:p.latitude,longitude:p.longitude) else { continue }
            field[y*width+x]=temperature
        } }
        for y in 0..<height { for x in 0..<width {
            let temperature=field[y*width+x]
            guard temperature.isFinite else { continue }
            let band=min(snapshot.cuts.filter { temperature >= $0 }.count,snapshot.bands.count-1)
            bandField[y*width+x]=band
            func neighbour(_ dx: Int,_ dy: Int) -> Double {
                let xx=min(width-1,max(0,x+dx)),yy=min(height-1,max(0,y+dy)),value=field[yy*width+xx]
                return value.isFinite ? value : temperature
            }
            let gradient=hypot((neighbour(1,0)-neighbour(-1,0))/2,(neighbour(0,1)-neighbour(0,-1))/2)
            var c=colours[band]
            // A narrow, gradient-aware visual transition (about 1.5 raster
            // pixels in total), not a different physical temperature interval.
            if let edge=snapshot.cuts.indices.min(by:{ abs(temperature-snapshot.cuts[$0]) < abs(temperature-snapshot.cuts[$1]) }) {
                let limit=min(snapshot.bands[edge].upper-snapshot.bands[edge].lower,
                              snapshot.bands[edge+1].upper-snapshot.bands[edge+1].lower)*0.15
                let feather=min(gradient*0.75,limit)
                if feather>0,abs(temperature-snapshot.cuts[edge])<feather {
                    let t=min(1,max(0,(temperature-snapshot.cuts[edge]+feather)/(2*feather)))
                    let f=t*t*(3-2*t),a=colours[edge],b=colours[edge+1]
                    c=(a.0+(b.0-a.0)*f,a.1+(b.1-a.1)*f,a.2+(b.2-a.2)*f)
                }
            }
            let offset=(y*width+x)*4
            pixels[offset]=UInt8((c.0*255).rounded());pixels[offset+1]=UInt8((c.1*255).rounded())
            pixels[offset+2]=UInt8((c.2*255).rounded());pixels[offset+3]=255
        } }
        guard let provider=CGDataProvider(data:Data(pixels) as CFData) else { return nil }
        guard let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
            provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return nil }
        // Work from connected rendered areas, never from a remote sample or
        // one extreme eastern pixel. Tiny disconnected islands do not attract labels.
        var visited=[Bool](repeating:false,count:width*height)
        var largest: [Int:[Int]] = [:]
        for seed in bandField.indices where bandField[seed]>=0 && !visited[seed] {
            let band=bandField[seed]
            var queue=[seed],head=0;visited[seed]=true
            while head<queue.count {
                let i=queue[head];head+=1
                let x=i%width,y=i/width
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let xx=x+dx,yy=y+dy
                    guard xx>=0,xx<width,yy>=0,yy<height else { continue }
                    let next=yy*width+xx
                    if !visited[next],bandField[next]==band { visited[next]=true;queue.append(next) }
                }
            }
            if queue.count > (largest[band]?.count ?? 0) { largest[band]=queue }
        }
        var edges: [Int:[CGPoint]] = [:],interiors: [Int:[CGPoint]] = [:]
        func unit(_ i: Int) -> CGPoint {
            CGPoint(x:(Double(i%width)+0.5)/Double(width),y:(Double(i/width)+0.5)/Double(height))
        }
        for (band,component) in largest {
            var boundary=[Int](),inside=[Int]()
            for i in component.sorted() {
                let x=i%width,y=i/width
                let isEdge=x==0 || x==width-1 || y==0 || y==height-1 ||
                    bandField[i-1] != band || bandField[i+1] != band ||
                    bandField[i-width] != band || bandField[i+width] != band
                if isEdge { boundary.append(i) }
                else if x%8==0,y%8==0 { inside.append(i) }
            }
            let step=max(1,(boundary.count+159)/160)
            edges[band]=stride(from:0,to:boundary.count,by:step).map { unit(boundary[$0]) }
            let innerStep=max(1,(inside.count+95)/96)
            interiors[band]=stride(from:0,to:inside.count,by:innerStep).map { unit(inside[$0]) }
        }
        let result=ThermalMapRasterResult(image:image,edgeAnchors:edges,interiorAnchors:interiors,
            bandField:bandField,width:width,height:height)
        cache.setObject(ThermalMapRasterBox(result),forKey:key,cost:width*height*4)
        return result
    }
}

struct ThermalMapView: View {
    let display: ThermalMapDisplay
    var preparedCanvasSize: CGSize? = nil
    let aircraft: [TrackedAircraft]
    let aircraftMetadata: [String: AircraftMetadata]
    let aircraftBounds: AircraftBounds?
    let previousAircraftLabelPositions: [String: Int]
    let preferredAircraftIDs: Set<String>
    let preferredShanghaiAircraftIDs: Set<String>
    private let geometry: ThermalMapGeometry?
    private let raster: ThermalMapRasterResult?
    init(display: ThermalMapDisplay,
         preparedCanvasSize: CGSize? = nil,
         aircraft: [TrackedAircraft] = [],
         aircraftMetadata: [String: AircraftMetadata] = [:],
         aircraftBounds: AircraftBounds? = nil,
         previousAircraftLabelPositions: [String: Int] = [:],
         preferredAircraftIDs: Set<String> = [],
         preferredShanghaiAircraftIDs: Set<String> = []) {
        self.display=display
        self.preparedCanvasSize=preparedCanvasSize
        self.aircraft=aircraft
        self.aircraftMetadata=aircraftMetadata
        self.aircraftBounds=aircraftBounds
        self.previousAircraftLabelPositions=previousAircraftLabelPositions
        self.preferredAircraftIDs=preferredAircraftIDs
        self.preferredShanghaiAircraftIDs=preferredShanghaiAircraftIDs
        let geometry=try? ThermalMapGeometry.bundled()
        self.geometry=geometry
        self.raster=display.snapshot.flatMap { snapshot in geometry.flatMap { ThermalMapRaster.image(snapshot:snapshot,geometry:$0) } }
    }

    private var mapFailureMessage: String {
        if geometry == nil { return "地图资源读取失败" }
        if display.snapshot == nil { return display.message }
        return "地图图像生成失败"
    }

    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text("江浙沪 · 体感温度").fontWeight(.medium)
                Spacer(minLength:2)
                Text(SolarTermCalendar.status(at:display.date).label).foregroundStyle(.secondary)
            }.font(.system(size:12))
            if let geometry,let snapshot=display.snapshot,let raster {
                Canvas { context,size in
                    _ = draw(context:&context,size:size,
                        geometry:geometry,snapshot:snapshot,raster:raster)
                }
                    .frame(
                        width: preparedCanvasSize?.width,
                        height: preparedCanvasSize?.height)
                    .accessibilityLabel("江浙沪体感温度地图，\(snapshot.bands.count)条温度带，摄氏度。\(display.message)")
            } else {
                VStack(spacing:8) {
                    Image(systemName:"map").font(.system(size:26,weight:.light))
                    Text(mapFailureMessage).font(.system(size:11)).multilineTextAlignment(.center)
                }.foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            HStack {
                Text(display.isReplay ? "历史回放 · 非实时" : display.message)
                Spacer(minLength:2)
                Text(ShanghaiTime.timestamp(display.snapshot?.date ?? display.date))
            }.font(.system(size:8)).foregroundStyle(.secondary)
            if let seasonal=display.seasonalMessage {
                Text(seasonal).font(.system(size:9)).foregroundStyle(.secondary)
            }
        }.padding(13)
    }

    // Returns the same aircraft layout that is used for drawing.
    // Preparation callers supply a disposable graphics context.
    func prepareAircraftLayout(
        context: inout GraphicsContext,
        size: CGSize
    ) -> AircraftMapDrawResult? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 4, size.height > 4,
              let geometry, let snapshot=display.snapshot,
              let raster else { return nil }
        return draw(context:&context,size:size,geometry:geometry,
            snapshot:snapshot,raster:raster,renderAircraft:false)
    }

    private func draw(context: inout GraphicsContext,size: CGSize,geometry: ThermalMapGeometry,
                      snapshot: ThermalBandSnapshot,raster: ThermalMapRasterResult,
                      renderAircraft: Bool = true) -> AircraftMapDrawResult? {
        let projection=MapProjection(bounds:geometry.bounds,
            rect:CGRect(x:size.width*0.18,y:9,width:size.width*0.64,height:max(1,size.height-18)))
        let outline=projection.path(geometry.regions)
        var clipped=context
        clipped.clip(to:outline,style:FillStyle(eoFill:true))
        clipped.draw(Image(decorative:raster.image,scale:1).interpolation(.high),in:projection.rect)
        context.stroke(outline,with:.color(.primary.opacity(0.55)),lineWidth:0.55)
        // Range labels choose nearby space on every side before place names.
        var aircraftLeaderObstacles = [CGRect]()
        var occupied=drawRanges(
            context:&context,size:size,projection:projection,
            snapshot:snapshot,raster:raster,
            aircraftLeaderObstacles:&aircraftLeaderObstacles)
        for label in geometry.labels {
            let anchor=projection.point(longitude:label.longitude,latitude:label.latitude)
            let text=context.resolve(Text(verbatim:label.name).font(.system(size:8.5,weight:.medium)).foregroundColor(.primary))
            let textSize=text.measure(in:CGSize(width:80,height:15))
            let offsets:[CGPoint]=[CGPoint(x:4,y:-12),CGPoint(x:4,y:3),CGPoint(x:-textSize.width-4,y:-12),
                CGPoint(x:-textSize.width-4,y:3),CGPoint(x:4,y:-24),CGPoint(x:-textSize.width-4,y:15),
                CGPoint(x:4,y:15),CGPoint(x:-textSize.width-4,y:-24)]
            let candidates=offsets.map { delta in CGRect(x:min(max(0,anchor.x+delta.x),max(0,size.width-textSize.width)),
                y:min(max(0,anchor.y+delta.y),max(0,size.height-textSize.height)),width:textSize.width,height:textSize.height) }
            let rect=candidates.first { candidate in !occupied.contains { $0.intersects(candidate.insetBy(dx:-2,dy:-2)) } } ?? candidates[0]
            occupied.append(rect)
            var leader=Path();leader.move(to:anchor);leader.addLine(to:CGPoint(x:rect.midX,y:rect.midY))
            context.stroke(leader,with:.color(.primary.opacity(0.35)),lineWidth:0.4)
            aircraftLeaderObstacles += Self.aircraftLineObstacles(
                from:anchor,to:CGPoint(x:rect.midX,y:rect.midY))
            var halo=context;halo.addFilter(.shadow(color:Color(nsColor:.windowBackgroundColor).opacity(0.9),radius:1))
            halo.draw(text,at:CGPoint(x:rect.minX,y:rect.minY),anchor:.topLeading)
        }
        if !display.isReplay, let aircraftBounds {
            let layout = AircraftMapLayer.layout(
                context:context,
                canvas:CGRect(origin:.zero,size:size),
                aircraft:aircraft,
                metadata:aircraftMetadata,
                reserved:occupied + aircraftLeaderObstacles,
                previousLabelPositions:previousAircraftLabelPositions,
                preferredIDs:preferredAircraftIDs,
                preferredShanghaiIDs:preferredShanghaiAircraftIDs,
                now:display.date,
                bounds:aircraftBounds,
                project: { longitude,latitude in
                    projection.point(longitude:longitude,latitude:latitude)
                })
            if renderAircraft {
                AircraftMapLayer.render(layout,context:&context)
            }
            return layout
        }
        return nil
    }

    private static func aircraftLineObstacles(
        from a: CGPoint, to b: CGPoint
    ) -> [CGRect] {
        let length=hypot(b.x-a.x,b.y-a.y)
        let count=max(1,Int(ceil(length/2)))
        return (0...count).map { index in
            let fraction=CGFloat(index)/CGFloat(count)
            return CGRect(
                x:a.x+(b.x-a.x)*fraction-1,
                y:a.y+(b.y-a.y)*fraction-1,
                width:2,height:2)
        }
    }

    private struct RangeCandidate {
        let rect: CGRect
        let anchor: CGPoint
        let attachment: CGPoint
        let score: CGFloat
        let inside: Bool
    }

    private func drawRanges(context: inout GraphicsContext,size: CGSize,projection: MapProjection,
                            snapshot: ThermalBandSnapshot,raster: ThermalMapRasterResult,
                            aircraftLeaderObstacles: inout [CGRect]) -> [CGRect] {
        let canvas=CGRect(origin:.zero,size:size).insetBy(dx:2,dy:2)
        func project(_ unit: CGPoint) -> CGPoint {
            CGPoint(x:projection.rect.minX+unit.x*projection.rect.width,
                    y:projection.rect.minY+unit.y*projection.rect.height)
        }
        func attachment(_ p: CGPoint,_ rect: CGRect) -> CGPoint {
            CGPoint(x:min(rect.maxX,max(rect.minX,p.x)),y:min(rect.maxY,max(rect.minY,p.y)))
        }
        var candidates: [Int:[RangeCandidate]] = [:]
        var texts: [Int:GraphicsContext.ResolvedText] = [:]
        for band in snapshot.bands {
            let text=context.resolve(Text(verbatim:String(format:"%.1f–%.1f°",band.lower,band.upper))
                .font(.system(size:8,weight:.medium)).foregroundColor(.primary))
            texts[band.index]=text
            let measured=text.measure(in:CGSize(width:100,height:16))
            let box=CGSize(width:ceil(measured.width)+4,height:ceil(measured.height)+2)
            var choices=[RangeCandidate]()
            func add(_ rect: CGRect,_ anchor: CGPoint) {
                guard canvas.contains(rect) else { return }
                // Text may sit outside the map or completely inside its own
                // colour band. It must never straddle unrelated temperature bands.
                var outside=true,own=true
                for row in 0...2 { for column in 0...4 {
                    let p=CGPoint(x:rect.minX+rect.width*CGFloat(column)/4,
                                  y:rect.minY+rect.height*CGFloat(row)/2)
                    let value=raster.band(at:p,in:projection.rect)
                    outside=outside && value<0;own=own && value==band.index
                } }
                guard outside || own else { return }
                let end=attachment(anchor,rect)
                let length=hypot(end.x-anchor.x,end.y-anchor.y)
                guard length<=28 else { return } // Never move a label across the widget.
                let centre=CGPoint(x:rect.midX,y:rect.midY)
                let ownPenalty:CGFloat=own ? 14 : 0
                choices.append(RangeCandidate(rect:rect,anchor:anchor,attachment:end,
                    score:length+ownPenalty+hypot(centre.x-anchor.x,centre.y-anchor.y)*0.05,inside:own))
            }
            for unit in raster.edgeAnchors[band.index] ?? [] {
                let a=project(unit)
                for gap in [CGFloat(6),12,18] {
                    let offsets=[CGPoint(x:gap,y:-box.height/2),CGPoint(x:-box.width-gap,y:-box.height/2),
                        CGPoint(x:-box.width/2,y:-box.height-gap),CGPoint(x:-box.width/2,y:gap),
                        CGPoint(x:gap,y:-box.height-gap),CGPoint(x:-box.width-gap,y:-box.height-gap),
                        CGPoint(x:gap,y:gap),CGPoint(x:-box.width-gap,y:gap)]
                    for d in offsets { add(CGRect(origin:CGPoint(x:a.x+d.x,y:a.y+d.y),size:box),a) }
                }
            }
            // Broad regions can also carry a direct label with no leader.
            for unit in raster.interiorAnchors[band.index] ?? [] {
                let a=project(unit)
                add(CGRect(x:a.x-box.width/2,y:a.y-box.height/2,width:box.width,height:box.height),a)
            }
            candidates[band.index]=choices.sorted { $0.score<$1.score }
        }
        var occupied=[CGRect](),leaders=[(CGPoint,CGPoint)]()
        // Give narrow, constrained bands first choice, rather than sorting by
        // temperature and forcing every subsequent label farther down the page.
        let order=snapshot.bands.sorted {
            let a=candidates[$0.index]?.count ?? 0,b=candidates[$1.index]?.count ?? 0
            return a==b ? $0.index<$1.index : a<b
        }
        for band in order {
            guard let text=texts[band.index],let choices=candidates[band.index] else { continue }
            func crossing(_ candidate: RangeCandidate) -> Bool {
                for rect in occupied {
                    if rect.insetBy(dx:-2,dy:-2).intersects(candidate.rect) { return true }
                    for step in 0...6 {
                        let f=CGFloat(step)/6
                        let p=CGPoint(x:candidate.anchor.x+(candidate.attachment.x-candidate.anchor.x)*f,
                                      y:candidate.anchor.y+(candidate.attachment.y-candidate.anchor.y)*f)
                        if rect.contains(p) { return true }
                    }
                }
                for (a,b) in leaders { for step in 0...6 {
                    let f=CGFloat(step)/6
                    if candidate.rect.contains(CGPoint(x:a.x+(b.x-a.x)*f,y:a.y+(b.y-a.y)*f)) { return true }
                } }
                return false
            }
            guard let chosen=choices.first(where:{ !crossing($0) }) else { continue }
            occupied.append(chosen.rect)
            if !chosen.inside {
                var line=Path();line.move(to:chosen.anchor);line.addLine(to:chosen.attachment)
                context.stroke(line,with:.color(.primary.opacity(0.4)),lineWidth:0.45)
                leaders.append((chosen.anchor,chosen.attachment))
            }
            var halo=context
            halo.addFilter(.shadow(color:Color(nsColor:.windowBackgroundColor).opacity(0.9),radius:1))
            halo.draw(text,at:CGPoint(x:chosen.rect.minX+2,y:chosen.rect.minY+1),anchor:.topLeading)
        }
        // Keep leader obstacles separate so existing city-label placement
        // remains unchanged. Only aircraft must avoid these extra obstacles.
        for (a,b) in leaders {
            aircraftLeaderObstacles += Self.aircraftLineObstacles(from:a,to:b)
        }
        return occupied
    }
}
