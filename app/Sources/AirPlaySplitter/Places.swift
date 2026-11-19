import Foundation
import CoreGraphics

/// A saved group of TVs for one location ("Sanctuary", "Youth Room").
struct Place: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// KnownTV keys (device ID, or name).
    var tvKeys: [String]
}

/// Something to do at a set time on chosen days. Runs while the app is open.
struct ScheduleItem: Codable, Identifiable, Equatable {
    enum Action: Codable, Equatable, Hashable {
        case connectPlace(UUID)
        case showHolding
        case countdown(minutes: Int)
        case showScreen
        case blank
        case stopAll
    }

    var id = UUID()
    var hour: Int
    var minute: Int
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday. Empty means every day.
    var days: Set<Int>
    var action: Action
    var enabled = true

    var timeText: String {
        var c = DateComponents(); c.hour = hour; c.minute = minute
        let d = Calendar.current.date(from: c) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }

    var daysText: String {
        if days.isEmpty || days.count == 7 { return "Every day" }
        if days == [1] { return "Sundays" }
        if days == Set(2...6) { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        let names = Calendar.current.shortWeekdaySymbols
        return days.sorted().map { names[$0 - 1] }.joined(separator: ", ")
    }

    func isDue(at date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute, .weekday], from: date)
        return enabled && c.hour == hour && c.minute == minute && (days.isEmpty || days.contains(c.weekday ?? 0))
    }
}

/// Places and schedules, saved between launches.
enum PlacesStore {
    static func loadPlaces() -> [Place] { load("places") ?? [] }
    static func savePlaces(_ v: [Place]) { save(v, "places") }
    static func loadSchedule() -> [ScheduleItem] { load("schedule") ?? [] }
    static func saveSchedule(_ v: [ScheduleItem]) { save(v, "schedule") }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private static func save<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }
}

extension SplitterModel {
    // MARK: places

    /// Saves the TVs that are switched on now as a place.
    func savePlace(named name: String) {
        let keys = tvs.filter { selected.contains($0.ip) }.map(KnownTV.key(for:))
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !keys.isEmpty, !trimmed.isEmpty else { return }
        if let i = places.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            places[i].tvKeys = keys   // same name: update it
        } else {
            places.append(Place(name: trimmed, tvKeys: keys))
        }
    }

    func deletePlace(_ p: Place) {
        places.removeAll { $0.id == p.id }
        schedule.removeAll { $0.action == .connectPlace(p.id) }
    }

    /// Switches on every TV in a place.
    func connectPlace(_ p: Place) {
        for key in p.tvKeys {
            guard let tv = tvs.first(where: { KnownTV.key(for: $0) == key }) else { continue }
            if !selected.contains(tv.ip) { toggle(tv) }
        }
    }

    func tvNames(in p: Place) -> [String] {
        p.tvKeys.compactMap { key in tvs.first { KnownTV.key(for: $0) == key }?.name }
    }

    /// The place you're probably at: the one with the largest share of its
    /// TVs visible on this network right now (at least half). No Wi-Fi name
    /// or location permission needed.
    var suggestedPlace: Place? {
        let visible = Set(tvs.filter { !missing.contains($0.ip) }.map(KnownTV.key(for:)))
        return places
            .map { p in (p, Double(p.tvKeys.filter(visible.contains).count) / Double(max(1, p.tvKeys.count))) }
            .filter { $0.1 >= 0.5 }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: schedule

    func addSchedule(_ item: ScheduleItem) {
        schedule.append(item)
        schedule.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    func deleteSchedule(_ item: ScheduleItem) { schedule.removeAll { $0.id == item.id } }

    func setSchedule(_ item: ScheduleItem, enabled: Bool) {
        if let i = schedule.firstIndex(where: { $0.id == item.id }) { schedule[i].enabled = enabled }
    }

    func describe(_ a: ScheduleItem.Action) -> String {
        switch a {
        case .connectPlace(let id): "Connect \(places.first { $0.id == id }?.name ?? "a removed place")"
        case .showHolding: "Show the holding screen"
        case .countdown(let m): "Start a \(m)-minute countdown"
        case .showScreen: "Show the main screen"
        case .blank: "Blank the TVs"
        case .stopAll: "Stop all"
        }
    }

    /// Called every few seconds; runs each due item once per minute.
    func runSchedule(now: Date = Date()) {
        let minuteStamp = Int(now.timeIntervalSince1970 / 60)
        for item in schedule where item.isDue(at: now) && firedSchedule[item.id] != minuteStamp {
            firedSchedule[item.id] = minuteStamp
            perform(item.action)
        }
    }

    private func perform(_ a: ScheduleItem.Action) {
        switch a {
        case .connectPlace(let id): if let p = places.first(where: { $0.id == id }) { connectPlace(p) }
        case .showHolding: blanked = false; showHolding()
        case .countdown(let m): blanked = false; startCountdown(minutes: m)
        case .showScreen: blanked = false; chooseDisplay(CGMainDisplayID())
        case .blank: if !selected.isEmpty { blanked = true }
        case .stopAll: stopAll()
        }
    }
}
