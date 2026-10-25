import EventKit

struct UpcomingEvent {
    let title: String
    let start: Date
    let allDay: Bool
}

/// Today's and tomorrow's events from the Calendar app, read only after the user turns them on
/// and macOS grants access.
final class CalendarEvents {
    static let shared = CalendarEvents()

    private let store = EKEventStore()
    private var cache: [UpcomingEvent] = []
    private var cachedAt = Date.distantPast

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.cachedAt = .distantPast
        }
    }

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess(done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func upcoming(now: Date = Date()) -> [UpcomingEvent] {
        guard Settings.shared.showEvents, authorized else { return [] }
        if now.timeIntervalSince(cachedAt) > 60 {
            let calendar = Calendar.current
            let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))!
            let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
            cache = store.events(matching: predicate)
                .filter { $0.endDate > now }
                .sorted {
                    (calendar.startOfDay(for: $0.startDate), $0.isAllDay ? 0 : 1, $0.startDate)
                        < (calendar.startOfDay(for: $1.startDate), $1.isAllDay ? 0 : 1, $1.startDate)
                }
                .prefix(6)
                .map { UpcomingEvent(title: $0.title ?? "", start: $0.startDate, allDay: $0.isAllDay) }
            cachedAt = now
        }
        return cache
    }
}
