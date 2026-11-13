import SwiftUI

struct ReadingStatisticsView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @ScaledMetric(relativeTo: .largeTitle) private var durationFontSize = 42
    @Environment(\.sizeCategory) private var sizeCategory

    private var statistics: ReadingStatistics { activity.statistics }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    header
                    todayCard
                    overviewGrid
                    weeklyCard(chartHeight: max(96, min(148, geometry.size.height - 650)))
                    historyLink
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(ReadingTheme.canvas)
        .navigationBarHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("阅读统计")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(ReadingTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("每一页，都算数")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日阅读")
                    .font(.subheadline)
                    .foregroundStyle(ReadingTheme.onAccent.opacity(0.95))
                Spacer()
                Text(Date.now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()))
                    .font(.caption)
                    .foregroundStyle(ReadingTheme.onAccent.opacity(0.75))
            }
            Text(duration(statistics.todayReadTime, compact: false))
                .font(.system(size: durationFontSize, weight: .semibold))
                .foregroundStyle(ReadingTheme.onAccent)
                .readingNumericTransition()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(statistics.todayReadTime == 0 ? "今天还没有阅读记录" : "已记录今天的阅读时长")
                .font(.caption)
                .foregroundStyle(ReadingTheme.onAccent.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(alignment: .bottomTrailing) {
            Image("StatisticsBookArtwork")
                .resizable()
                .scaledToFit()
                .frame(width: 156, height: 106)
                .opacity(0.48)
                .padding(.trailing, 10)
                .accessibilityHidden(true)
        }
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [ReadingTheme.emphasisSurface, Color(white: 0.19), ReadingTheme.emphasisSurface],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                ))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statistics.todayCard")
    }

    private var overviewGrid: some View {
        ReadingSoftCard {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    statisticTile(title: "累计阅读", value: duration(statistics.totalReadTime, compact: true), icon: "clock")
                    statisticTile(title: "阅读书籍", value: "\(statistics.bookCount) 本", icon: "books.vertical")
                }
                Rectangle().fill(ReadingTheme.separator.opacity(0.45)).frame(height: 0.5)
                HStack(spacing: 0) {
                    statisticTile(
                        title: "近 7 天",
                        value: duration(statistics.recentDays.reduce(0) { $0 + $1.readTime }, compact: true),
                        icon: "calendar"
                    )
                    statisticTile(title: "连续阅读", value: "\(statistics.currentStreak) 天", icon: "chart.bar")
                }
            }
            .overlay {
                Rectangle().fill(ReadingTheme.separator.opacity(0.45))
                    .frame(width: 0.5)
                    .padding(.vertical, 16)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
        }
    }

    private func statisticTile(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            if !sizeCategory.isAccessibilityCategory {
                Image(systemName: icon)
                    .environment(\.symbolVariants, .none)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 38, height: 40)
                    .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ReadingTheme.ink)
                    .readingNumericTransition()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }

    private func weeklyCard(chartHeight: CGFloat) -> some View {
        ReadingSoftCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("最近 7 天")
                        .font(.headline)
                        .foregroundStyle(ReadingTheme.ink)
                    Spacer()
                    Text("每日阅读时长")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(statistics.recentDays, id: \.date) { day in
                        VStack(spacing: 9) {
                            Text(barLabel(day.readTime))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Capsule()
                                .fill(day.readTime > 0 ? ReadingTheme.accent.opacity(Calendar.current.isDateInToday(day.date) ? 1 : 0.3) : ReadingTheme.accentSoft)
                                .frame(width: 24, height: barHeight(day.readTime, availableHeight: chartHeight))
                            Text(weekday(day.date))
                                .font(.system(size: 12))
                                .foregroundStyle(Calendar.current.isDateInToday(day.date) ? ReadingTheme.ink : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(weekday(day.date))，阅读 \(duration(day.readTime, compact: false))")
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)
            }
            .padding(18)
        }
    }

    private var historyLink: some View {
        NavigationLink {
            ReadingHistoryView()
        } label: {
            ReadingSoftCard {
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 23))
                    Text("阅读记录").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(ReadingTheme.accent)
                .frame(minHeight: 24)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("statistics.history")
    }

    private func barHeight(_ milliseconds: Int64, availableHeight: CGFloat) -> CGFloat {
        let maximum = max(statistics.recentDays.map(\.readTime).max() ?? 0, 1)
        guard milliseconds > 0 else { return 4 }
        return max(6, (availableHeight - 48) * CGFloat(milliseconds) / CGFloat(maximum))
    }

    private func barLabel(_ milliseconds: Int64) -> String {
        guard milliseconds >= 60_000 else { return milliseconds > 0 ? "<1分" : "0秒" }
        if milliseconds < 3_600_000 { return "\(milliseconds / 60_000)分" }
        let hours = Double(milliseconds) / 3_600_000
        return String(format: "%.1f时", hours)
    }

    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func duration(_ milliseconds: Int64, compact: Bool) -> String {
        let value = max(milliseconds, 0)
        let hours = value / 3_600_000
        let minutes = value % 3_600_000 / 60_000
        if compact {
            if hours > 0 { return minutes > 0 ? "\(hours)时\(minutes)分" : "\(hours) 小时" }
            return "\(minutes) 分钟"
        }
        let seconds = value % 60_000 / 1_000
        if hours > 0 { return minutes > 0 ? "\(hours)小时 \(minutes)分钟" : "\(hours) 小时" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "\(seconds) 秒"
    }
}
