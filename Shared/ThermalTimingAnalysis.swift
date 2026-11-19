import Foundation

struct DailyThermalMean: Codable, Sendable {
    let date: Date
    let apparentTemperature: Double
}

enum ThermalTimingAnalysis {
    private static func median(_ values: [Double]) -> Double {
        let a=values.sorted();return a.count%2 == 0 ? (a[a.count/2-1]+a[a.count/2])/2 : a[a.count/2]
    }
    private static func slope(_ values: [Double]) -> Double {
        guard values.count>1 else { return 0 }
        var slopes:[Double]=[]
        for i in 0..<(values.count-1) { for j in (i+1)..<values.count { slopes.append((values[j]-values[i])/Double(j-i)) } }
        return median(slopes)
    }
    private struct Generator {
        var state: UInt64=0x535448
        mutating func index(_ count: Int) -> Int {
            state=state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(count))
        }
    }

    static func anomalyMessage(_ comparison: ThermalComparison) -> String {
        let years=comparison.historicalYears
        guard years.count>=3,!comparison.points.isEmpty else { return "同期样本不足" }
        let historical=years.indices.map { year in
            comparison.points.map {$0.historicalYears[year].mean}.reduce(0,+)/Double(comparison.points.count)
        }
        var generator=Generator(),means:[Double]=[]
        for _ in 0..<300 {
            means.append((0..<historical.count).map {_ in historical[generator.index(historical.count)]}.reduce(0,+)/Double(historical.count))
        }
        means.sort()
        let current=comparison.points.map(\.apparentTemperature).reduce(0,+)/Double(comparison.points.count)
        let delta=current-historical.reduce(0,+)/Double(historical.count)
        if current>=means[7],current<=means[292] { return "接近往年同期均值" }
        return String(format:"较往年同期%@约%.1f°",delta>=0 ? "偏暖" : "偏冷",abs(delta))
    }

    static func seasonalMessage(observed: [DailyThermalMean],profiles: [Int:[Int:Double]],at date: Date) -> String? {
        let calendar=ShanghaiTime.calendar,hour=calendar.component(.hour,from:date)
        let today=calendar.startOfDay(for:date)
        let days=observed.sorted {$0.date<$1.date}
        guard days.count==14,days.enumerated().allSatisfy({ i,item in
            item.apparentTemperature.isFinite && calendar.component(.hour,from:item.date)==hour &&
            calendar.dateComponents([.day],from:today,to:calendar.startOfDay(for:item.date)).day==i-13
        }) else { return nil }
        let shifts=Array(-14...14)
        let valid=profiles.values.filter { profile in (-27...14).allSatisfy { profile[$0]?.isFinite == true } }
        guard valid.count>=5 else { return nil }
        let values=days.map(\.apparentTemperature)
        let first=slope(Array(values.prefix(7))),last=slope(Array(values.suffix(7)))
        guard first*last>0 else { return nil }
        let warming=first>0
        func curve(_ sample: [[Int:Double]],_ shift: Int) -> [Double] {
            (-13...0).map { offset in sample.map {$0[offset+shift]!}.reduce(0,+)/Double(sample.count) }
        }
        func best(_ sample: [[Int:Double]]) -> Int {
            shifts.min { a,b in
                func error(_ s: Int) -> Double { zip(values,curve(sample,s)).map {pow($0.0-$0.1,2)}.reduce(0,+) }
                let x=error(a),y=error(b)
                return abs(x-y)<1e-10 ? abs(a)<abs(b) : x<y
            }!
        }
        let selected=best(Array(valid))
        guard abs(selected)>0,abs(selected)<14,slope(curve(Array(valid),selected))*first>0 else { return nil }
        var generator=Generator(),estimates:[Int]=[]
        for _ in 0..<200 { estimates.append(best((0..<valid.count).map {_ in valid[generator.index(valid.count)]})) }
        estimates.sort()
        guard (estimates[4]>0 || estimates[195]<0),abs(estimates[4])<14,abs(estimates[195])<14 else { return nil }
        return "近期"+(warming ? "回暖" : "降温")+"较往年"+(selected>0 ? "提前" : "推迟")+"约\(abs(selected))天"
    }
}
