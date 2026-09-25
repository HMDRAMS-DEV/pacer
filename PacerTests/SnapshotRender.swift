import AppKit
import SwiftUI
import Testing
@testable import Pacer

/// Renders the main screens to PNGs for design review. Run with TEST_RUNNER_PACER_SNAPSHOTS=1 (see README).
@MainActor
struct SnapshotRender {
    let folder = FileManager.default.temporaryDirectory.appending(path: "PacerSnapshots")

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_SNAPSHOTS"] != nil))
    func render() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Dates.parseISO("2026-09-23T15:00:00Z")!
        func usage(_ used: Double, resets: String, points: [(String, Double)]) -> ProviderUsage {
            ProviderUsage(weekly: UsageWindow(usedPercent: used, resetsAt: Dates.parseISO(resets)!, length: UsageWindow.week),
                          session: UsageWindow(usedPercent: 12, resetsAt: now.addingTimeInterval(7200), length: 18000),
                          history: points.map { UsagePoint(date: Dates.parseISO($0.0)!, usedPercent: $0.1) },
                          observedAt: now, historyIsEstimated: false)
        }
        let store = PacerStore(preview: [
            .claude: usage(62, resets: "2026-09-27T16:00:00Z", points: [("2026-09-21T15:00:00Z", 22), ("2026-09-22T15:00:00Z", 45), ("2026-09-23T14:00:00Z", 62)]),
            .codex: usage(28, resets: "2026-09-26T08:00:00Z", points: [("2026-09-21T15:00:00Z", 8), ("2026-09-22T15:00:00Z", 20), ("2026-09-23T14:00:00Z", 28)]),
        ], now: now)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            save(PopoverView().environment(store)
                // Stand-in for the menu material, which ImageRenderer can't draw.
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.93))
                .environment(\.colorScheme, scheme), "popover-\(suffix)")
        }
        for step in SetupView.Step.allCases {
            save(SetupView(step: step).environment(store), "setup-\(step.rawValue)")
        }
        save(SetupView(step: .plan).environment(store).environment(\.colorScheme, .dark), "setup-dark")
        save(MainView().environment(store), "main")
        save(MainView().environment(store).environment(\.colorScheme, .dark), "main-dark")
        UserDefaults.standard.set(ChartStyle.dots.rawValue, forKey: Keys.chartStyle)
        defer { UserDefaults.standard.removeObject(forKey: Keys.chartStyle) }
        for scheme in [ColorScheme.light, .dark] {
            save(PopoverView().environment(store)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.93))
                .environment(\.colorScheme, scheme), "dots-popover-\(scheme == .light ? "light" : "dark")")
        }
        save(MainView().environment(store).environment(\.colorScheme, .dark), "dots-main-dark")
        let icon = MenuBarIcon.image(rings: store.iconRings)
        let big = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { r in icon.draw(in: r); return true }
        try big.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }!.write(to: folder.appending(path: "icon.png"))
    }

    private func save(_ view: some View, _ name: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appending(path: "\(name).png"))
    }
}
