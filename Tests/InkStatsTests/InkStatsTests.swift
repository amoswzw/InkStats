import InkKit
import AppKit
import XCTest
@testable import InkStats

final class AlertEngineTests: XCTestCase {
    override func setUp() {
        for rule in AlertRule.allCases {
            UserDefaults.standard.removeObject(forKey: rule.enabledKey)
            UserDefaults.standard.removeObject(forKey: rule.thresholdKey)
        }
    }

    private func snapshot(cpu: Double) -> Snapshot {
        var s = Snapshot()
        s.cpu.total = cpu
        s.networkDetails.ipv4 = ["192.168.1.2"]
        return s
    }

    func testCPUAlertWaitsForSustainThenFiresOnce() {
        UserDefaults.standard.set(true, forKey: AlertRule.cpuHigh.enabledKey)
        let engine = AlertEngine()
        var fired: [AlertRule] = []
        engine.deliver = { rule, _, _ in fired.append(rule) }
        let start = Date()

        engine.evaluate(snapshot(cpu: 95), chinese: false, now: start)
        engine.evaluate(snapshot(cpu: 95), chinese: false, now: start.addingTimeInterval(4 * 60))
        XCTAssertEqual(fired, [], "must not fire before five minutes")

        engine.evaluate(snapshot(cpu: 95), chinese: false, now: start.addingTimeInterval(5 * 60))
        engine.evaluate(snapshot(cpu: 95), chinese: false, now: start.addingTimeInterval(9 * 60))
        XCTAssertEqual(fired, [.cpuHigh], "fires once per episode")
    }

    func testAlertRearmsAfterConditionClears() {
        UserDefaults.standard.set(true, forKey: AlertRule.cpuHigh.enabledKey)
        let engine = AlertEngine()
        var count = 0
        engine.deliver = { _, _, _ in count += 1 }
        let t0 = Date()

        engine.evaluate(snapshot(cpu: 95), chinese: false, now: t0)
        engine.evaluate(snapshot(cpu: 95), chinese: false, now: t0.addingTimeInterval(300))
        engine.evaluate(snapshot(cpu: 10), chinese: false, now: t0.addingTimeInterval(310))
        engine.evaluate(snapshot(cpu: 95), chinese: false, now: t0.addingTimeInterval(320))
        XCTAssertEqual(count, 1, "a new episode restarts the five-minute wait")
        engine.evaluate(snapshot(cpu: 95), chinese: false, now: t0.addingTimeInterval(620))
        XCTAssertEqual(count, 2)
    }

    func testDisabledRuleNeverFiresAndThresholdIsRespected() {
        let engine = AlertEngine()
        var count = 0
        engine.deliver = { _, _, _ in count += 1 }
        var s = Snapshot()
        s.battery = BatteryStats(present: true, percent: 15, charging: false, onAdapter: false)
        s.networkDetails.ipv4 = ["10.0.0.2"]
        engine.evaluate(s, chinese: false)
        XCTAssertEqual(count, 0, "rules are off by default")

        UserDefaults.standard.set(true, forKey: AlertRule.batteryLow.enabledKey)
        UserDefaults.standard.set(10.0, forKey: AlertRule.batteryLow.thresholdKey)
        engine.evaluate(s, chinese: false)
        XCTAssertEqual(count, 0, "15% is above a 10% threshold")
        s.battery.percent = 9
        engine.evaluate(s, chinese: false)
        XCTAssertEqual(count, 1)
    }
}

final class FormatTests: XCTestCase {
    func testRatesAndBytes() {
        XCTAssertEqual(Format.rate(0), "0.0 KB/s")
        XCTAssertEqual(Format.rate(1536 * 1024), "1.5 MB/s")
        XCTAssertEqual(Format.shortRate(820 * 1024), "820K")
        XCTAssertEqual(Format.bytes(48 * 1_073_741_824, decimals: 0), "48 GB")
        XCTAssertEqual(Format.duration(minutes: 372), "6:12")
    }
}

final class RenderingTests: XCTestCase {
    func testRoughRandomIsDeterministic() {
        var a = RoughRandom(seed: 42), b = RoughRandom(seed: 42)
        let first = (0..<5).map { _ in a.next() }
        XCTAssertEqual(first, (0..<5).map { _ in b.next() })
        XCTAssertTrue(first.allSatisfy { $0 >= 0 && $0 < 1 })
    }

    func testHachureStaysInsideShape() {
        var g = RoughGenerator(RoughOptions(roughness: 0, hachureGap: 4, seed: 3))
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40), CGPoint(x: 0, y: 40)]
        let ops = g.hachure(square)
        XCTAssertFalse(ops.isEmpty)
        for case let .curve(_, _, end) in ops {
            XCTAssertTrue((-0.5...40.5).contains(end.x) && (-0.5...40.5).contains(end.y), "\(end) left the square")
        }
    }

    func testSensorNames() {
        XCTAssertEqual(SensorNames.friendly("PMU tdie12"), "CPU die 12")
        XCTAssertEqual(SensorNames.friendly("NAND CH0 temp"), "SSD")
        XCTAssertEqual(SensorNames.friendly("gas gauge battery"), "Battery")
        XCTAssertEqual(SensorNames.friendly("pACC MTR Temp Sensor3"), "CPU performance cluster 3")
    }

    /// A trimmed Open-Meteo response, in the shape the API actually returns.
    func testParsesOpenMeteoForecast() throws {
        let json = """
        {"latitude":31.2,"longitude":121.5,"utc_offset_seconds":28800,"timezone":"Asia/Shanghai",
         "current":{"time":1792827000,"interval":900,"temperature_2m":20.7,"apparent_temperature":21.6,"relative_humidity_2m":88,
                    "weather_code":51,"wind_speed_10m":15.4,"is_day":1},
         "hourly":{"time":[1792825200,1792828800,1792832400],"temperature_2m":[20.5,20.9,null]},
         "daily":{"time":[1792771200,1792857600],"weather_code":[81,2],"temperature_2m_max":[20.9,23.5],"temperature_2m_min":[18.1,null],
                  "sunrise":[1792792987,1792879431],"sunset":[1792833193,1792919533],"precipitation_probability_max":[100,54]}}
        """
        let place = WeatherPlace(name: "Shanghai", detail: "China", latitude: 31.2, longitude: 121.5)
        let report = try WeatherService.parse(Data(json.utf8), place: place, now: Date(timeIntervalSince1970: 1792827000))
        XCTAssertEqual(report.celsius, 20.7)
        XCTAssertEqual(report.condition, .drizzle)
        XCTAssertTrue(report.isDay)
        XCTAssertEqual(report.hourly, [20.5, 20.9, nil])
        XCTAssertEqual(report.days.count, 1, "a day without a low is dropped")
        XCTAssertEqual(report.days.first?.condition, .rain)
        XCTAssertEqual(report.timeZone.secondsFromGMT(), 28800)
    }

    /// Open-Meteo gives Shanghai's sunrise on 24 October 2026 as 1792792987 and sunset as 1792833193.
    func testSunTimesMatchOpenMeteo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = Date(timeIntervalSince1970: 1792827000)
        let sun = Sky.sunTimes(on: day, latitude: 31.2222, longitude: 121.4581, calendar: calendar)
        XCTAssertEqual(sun.rise?.timeIntervalSince1970 ?? 0, 1792792987, accuracy: 120)
        XCTAssertEqual(sun.set?.timeIntervalSince1970 ?? 0, 1792833193, accuracy: 120)
    }

    func testMoonPhase() {
        // Full moon 25 January 2024 17:54 UTC; new moon 11 January 2024 11:57 UTC.
        XCTAssertEqual(Sky.moonPhase(at: Date(timeIntervalSince1970: 1706205240)), 0.5, accuracy: 0.03)
        let newMoon = Sky.moonPhase(at: Date(timeIntervalSince1970: 1704974220))
        XCTAssertLessThan(min(newMoon, 1 - newMoon), 0.03)
        XCTAssertEqual(Sky.moonName(0.5).english, "Full moon")
    }

    func testLunarDayNames() {
        XCTAssertEqual([1, 10, 11, 15, 20, 21, 29, 30].map(Lunar.dayName), ["初一", "初十", "十一", "十五", "二十", "廿一", "廿九", "三十"])
    }

    func testWeatherCodes() {
        let expected: [Int: WeatherCondition] = [0: .clear, 2: .partlyCloudy, 3: .cloudy, 48: .fog, 53: .drizzle, 82: .rain, 75: .snow, 99: .thunder]
        for (code, condition) in expected { XCTAssertEqual(WeatherCondition(code: code), condition, "code \(code)") }
    }

    func testCombinedItemsTakeTheFirstOnesPlace() {
        let modules: [ModuleID] = [.cpu, .gpu, .memory, .network, .disk]
        let some = StatusBarController.itemIDs(modules, combined: [.gpu, .disk])
        XCTAssertEqual(some.ids, ["cpu", "combined", "memory", "network"])
        XCTAssertEqual(some.grouped, [.gpu, .disk])
        XCTAssertEqual(StatusBarController.itemIDs(modules, combined: [.memory]).ids, ["cpu", "gpu", "memory", "network", "disk"],
                       "one combined module stays a module")
        XCTAssertEqual(StatusBarController.itemIDs(modules, combined: Set(ModuleID.allCases)).ids, ["combined"])
        XCTAssertEqual(StatusBarController.itemIDs([.cpu], combined: [.cpu, .gpu]).grouped, [], "disabled modules don't count")
    }

    /// Regression test for the combine-checkbox crash: removing a status item that has an
    /// autosave name makes AppKit write to UserDefaults, which posts didChangeNotification
    /// synchronously. That re-entered setModules mid-teardown (state was committed only at
    /// the end), so it tore the items down again and again until the stack overflowed.
    /// setModules must commit its state before touching the status bar, and must treat a
    /// lone combined module (grouped empty) as no change.
    func testSetModulesSurvivesTheNotificationStormFromTeardown() throws {
        // Real NSStatusItems need a WindowServer session and a booted NSApplication; a bare
        // CLI test process aborts inside CGS otherwise (seen on CI), so skip without a GUI.
        try XCTSkipUnless(CGSessionCopyCurrentDictionary() != nil, "no GUI session for status items")
        _ = NSApplication.shared
        let modules: [ModuleID] = [.cpu, .gpu, .memory]
        let statusBar = StatusBarController()
        var renders = 0
        // The same wiring AppDelegate uses: every defaults change re-renders.
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            renders += 1
            statusBar.setModules(modules, combined: Settings.shared.combinedModules)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            statusBar.setModules([], combined: [])
            Settings.shared.combinedModules = []
        }

        statusBar.setModules(modules, combined: [])
        Settings.shared.combinedModules = [.cpu, .gpu]  // what the Combine checkbox does
        XCTAssertEqual(statusBar.combinedModules, [.cpu, .gpu])
        Settings.shared.combinedModules = [.cpu]        // a lone combined module is none
        XCTAssertEqual(statusBar.combinedModules, [])
        Settings.shared.combinedModules = []
        XCTAssertEqual(statusBar.combinedModules, [])

        // Let queued observer calls drain; they must have converged, not crashed.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(renders, 0, "the teardown's defaults writes did notify")
    }
}
