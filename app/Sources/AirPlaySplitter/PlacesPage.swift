import SwiftUI

/// The Places page: saved groups of TVs, and things to do at set times.
struct PlacesPage: View {
    @ObservedObject var model: SplitterModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: Tokens.gap) {
                PlacesCard(model: model)
                ScheduleCard(model: model)
            }
        }
        .scrollIndicators(.automatic)
        .frame(minHeight: 140, idealHeight: Tokens.pageCap, maxHeight: Tokens.pageCap)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
    }
}

private struct PageCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .modifier(PageGlass())
    }
}

private struct PageGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
        if #available(macOS 26.0, *) { content.glassEffect(.regular, in: shape) }
        else { content.background(.regularMaterial, in: shape) }
    }
}

// MARK: places

private struct PlacesCard: View {
    @ObservedObject var model: SplitterModel
    @State private var name = ""

    var body: some View {
        PageCard(title: "Places", symbol: "mappin.and.ellipse") {
            if model.places.isEmpty {
                Text("Switch on the TVs for a room, then save them as a place. Next time, one click connects them all.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.places) { p in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(p.name).font(.callout.weight(.medium))
                            if model.suggestedPlace?.id == p.id {
                                Text("Here").font(.caption2.weight(.semibold)).foregroundStyle(Tokens.live)
                            }
                        }
                        Text(model.tvNames(in: p).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button("Connect") { model.connectPlace(p) }.controlSize(.small)
                    Button { model.deletePlace(p) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this place")
                }
            }
            HStack(spacing: 6) {
                TextField(model.selected.isEmpty ? "Switch on TVs first" : "Name this place", text: $name)
                    .onSubmit(save)
                    .modifier(Field())
                    .disabled(model.selected.isEmpty)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.selected.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.callout)
        }
    }

    private func save() {
        model.savePlace(named: name)
        name = ""
    }
}

// MARK: schedule

private struct ScheduleCard: View {
    @ObservedObject var model: SplitterModel
    @State private var time = CountdownCardTime.next()
    @State private var days: Set<Int> = [1]
    @State private var action: ScheduleItem.Action = .countdown(minutes: 15)

    var body: some View {
        PageCard(title: "Schedule", symbol: "calendar.badge.clock") {
            if model.schedule.isEmpty {
                Text("Run things at set times while the app is open, like a countdown before each service.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.schedule) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(item.timeText) · \(item.daysText)").font(.callout.weight(.medium).monospacedDigit())
                        Text(model.describe(item.action)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Toggle("On", isOn: Binding(get: { item.enabled }, set: { model.setSchedule(item, enabled: $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    Button { model.deleteSchedule(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                }
            }
            Divider().opacity(0.4)
            // Add a new item.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.stepperField)
                    Picker("Do", selection: $action) {
                        ForEach(model.places) { p in Text("Connect \(p.name)").tag(ScheduleItem.Action.connectPlace(p.id)) }
                        if !model.places.isEmpty { Divider() }
                        ForEach([5, 10, 15], id: \.self) { m in
                            Text("Start a \(m)-minute countdown").tag(ScheduleItem.Action.countdown(minutes: m))
                        }
                        Text("Show the holding screen").tag(ScheduleItem.Action.showHolding)
                        Text("Show the main screen").tag(ScheduleItem.Action.showScreen)
                        Text("Blank the TVs").tag(ScheduleItem.Action.blank)
                        Text("Stop all").tag(ScheduleItem.Action.stopAll)
                    }
                    .labelsHidden()
                }
                HStack(spacing: 3) {
                    ForEach(1...7, id: \.self) { d in
                        let on = days.contains(d)
                        Button { if on { days.remove(d) } else { days.insert(d) } } label: {
                            Text(Calendar.current.veryShortWeekdaySymbols[d - 1])
                                .font(.caption2.weight(.semibold))
                                .frame(width: 20, height: 20)
                                .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
                                .foregroundStyle(on ? Color.white : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(Calendar.current.weekdaySymbols[d - 1])
                    }
                    Spacer()
                    Button("Add", action: add).buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
    }

    private func add() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        model.addSchedule(ScheduleItem(hour: c.hour ?? 0, minute: c.minute ?? 0, days: days, action: action))
    }
}

/// Next quarter hour, shared default for time pickers.
enum CountdownCardTime {
    static func next() -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: Date().addingTimeInterval(60))
        let m = c.minute ?? 0
        c.minute = m + (15 - m % 15) % 15
        c.second = 0
        return cal.date(from: c) ?? Date()
    }
}
