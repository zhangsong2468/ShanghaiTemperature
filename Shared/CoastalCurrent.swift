import Foundation

// Widget-only acquisition. The App never constructs this store or supplies an overlay.
struct CoastalCurrentPoint: Codable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double

    static let coast: [CoastalCurrentPoint] = [
        .init(id:"jiangsu-north",latitude:34.4,longitude:120.2),
        .init(id:"jiangsu-south",latitude:32.3,longitude:121.8),
        .init(id:"shanghai-offshore",latitude:30.8,longitude:122.4),
        .init(id:"zhejiang-north",latitude:29.5,longitude:122.6),
        .init(id:"zhejiang-south",latitude:28.3,longitude:121.9)
    ]
}

struct CoastalCurrentSample: Codable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let validAt: Date
    let speed: Double // m/s, instantaneous model current, never a 24-hour mean.
    let direction: Double // Where the water is heading; 0 = north, 90 = east.

    var eastwardUnit: Double { sin(direction * .pi / 180) }
    var northwardUnit: Double { cos(direction * .pi / 180) }
}

struct CoastalCurrentOverlay: Codable, Sendable {
    static let duration: TimeInterval = 120
    let fetchedAt: Date
    let samples: [CoastalCurrentSample]
    var expiresAt: Date { fetchedAt.addingTimeInterval(Self.duration) }

    func visible(at date: Date) -> [CoastalCurrentSample] {
        guard date>=fetchedAt,date<expiresAt else { return [] }
        return samples.filter { sample in
            sample.speed.isFinite && sample.speed>0 && sample.direction.isFinite &&
            (0...360).contains(sample.direction) &&
            date.timeIntervalSince(sample.validAt)>=0 && date.timeIntervalSince(sample.validAt)<=3600
        }
    }
}

struct CoastalCurrentUpdate: Sendable {
    let overlay: CoastalCurrentOverlay?
    let refreshAfter: Date
}

enum CoastalCurrentDecoder {
    private struct Response: Decodable {
        struct Current: Decodable {
            let time: Double
            let ocean_current_velocity: Double?
            let ocean_current_direction: Double?
        }
        let latitude: Double
        let longitude: Double
        let current_units: [String:String]
        let current: Current
    }

    static func request() -> URL {
        let points=CoastalCurrentPoint.coast
        var url=URLComponents()
        url.scheme="https";url.host="marine-api.open-meteo.com";url.path="/v1/marine"
        url.queryItems=[
            .init(name:"latitude",value:points.map { String($0.latitude) }.joined(separator:",")),
            .init(name:"longitude",value:points.map { String($0.longitude) }.joined(separator:",")),
            .init(name:"current",value:"ocean_current_velocity,ocean_current_direction"),
            .init(name:"wind_speed_unit",value:"ms"),
            .init(name:"timezone",value:"Asia/Shanghai"),
            .init(name:"timeformat",value:"unixtime"),
            .init(name:"forecast_days",value:"1"),
            .init(name:"cell_selection",value:"sea")]
        return url.url!
    }

    static func decode(_ data: Data,at date: Date) throws -> [CoastalCurrentSample] {
        let rows=try JSONDecoder().decode([Response].self,from:data)
        guard rows.count==CoastalCurrentPoint.coast.count else { throw URLError(.cannotParseResponse) }
        var result=[CoastalCurrentSample](),cells=Set<String>()
        for (point,row) in zip(CoastalCurrentPoint.coast,rows) {
            guard row.latitude.isFinite,row.longitude.isFinite,
                  abs(row.latitude-point.latitude)<=0.25,abs(row.longitude-point.longitude)<=0.25,
                  row.current_units["time"]=="unixtime",
                  row.current_units["ocean_current_velocity"]=="m/s",
                  row.current_units["ocean_current_direction"]=="°" else {
                throw URLError(.cannotParseResponse)
            }
            guard row.current.time.isFinite,let speed=row.current.ocean_current_velocity,
                  let direction=row.current.ocean_current_direction,
                  speed.isFinite,speed>=0,direction.isFinite,(0...360).contains(direction) else { continue }
            let validAt=Date(timeIntervalSince1970:row.current.time)
            guard date.timeIntervalSince(validAt)>=0,date.timeIntervalSince(validAt)<=3600 else { continue }
            // Returned grid-cell coordinates are the actual model location.
            let cell=String(format:"%.5f,%.5f",row.latitude,row.longitude)
            guard cells.insert(cell).inserted else { continue }
            result.append(.init(id:point.id,latitude:row.latitude,longitude:row.longitude,
                validAt:validAt,speed:speed,direction:direction))
        }
        guard !result.isEmpty else { throw URLError(.cannotParseResponse) }
        return result
    }
}

actor CoastalCurrentStore {
    static let shared=CoastalCurrentStore()
    static let interval: TimeInterval = 600
    private struct State: Codable {
        let schema: Int
        let nextRequestAt: Date
        let overlay: CoastalCurrentOverlay?
    }
    private let directory: URL
    private let session: URLSession
    private let clock: () -> Date
    private var state: State?
    private var inFlight: Task<CoastalCurrentUpdate,Never>?

    init(directory: URL? = nil,session: URLSession? = nil,clock: @escaping () -> Date = { Date() }) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("ShanghaiTemperature-CoastalCurrent-v1")
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=12;config.timeoutIntervalForResource=18
        self.session=session ?? URLSession(configuration:config)
        self.clock=clock
    }

    func load() async -> CoastalCurrentUpdate {
        if let inFlight { return await inFlight.value }
        if state==nil,let data=try? Data(contentsOf:directory.appendingPathComponent("state.json")),
           let saved=try? JSONDecoder().decode(State.self,from:data),saved.schema==1 { state=saved }
        let now=clock()
        if let state,now<state.nextRequestAt {
            return CoastalCurrentUpdate(overlay:state.overlay,refreshAfter:state.nextRequestAt)
        }
        let task=Task { await self.perform(at:now) }
        inFlight=task
        let update=await task.value
        inFlight=nil
        return update
    }

    private func save(_ value: State) {
        state=value
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let data=try? JSONEncoder().encode(value) {
            try? data.write(to:directory.appendingPathComponent("state.json"),options:.atomic)
        }
    }

    private func perform(at started: Date) async -> CoastalCurrentUpdate {
        var next=started.addingTimeInterval(Self.interval)
        // Persist the request gate before awaiting; process restarts do not reset it.
        save(State(schema:1,nextRequestAt:next,overlay:nil))
        do {
            let (data,response)=try await session.data(from:CoastalCurrentDecoder.request())
            guard let http=response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode==429 || http.statusCode==503 {
                let end=clock()
                var delay:TimeInterval=600
                if let header=http.value(forHTTPHeaderField:"Retry-After") {
                    if let seconds=Double(header),seconds.isFinite,seconds>=0 { delay=max(delay,seconds) }
                    else {
                        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(secondsFromGMT:0)
                        f.dateFormat="EEE, dd MMM yyyy HH:mm:ss zzz"
                        if let until=f.date(from:header) { delay=max(delay,until.timeIntervalSince(end)) }
                    }
                }
                next=max(next,end.addingTimeInterval(delay))
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode),data.count<1_000_000 else { throw URLError(.badServerResponse) }
            let received=clock()
            let samples=try CoastalCurrentDecoder.decode(data,at:received)
            let overlay=CoastalCurrentOverlay(fetchedAt:received,samples:samples)
            next=received.addingTimeInterval(Self.interval)
            save(State(schema:1,nextRequestAt:next,overlay:overlay))
            return CoastalCurrentUpdate(overlay:overlay,refreshAfter:next)
        } catch {
            // Failed acquisition never restarts the two-minute display window.
            save(State(schema:1,nextRequestAt:next,overlay:nil))
            return CoastalCurrentUpdate(overlay:nil,refreshAfter:next)
        }
    }
}

// Display-only geometry in points (x=east, y=north). This does not modify model data.
struct CoastalCurrentGlyph: Sendable {
    struct Point: Sendable {
        let x: Double
        let y: Double
        func distance(to other: Point) -> Double { hypot(x-other.x,y-other.y) }
    }
    static let headLength = 2.2
    let tip: Point
    let left: Point
    let right: Point
    let start: Point?
    let control1: Point?
    let control2: Point?
    let opacity: Double

    init?(speed: Double,direction: Double,coastEast: Double? = nil,coastNorth: Double? = nil) {
        guard speed.isFinite,speed>0,direction.isFinite,(0...360).contains(direction) else { return nil }
        let radians=direction * .pi/180,dx=sin(radians),dy=cos(radians)
        let h=Self.headLength
        let base=Point(x:-dx*h,y:-dy*h)
        tip=Point(x:0,y:0)
        left=Point(x:base.x-dy*0.9,y:base.y+dx*0.9)
        right=Point(x:base.x+dy*0.9,y:base.y-dx*0.9)
        // A visual scale, not a physical speed class. Weak currents get only a chevron.
        let strength=min(1,max(0,(speed-0.15)/1.35))
        opacity=0.35+0.25*strength
        guard strength>0 else { start=nil;control1=nil;control2=nil;return }
        var tx=dx,ty=dy
        if let x=coastEast,let y=coastNorth,x.isFinite,y.isFinite,hypot(x,y)>1e-9 {
            let length=hypot(x,y);tx=x/length;ty=y/length
            let alignment=tx*dx+ty*dy
            if alignment<(-1e-9) || (abs(alignment)<=1e-9 && ty<0) { tx = -tx;ty = -ty }
        }
        // The cubic control-polygon length is h + tail <= 3h (6.6 pt).
        // Its final tangent ALWAYS equals the API heading, even for east/west flow.
        let tail=2*h*strength
        start=Point(x:base.x-tx*tail,y:base.y-ty*tail)
        control1=Point(x:base.x-tx*tail*2/3,y:base.y-ty*tail*2/3)
        control2=base
    }
}
