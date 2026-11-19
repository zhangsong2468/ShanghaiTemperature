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
    let anchors: [Int: CGPoint] // Normalised image coordinates on each band's eastern edge.
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
        var anchors: [Int: CGPoint] = [:]
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
            let unit=CGPoint(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height))
            if anchors[band] == nil || unit.x > anchors[band]!.x { anchors[band]=unit }
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
        let result=ThermalMapRasterResult(image:image,anchors:anchors)
        cache.setObject(ThermalMapRasterBox(result),forKey:key,cost:width*height*4)
        return result
    }
}

struct ThermalMapView: View {
    let display: ThermalMapDisplay
    private let geometry: ThermalMapGeometry?
    private let raster: ThermalMapRasterResult?
    init(display: ThermalMapDisplay) {
        self.display=display
        let geometry=try? ThermalMapGeometry.bundled()
        self.geometry=geometry
        self.raster=display.snapshot.flatMap { snapshot in geometry.flatMap { ThermalMapRaster.image(snapshot:snapshot,geometry:$0) } }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text("江浙沪 · 体感温度").fontWeight(.medium)
                Spacer(minLength:2)
                Text(SolarTermCalendar.status(at:display.date).label).foregroundStyle(.secondary)
            }.font(.system(size:12))
            if let geometry,let snapshot=display.snapshot,let raster {
                Canvas { context,size in draw(context:&context,size:size,geometry:geometry,snapshot:snapshot,raster:raster) }
                    .accessibilityLabel("江浙沪体感温度地图，\(snapshot.bands.count)条温度带，摄氏度。\(display.message)")
            } else {
                VStack(spacing:8) {
                    Image(systemName:"map").font(.system(size:26,weight:.light))
                    Text(display.message).font(.system(size:11)).multilineTextAlignment(.center)
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
            Text("Open-Meteo · Natural Earth").font(.system(size:8)).foregroundStyle(.secondary)
        }.padding(13)
    }

    private func draw(context: inout GraphicsContext,size: CGSize,geometry: ThermalMapGeometry,
                      snapshot: ThermalBandSnapshot,raster: ThermalMapRasterResult) {
        let projection=MapProjection(bounds:geometry.bounds,
            rect:CGRect(x:size.width*0.20,y:9,width:size.width*0.62,height:max(1,size.height-18)))
        let outline=projection.path(geometry.regions)
        var clipped=context
        clipped.clip(to:outline,style:FillStyle(eoFill:true))
        clipped.draw(Image(decorative:raster.image,scale:1).interpolation(.high),in:projection.rect)
        context.stroke(outline,with:.color(.primary.opacity(0.55)),lineWidth:0.55)
        var occupied:[CGRect]=[]
        for label in geometry.labels {
            let anchor=projection.point(longitude:label.longitude,latitude:label.latitude)
            let text=context.resolve(Text(verbatim:label.name).font(.system(size:8.5,weight:.medium)).foregroundColor(.primary))
            let textSize=text.measure(in:CGSize(width:80,height:15))
            let offsets:[CGPoint]=[CGPoint(x:4,y:-12),CGPoint(x:4,y:3),CGPoint(x:-textSize.width-4,y:-12),
                CGPoint(x:-textSize.width-4,y:3),CGPoint(x:4,y:-24),CGPoint(x:-textSize.width-4,y:15),
                CGPoint(x:4,y:15),CGPoint(x:-textSize.width-4,y:-24)]
            let candidates=offsets.map { delta in CGRect(x:min(max(0,anchor.x+delta.x),max(0,size.width*0.78-textSize.width)),
                y:min(max(0,anchor.y+delta.y),max(0,size.height-textSize.height)),width:textSize.width,height:textSize.height) }
            let rect=candidates.first { candidate in !occupied.contains { $0.intersects(candidate.insetBy(dx:-2,dy:-2)) } } ?? candidates[0]
            occupied.append(rect)
            var leader=Path();leader.move(to:anchor);leader.addLine(to:CGPoint(x:rect.midX,y:rect.midY))
            context.stroke(leader,with:.color(.primary.opacity(0.35)),lineWidth:0.4)
            var halo=context;halo.addFilter(.shadow(color:Color(nsColor:.windowBackgroundColor).opacity(0.9),radius:1))
            halo.draw(text,at:CGPoint(x:rect.minX,y:rect.minY),anchor:.topLeading)
        }
        // Place interval text outside the map silhouette, alongside each band's
        // sample-height range. Leaders point to real classified sample locations.
        var previousY:CGFloat = -20
        for band in snapshot.bands {
            let members=snapshot.points.filter { $0.bandIndex==band.index }
            let lat=members.isEmpty ? (geometry.bounds[1]+geometry.bounds[3])/2 : members.map(\.latitude).reduce(0,+)/Double(members.count)
            let lon=members.isEmpty ? geometry.bounds[2] : members.map(\.longitude).max()!
            let fallback=projection.point(longitude:lon,latitude:lat)
            let anchor=raster.anchors[band.index].map { unit in
                CGPoint(x:projection.rect.minX+unit.x*projection.rect.width,
                        y:projection.rect.minY+unit.y*projection.rect.height)
            } ?? fallback
            var y=min(max(2,anchor.y-5),max(2,size.height-12))
            y=max(y,previousY+13);previousY=y
            if y>size.height-10 { y=CGFloat(band.index+1)*size.height/CGFloat(snapshot.bands.count+1) }
            let range=String(format:"%.1f–%.1f°",band.lower,band.upper)
            let text=context.resolve(Text(verbatim:range).font(.system(size:8,weight:.medium)).foregroundColor(.primary))
            let box=text.measure(in:CGSize(width:90,height:14))
            let x=max(0,size.width-box.width)
            var line=Path();line.move(to:anchor);line.addLine(to:CGPoint(x:x-2,y:y+box.height/2))
            context.stroke(line,with:.color(.primary.opacity(0.4)),lineWidth:0.5)
            context.draw(text,at:CGPoint(x:x,y:y),anchor:.topLeading)
        }
    }
}
