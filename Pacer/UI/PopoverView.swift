import SwiftUI

struct MenuBarLabel: View {
    @Environment(PacerStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Keys.setupDone) private var setupDone = false

    var body: some View {
        Image(nsImage: MenuBarIcon.image(rings: store.iconRings))
            .task {
                store.start()
                if !setupDone {
                    openWindow(id: WindowID.setup)
                    NSApp.activate()
                }
            }
    }
}

/// Sits on the system menu material, so it reads like part of macOS.
struct PopoverView: View {
    @Environment(PacerStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Keys.setupDone) private var setupDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Format.weekday(store.now))
                .display(20)
                .foregroundStyle(.primary)

            if let version = Updater.shared.available {
                UpdateTile(version: version)
            }

            if !setupDone {
                HStack {
                    Text("Let's get you set up.")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Start") { open(WindowID.setup) }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(12)
                .tile()
            }

            if store.activeProviders.isEmpty {
                if setupDone {
                    Text("Turn on a tool in Pacer's window.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tile()
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(store.activeProviders) { provider in
                        ProviderTile(provider: provider) {
                            store.focus = provider
                            open(WindowID.main)
                        }
                    }
                }
            }

            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let last = store.lastRefresh {
                Text("Updated \(Format.ago(last, now: store.now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.mini).padding(.trailing, 4)
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") {
                Task { await store.refresh(force: true) }
            }
            IconButton(symbol: "gearshape", help: "Settings") { open(WindowID.settings) }
            Menu {
                Button("Open Pacer") { open(WindowID.main) }
                Button("Settings…") { open(WindowID.settings) }
                Button("Set up again…") { open(WindowID.setup) }
                Button("Check for Updates…") { Updater.shared.check() }
                Divider()
                Button("Quit Pacer") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("More")
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

/// An update a background check found. Sparkle takes over from the button.
struct UpdateTile: View {
    let version: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available")
                    .font(.system(size: 13, weight: .semibold))
                Text("Pacer \(version) is ready.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Update") { Updater.shared.check() }
                .buttonStyle(PillButtonStyle())
        }
        .padding(12)
        .tile()
    }
}

/// A quiet round icon button, like the ones along the bottom of system menus.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 24
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(hovering ? Theme.quietWash : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

extension View {
    /// A translucent rounded tile that lets the menu material show through.
    func tile() -> some View {
        background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// One tool in the popover. Clicking it opens the main window on that tool.
struct ProviderTile: View {
    @Environment(PacerStore.self) private var store
    let provider: Provider
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            UsageCard(provider: provider)
                .tile()
                .scaleEffect(hovering ? 1.015 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(store.report(for: provider)?.detail(now: store.now) ?? store.errors[provider] ?? "")
    }
}

/// One tool at a glance: status, a big number, and the week as a race against the plan.
/// The main window shows it larger, and expanded with a little more detail.
struct UsageCard: View {
    @Environment(PacerStore.self) private var store
    let provider: Provider
    var large = false
    var expanded = false
    @AppStorage(Keys.chartStyle) private var chartStyle = ChartStyle.line

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 10 : 6) {
            HStack(alignment: .center) {
                provider.logo
                    .resizable()
                    .scaledToFit()
                    .frame(width: large ? 20 : 16, height: large ? 20 : 16)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(provider.name)
                    .help(provider.name)
                Spacer(minLength: 8)
                if let report = store.report(for: provider) {
                    band(report.band(now: store.now))
                }
            }
            if let report = store.report(for: provider), let usage = store.usage[provider] {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.percent(report.used))
                        .display(large ? 48 : 34)
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: report.used))
                    planLine(report)
                }
                Group {
                    switch chartStyle {
                    case .line: PaceTrack(usage: usage, report: report, now: store.now)
                    case .dots: PaceDots(usage: usage, report: report, now: store.now)
                    }
                }
                .frame(height: large ? 120 : 78)
                if expanded {
                    UsageDetail(provider: provider, report: report, usage: usage)
                        .padding(.top, 6)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.35).delay(0.15)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        ))
                }
            } else {
                placeholder
            }
        }
        .padding(large ? 18 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func band(_ band: (symbol: String, text: String, tone: Tone)) -> some View {
        Label(band.text, systemImage: band.symbol)
            .font(.system(size: large ? 12 : 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(band.tone.color)
            .padding(.horizontal, large ? 10 : 8)
            .padding(.vertical, large ? 5 : 4)
            .background(band.tone.wash, in: Capsule())
    }

    /// The plan struck through next to how far off you are, like a rescheduled departure.
    private func planLine(_ report: PaceReport) -> some View {
        let delta = report.delta
        return HStack(spacing: 5) {
            Text(Format.percent(report.expected))
                .strikethrough(delta.tone != .neutral, color: Theme.muted)
                .foregroundStyle(Theme.muted)
            Text(delta.text)
                .foregroundStyle(delta.tone.color)
        }
        .font(.system(size: large ? 14 : 12, weight: .medium).monospacedDigit())
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            if let error = store.errors[provider] {
                Image(systemName: "exclamationmark.circle")
                Text(large ? error : "Needs attention")
            } else {
                ProgressView().controlSize(.small)
                Text("Loading")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 60)
    }
}

/// The extra detail under an expanded card: a few numbers and the day by day split.
private struct UsageDetail: View {
    let provider: Provider
    let report: PaceReport
    let usage: ProviderUsage
    @Environment(PacerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 0) {
                stat("Left today", Format.percent(report.todayLeft))
                if let runOut = report.runOutAt, runOut < report.finishBy {
                    stat("Runs out", short(runOut), tone: .bad)
                } else if let projected = report.projectedAtFinish {
                    stat("At finish", Format.percent(projected))
                }
                stat("Resets", short(report.resetsAt))
                if let session = usage.session {
                    stat("5-hour", Format.percent(session.usedPercent))
                }
            }
            WeekStrip(bars: store.bars(for: provider), provider: provider, height: 64, showsValues: true)
        }
    }

    private func stat(_ title: String, _ value: String, tone: Tone? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
            Text(value)
                .display(20)
                .foregroundStyle(tone?.color ?? Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func short(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour())
    }
}
