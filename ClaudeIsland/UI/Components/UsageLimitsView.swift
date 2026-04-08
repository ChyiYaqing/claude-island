//
//  UsageLimitsView.swift
//  ClaudeIsland
//
//  Compact usage limits display for the notch header row
//

import SwiftUI

/// Compact inline display: "5h: 3%  W: 34%"
struct UsageLimitsView: View {
    let data: UsageLimitData

    var body: some View {
        HStack(spacing: 6) {
            // 5-hour (session) limit
            if let pct = data.fiveHourPercent {
                usageLabel(pct: pct, label: "5h")
            }

            // Separator
            if data.fiveHourPercent != nil && data.sevenDayPercent != nil {
                Text("·")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.2))
            }

            // 7-day (weekly) limit
            if let pct = data.sevenDayPercent {
                usageLabel(pct: pct, label: "W")
            }
        }
    }

    @ViewBuilder
    private func usageLabel(pct: Double, label: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.25))
            Text("\(Int(pct * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(percentColor(pct))
        }
    }

    private func percentColor(_ pct: Double) -> Color {
        if pct >= 0.8 {
            return Color(red: 1.0, green: 0.4, blue: 0.4)  // Red
        } else if pct >= 0.5 {
            return TerminalColors.amber
        } else {
            return .white.opacity(0.45)
        }
    }
}
