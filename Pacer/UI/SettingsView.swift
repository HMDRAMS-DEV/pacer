import ServiceManagement
import SwiftUI

/// One page, in the native grouped style: which tools to track, the shared plan, and the rest.
struct SettingsView: View {
    @Environment(PacerStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Keys.alertsEnabled) private var alertsEnabled = true
    @AppStorage(Keys.chartStyle) private var chartStyle = ChartStyle.line
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Track") {
                ForEach(Provider.allCases) { provider in
                    Toggle(isOn: tracking(provider)) {
                        HStack(spacing: 8) {
                            provider.logo
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                            Text(provider.name)
                        }
                    }
                }
            }

            Section {
                Picker("Finish by", selection: $store.plan.finishWeekday) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(Optional(day))
                    }
                    Divider()
                    Text("When it resets").tag(Int?.none)
                }
                Picker("Spread", selection: $store.plan.shape) {
                    ForEach(PlanShape.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Spending days") {
                    WeekdayChips(selection: $store.plan.activeWeekdays)
                }
                LabeledContent("Working hours") {
                    HStack(spacing: 6) {
                        Picker("From", selection: $store.plan.dayStartHour) {
                            ForEach(0..<24, id: \.self) { Text(Format.hour($0)).tag($0) }
                        }
                        Text("to").foregroundStyle(.secondary)
                        Picker("To", selection: $store.plan.dayEndHour) {
                            ForEach((store.plan.dayStartHour + 1)...24, id: \.self) { Text(Format.hour($0)).tag($0) }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("Target") {
                    HStack(spacing: 10) {
                        Slider(value: $store.plan.targetPercent, in: 50...100, step: 5)
                            .frame(width: 140)
                        Text(Format.percent(store.plan.targetPercent))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Your week")
            } footer: {
                Text(store.plan.shape.summary)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Picker("Chart", selection: $chartStyle) {
                    ForEach(ChartStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Nudge me when a week drifts from the plan", isOn: $alertsEnabled)
                Toggle("Open Pacer at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                LabeledContent("Setup") {
                    Button("Run again") {
                        openWindow(id: WindowID.setup)
                        NSApp.activate()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 480, height: 620)
        .onChange(of: store.plan.dayStartHour) { _, start in
            if store.plan.dayEndHour <= start { store.plan.dayEndHour = start + 1 }
        }
    }

    private func tracking(_ provider: Provider) -> Binding<Bool> {
        Binding(
            get: { store.enabled.contains(provider) },
            set: { on in
                if on { store.enabled.insert(provider) } else { store.enabled.remove(provider) }
                Task { await store.refresh(force: true) }
            }
        )
    }
}
