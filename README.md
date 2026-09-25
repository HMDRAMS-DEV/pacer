# Pacer

A calm menu bar app that helps you pace your weekly Claude and Codex limits.

**[Download for macOS](https://github.com/HMDRAMS-DEV/pacer/releases/latest)** · [pacer.ramihmd.com](https://pacer.ramihmd.com)

Pacer shows how much of each weekly limit you've used. Tell it when you want to use your limit by, for example "all of it by Friday", and how to spread it. Pacer then tells you when you're running hot and will run out early, or when you have room to lean in.

## What you get

- **A menu bar icon that means something.** One ring per tool, filled to the share of your weekly limit you've used. A notch marks where your plan says you should be right now. If the fill passes the notch, you're ahead of plan. A ring turns orange when that tool will run out before your finish day.
- **A popover** with each tool's status, how much you can still spend today, and a week chart of planned versus actual use per day.
- **A plan per tool:** finish day, target percentage, shape (even, front-loaded, back-loaded), spending days, and working hours.
- **Nudges.** At most one "ease off" and one "lean in" notification per tool per day, and only during your working hours.

## Where the numbers come from

| | Weekly and 5-hour limits | Daily breakdown |
|---|---|---|
| **Codex** | `rate_limits` events in `~/.codex/sessions/**/*.jsonl`. Local only. | Measured from the same events. |
| **Claude** | `GET https://api.anthropic.com/api/oauth/usage`, the request behind `/usage` in Claude Code. It uses the sign-in Claude Code stores in your Keychain (`Claude Code-credentials`). | Estimated. The exact weekly total is spread across days in proportion to token counts in `~/.claude/projects/**/*.jsonl`. |

Things to know:

- Claude Code doesn't write limit percentages to disk, so Claude is the only source that uses the network. Pacer reads the Keychain item through `/usr/bin/security` and never refreshes or rewrites it. If the sign-in expires, run `claude` once to refresh it.
- The Claude usage endpoint is undocumented and may change.
- Codex numbers are only as fresh as your last Codex session on this Mac.
- Pacer reads only token counts, timestamps, and rate-limit fields. It doesn't store or send your prompts, code, or replies.
- Pacer has no account, server, or analytics.

## How pacing works

For each tool, Pacer lays your plan over the current limit window. It takes the spending days between the window start and your finish day, weighted by the plan's shape and spread evenly across your working hours. That gives an expected-usage curve.

- **Pace:** compares your actual usage with the curve now.
- **Forecast:** assumes your current ratio to the plan holds. That gives your projected usage at the finish, or the time you'll hit 100%.
- **Allowance:** divides what's left over the rest of the plan in the same proportions. That gives "left today" and "per day from here".

The math is in `Pacer/Model/PaceMath.swift` and covered by `PacerTests/PaceMathTests.swift`.

## Build

Requirements: macOS 15 or later, Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Pacer.xcodeproj -scheme Pacer -destination 'platform=macOS' test
open Pacer.xcodeproj   # then Run
```

Pacer isn't sandboxed, because it reads `~/.claude` and `~/.codex` and calls `security`. That means it can't ship on the Mac App Store.

To render the popover, setup, and main window to PNGs for design review:

```sh
TEST_RUNNER_PACER_SNAPSHOTS=1 xcodebuild -project Pacer.xcodeproj -scheme Pacer -destination 'platform=macOS' test -only-testing:PacerTests/SnapshotRender
```

The images land in `$TMPDIR/PacerSnapshots`.

To build the downloadable disk image, run `scripts/make-dmg.sh`. It builds Release and writes `site/downloads/Pacer.dmg` with a drag-to-Applications window. The app is ad-hoc signed and not notarized, so on first launch macOS asks people to allow it in System Settings, Privacy & Security.

The app icon is drawn in code. To change it, edit `scripts/render-icon.swift` and run `swift scripts/render-icon.swift` from the repo root.

## Roadmap

- Calendar-aware plans: lower a day's share based on hours of meetings.
- Persist scan offsets so a relaunch doesn't rescan a week of logs.

## License

MIT

The Claude and OpenAI marks in `Pacer/Assets.xcassets` come from [Simple Icons](https://simpleicons.org) (CC0). They're trademarks of Anthropic and OpenAI, used here only to label each tool. Pacer isn't affiliated with or endorsed by either company.
