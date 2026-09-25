import SwiftUI

/// A bigger version of the popover. Click a tool to see a little more.
///
/// The window fits its content and never scrolls. It grows and shrinks from the bottom so the
/// top edge stays put when a card opens or closes.
struct MainView: View {
    @Environment(PacerStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Provider?
    @State private var fit = WindowFit()

    var body: some View {
        content
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
            .fitsWindow(fit)
            .background(Theme.canvas)
        .onAppear { expanded = store.focus }
        .onChange(of: store.focus) { _, focus in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { expanded = focus }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.weekday(store.now))
                    .display(32)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                IconButton(symbol: "arrow.clockwise", help: "Refresh now", size: 30) {
                    Task { await store.refresh(force: true) }
                }
                IconButton(symbol: "gearshape", help: "Settings", size: 30) {
                    openWindow(id: WindowID.settings)
                    NSApp.activate()
                }
            }

            if store.activeProviders.isEmpty {
                Text("Turn on a tool in Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            ForEach(store.activeProviders) { provider in
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        expanded = expanded == provider ? nil : provider
                    }
                } label: {
                    UsageCard(provider: provider, large: true, expanded: expanded == provider)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let last = store.lastRefresh {
                Text("Updated \(Format.ago(last, now: store.now))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 24)
    }
}
