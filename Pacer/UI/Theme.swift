import AppKit
import SwiftUI

/// Native first, warm like Cosmos. The popover sits on the system menu material with
/// translucent tiles, so it blends into macOS. The main window is warm paper with white cards.
/// Dark mode is neutral gray, not tinted black. Type is big and tightly tracked. Color comes
/// from the data: blue and purple per tool, green for room to spare, red for running out.
enum Theme {
    /// The app icon from the asset catalog. `NSApp.applicationIconImage` comes from the system
    /// icon cache, which can keep showing an old icon after it changes.
    static var appIcon: NSImage { NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }

    static let canvas = Color(light: 0xF7F5F3, dark: 0x141414)
    static let card = Color(light: 0xFFFFFF, dark: 0x212020)
    static let ink = Color(light: 0x0D0D0D, dark: 0xFFFFFF)
    static let muted = Color(light: 0x85807B, dark: 0xA39E99)
    static let hairline = Color(light: 0xE4E1DD, dark: 0x323131)
    static let hot = Color(light: 0xD92D20, dark: 0xFF6B5E)
    static let slack = Color(light: 0x039855, dark: 0x3DD68C)
    static let accent = Color(light: 0x0A84FF, dark: 0x3B8BFF)
    /// A neutral fill that works on any background, including the menu material.
    static let quietWash = Color.primary.opacity(0.07)

    static func tint(_ provider: Provider) -> Color {
        switch provider {
        case .claude: Color(light: 0x0A84FF, dark: 0x4C9DFF)
        case .codex: Color(light: 0x7B61FF, dark: 0xA08CFF)
        }
    }

    /// Start of the ring gradient.
    static func tintSoft(_ provider: Provider) -> Color {
        switch provider {
        case .claude: Color(light: 0x7CC4FF, dark: 0x1D4ED8)
        case .codex: Color(light: 0xB7A8FF, dark: 0x5B3FE0)
        }
    }

    static func wash(_ provider: Provider) -> Color {
        tint(provider).opacity(0.18)
    }

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }
}

extension Provider {
    /// The tool's mark, as a template image that takes the foreground color.
    var logo: Image {
        switch self {
        case .claude: Image("logo-claude")
        case .codex: Image("logo-openai")
        }
    }
}

extension View {
    /// Display type: semibold and tightly tracked, after Cosmos.
    func display(_ size: CGFloat) -> some View {
        font(Theme.display(size)).tracking(-size * 0.035)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Format {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    static func hour(_ hour: Int) -> String {
        switch hour {
        case 0, 24: "midnight"
        case 12: "noon"
        case 1..<12: "\(hour)am"
        default: "\(hour - 12)pm"
        }
    }

    /// "today at 2pm", "tomorrow at 9:30am", or "Thu at 2pm".
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        // Reset times arrive a few milliseconds either side of the hour. Show the nearest minute.
        let date = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.component(.minute, from: date) == 0 ? "ha" : "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) at \(time)"
    }

    /// "45m", "3h 49m", or "1d 4h".
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}
