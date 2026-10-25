import InkKit
import Foundation

/// Sun and moon positions computed locally, accurate to about a minute, which is plenty for a menu bar.
enum Sky {
    private static func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86400 + 2440587.5 }

    private static func normalized(_ degrees: Double, _ range: Double = 360) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: range)
        return r < 0 ? r + range : r
    }

    /// Degrees above the horizon, from the low-precision solar coordinates in the Astronomical Almanac.
    static func sunElevation(at date: Date, latitude: Double, longitude: Double) -> Double {
        let rad = Double.pi / 180
        let n = julianDay(date) - 2451545.0
        let meanLongitude = normalized(280.460 + 0.9856474 * n)
        let anomaly = normalized(357.528 + 0.9856003 * n) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * rad
        let obliquity = (23.439 - 0.0000004 * n) * rad
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude)) / rad
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let siderealHours = normalized(18.697374558 + 24.06570982441908 * n, 24)
        let hourAngle = (siderealHours * 15 + longitude - rightAscension) * rad
        let lat = latitude * rad
        return asin(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle)) / rad
    }

    /// Sunrise and sunset within the given day, where the sun's upper edge crosses the horizon
    /// (-0.833° allows for refraction). Either is nil during polar day or night.
    static func sunTimes(on day: Date, latitude: Double, longitude: Double, calendar: Calendar = .current) -> (rise: Date?, set: Date?) {
        let start = calendar.startOfDay(for: day)
        let horizon = -0.833, step: TimeInterval = 300
        var rise: Date?, set: Date?
        var previous = sunElevation(at: start, latitude: latitude, longitude: longitude) - horizon
        for i in 1...288 {
            let t = start.addingTimeInterval(Double(i) * step)
            let current = sunElevation(at: t, latitude: latitude, longitude: longitude) - horizon
            if (previous < 0) != (current < 0) {
                let crossing = t.addingTimeInterval(-step * current / (current - previous))
                if current > 0 { rise = rise ?? crossing } else { set = set ?? crossing }
            }
            previous = current
        }
        return (rise, set)
    }

    /// 0 at new moon, 0.5 at full moon, measured from the new moon of 6 January 2000.
    static func moonPhase(at date: Date) -> Double {
        normalized(julianDay(date) - 2451550.1, 29.530588853) / 29.530588853
    }

    static func moonIllumination(_ phase: Double) -> Double { (1 - cos(2 * .pi * phase)) / 2 }

    static func moonName(_ phase: Double) -> (chinese: String, english: String) {
        switch phase {
        case ..<0.0339, 0.9661...: return ("新月", "New moon")
        case ..<0.2161: return ("蛾眉月", "Waxing crescent")
        case ..<0.2839: return ("上弦月", "First quarter")
        case ..<0.4661: return ("盈凸月", "Waxing gibbous")
        case ..<0.5339: return ("满月", "Full moon")
        case ..<0.7161: return ("亏凸月", "Waning gibbous")
        case ..<0.7839: return ("下弦月", "Last quarter")
        default: return ("残月", "Waning crescent")
        }
    }
}

enum Lunar {
    private static let calendar = Calendar(identifier: .chinese)
    private static let digits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MMM"
        return f
    }()

    /// 初一 … 初十, 十一 … 二十, 廿一 … 三十.
    static func dayName(_ day: Int) -> String {
        switch day {
        case 1...10: return "初" + digits[day]
        case 20: return "二十"
        case 30: return "三十"
        case 11...19: return "十" + digits[day - 10]
        default: return "廿" + digits[day - 20]
        }
    }

    static func day(_ date: Date) -> Int { calendar.component(.day, from: date) }

    /// e.g. 九月十五, or 闰六月初一.
    static func date(_ date: Date) -> String { monthFormatter.string(from: date) + dayName(day(date)) }

    static func month(_ date: Date) -> String { monthFormatter.string(from: date) }
}
