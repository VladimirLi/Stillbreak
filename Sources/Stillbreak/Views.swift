import StillbreakCore
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json

    var id: Self { self }
    var fileExtension: String { rawValue }
    var contentType: UTType { self == .json ? .json : .commaSeparatedText }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Work threshold") {
                Stepper(
                    value: setting(\.workThreshold),
                    in: 60...86_400,
                    step: 60
                ) {
                    Text("\(Int(model.settings.workThreshold / 60)) min")
                }
            }
            LabeledContent("Dead time") {
                Stepper(
                    value: setting(\.deadTime),
                    in: 60...86_400,
                    step: 60
                ) {
                    Text("\(Int(model.settings.deadTime / 60)) min")
                }
            }
            Toggle("Notifications", isOn: setting(\.notificationsEnabled))
            if let message = model.notificationStatus.message {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Warning: \(message)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    if let title = model.notificationStatus.actionTitle {
                        Button(title) { model.performNotificationAction() }
                    }
                }
            }
            Toggle("Sound", isOn: setting(\.soundEnabled))
            Toggle("Launch at login", isOn: setting(\.launchAtLogin))
            if let error = model.launchAtLoginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let error = model.persistenceError {
                Text("Could not save state: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Text("Timing changes apply to the next work interval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 420)
        .padding()
        .onAppear { model.settingsDidAppear() }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<BreakSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: {
                var settings = model.settings
                settings[keyPath: keyPath] = $0
                model.updateSettings(settings)
            }
        )
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var selectedRange = DashboardRange.default
    @State private var visibleEndDate = Calendar.current.startOfDay(for: .now)
    @State private var selectedSegment: DashboardSegment?
    @State private var selectedDay: Date?
    @State private var showDeleteConfirmation = false

    private var dateRange: DashboardDateRange {
        DashboardDateRange(
            range: selectedRange,
            endingAt: visibleEndDate,
            calendar: .current
        )
    }

    private var dashboard: DashboardProjection {
        DashboardProjection.make(
            records: model.history,
            currentInterval: model.currentInterval,
            range: dateRange,
            calendar: .current
        )
    }

    /// Always a visible day: the user's choice when still shown, otherwise today or the final day.
    private var displayedDay: Date? {
        DashboardDaySelection.resolve(selectedDay, in: dashboard.days, today: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity")
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 4) {
                        Text(dateRange.start, format: .dateTime.month(.abbreviated).day())
                        Text("-")
                        Text(
                            dateRange.end.addingTimeInterval(-1),
                            format: .dateTime.month(.abbreviated).day().year()
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Range", selection: $selectedRange) {
                    ForEach(DashboardRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)

                HStack(spacing: 4) {
                    Button {
                        visibleEndDate = dateRange.shifted(
                            by: -selectedRange.dayCount,
                            calendar: .current
                        ).end.addingTimeInterval(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous range")

                    Button("Today") {
                        visibleEndDate = Calendar.current.startOfDay(for: .now)
                    }

                    Button {
                        visibleEndDate = dateRange.shifted(
                            by: selectedRange.dayCount,
                            calendar: .current
                        ).end.addingTimeInterval(-1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Next range")
                    .disabled(!dateRange.canNavigateForward(calendar: .current))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            HStack(spacing: 0) {
                MetricView(
                    title: "Active time",
                    value: DashboardPresentation.summaryDuration(dashboard.activeDuration)
                )
                Divider()
                MetricView(
                    title: "Overtime",
                    value: DashboardPresentation.summaryDuration(dashboard.overtimeDuration)
                )
                Divider()
                MetricView(
                    title: "Longest completed",
                    value: dashboard.longestStretch.map(DashboardPresentation.summaryDuration) ?? "-"
                )
                Divider()
                MetricView(title: "Most active", value: mostActiveHour(dashboard.mostActiveHour))
            }
            .frame(height: 72)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        LegendItem(color: .blue, title: "Active work")
                        LegendItem(color: .red, title: "Overtime")
                        LegendItem(color: .secondary, title: "Ongoing", outlined: true)
                        Label("Compressed empty hours", systemImage: "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    if let note = DashboardPresentation.emptyRangeNote(for: dashboard) {
                        Label(note, systemImage: "clock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isStaticText)
                            .allowsHitTesting(false)
                    }

                    ActivityTimelineView(
                        dashboard: dashboard,
                        selectedDay: displayedDay,
                        onSelectDay: { selectedDay = $0 },
                        selectedSegment: $selectedSegment
                    )
                }
                .padding(DashboardLayout.timelinePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                if let day = dashboard.days.first(where: { $0.date == displayedDay }) {
                    DayDetailPanel(
                        day: day,
                        isToday: Calendar.current.isDateInToday(day.date)
                    )
                    .frame(width: DashboardLayout.detailPanelWidth)
                }
            }

            Divider()

            HStack {
                Spacer()
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.rawValue.uppercased()) {
                            model.export(
                                format: format,
                                from: dateRange.start,
                                before: dateRange.end
                            )
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete All History", systemImage: "trash")
                }
                .disabled(model.history.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: DashboardLayout.minimumWindowWidth, minHeight: 720)
        .onChange(of: dateRange) {
            selectedDay = DashboardDaySelection.resolve(
                selectedDay,
                in: dashboard.days,
                today: .now
            )
        }
        .confirmationDialog(
            "Delete all history?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All History", role: .destructive) {
                model.deleteAllHistory()
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func mostActiveHour(_ hour: Int?) -> String {
        guard let hour else { return "-" }
        return String(format: "%02d:00-%02d:00", hour, (hour + 1) % 24)
    }
}

private struct MetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

private struct LegendItem: View {
    let color: Color
    let title: String
    var outlined = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            RoundedRectangle(cornerRadius: 2)
                .fill(outlined ? Color.clear : color)
                .stroke(
                    outlined ? color : Color.clear,
                    style: StrokeStyle(lineWidth: 1, dash: outlined ? [2, 2] : [])
                )
                .frame(width: 9, height: 9)
        }
        .foregroundStyle(.secondary)
    }
}

private struct ActivityTimelineView: View {
    let dashboard: DashboardProjection
    let selectedDay: Date?
    let onSelectDay: (Date) -> Void
    @Binding var selectedSegment: DashboardSegment?
    @State private var timelineWidth: CGFloat = 0
    @State private var revealTracker = DashboardSelectionRevealTracker()

    private let headerHeight: CGFloat = 42
    private let timelineHeight: CGFloat = 350
    private let summaryHeight = CGFloat(DashboardLayout.daySummaryHeight)

    private var dayRegionWidth: Double {
        DashboardLayout.dayRegionWidth(timelineWidth: Double(timelineWidth))
    }

    private var columnLayout: DashboardColumnLayout {
        DashboardColumnLayout.make(
            availableDayRegionWidth: dayRegionWidth,
            range: dashboard.range.range
        )
    }

    private var dayWidth: CGFloat { CGFloat(columnLayout.dayWidth) }
    private var contentWidth: CGFloat { CGFloat(columnLayout.contentWidth) }

    private var tickOffsets: [Int] {
        let first = Int(ceil(dashboard.scale.expandedStartOffset / 3_600) * 3_600)
        let last = Int(floor(dashboard.scale.expandedEndOffset / 3_600) * 3_600)
        guard first <= last else { return [] }
        return Array(stride(from: first, through: last, by: 3_600))
    }

    private var axisReferenceDay: DashboardDay {
        DashboardPresentation.axisReferenceDay(in: dashboard.days)!
    }

    private var axisTicks: [DashboardAxisTick] {
        DashboardPresentation.axisTicks(
            offsets: tickOffsets.map(TimeInterval.init),
            referenceDay: axisReferenceDay.date,
            calendar: .current
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Text(
                    DashboardPresentation.axisReferenceLabel(
                        for: axisReferenceDay.date,
                        calendar: .current
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, maxHeight: headerHeight, alignment: .trailing)
                .padding(.trailing, 6)
                Divider()
                TimelineAxis(
                    scale: dashboard.scale,
                    ticks: axisTicks,
                    height: timelineHeight
                )
                .frame(height: timelineHeight)
                Divider()
                Text("Daily")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: summaryHeight, alignment: .trailing)
                    .padding(.trailing, 6)
            }
            .frame(width: DashboardLayout.axisWidth)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(dashboard.days) { day in
                            TimelineDayView(
                                day: day,
                                range: dashboard.range.range,
                                tickOffsets: tickOffsets,
                                width: dayWidth,
                                headerHeight: headerHeight,
                                timelineHeight: timelineHeight,
                                summaryHeight: summaryHeight,
                                isSelected: day.date == selectedDay,
                                onSelectDay: onSelectDay,
                                selectedSegment: $selectedSegment
                            )
                            .id(day.date)
                        }
                    }
                    .frame(width: contentWidth)
                }
                // Keep the day shown in the detail panel on screen when it scrolls.
                .onAppear { revealSelection(proxy) }
                .onChange(of: selectedDay) { revealSelection(proxy) }
                .onChange(of: dashboard.range) { revealSelection(proxy) }
                // With no anchor, scrollTo moves the minimum needed to show the whole day,
                // so edge days end flush with the viewport instead of jumping.
                .onChange(of: columnLayout) {
                    if revealTracker.shouldReveal(for: columnLayout) {
                        proxy.scrollTo(selectedDay)
                    }
                }
            }
        }
        // Columns follow the measured width; the ScrollView fills it, so there is no feedback loop.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timelineWidth = $0 }
        .overlay {
            Rectangle()
                .stroke(.separator, lineWidth: 1)
        }
        .popover(item: $selectedSegment, arrowEdge: .trailing) { segment in
            ActivityPopover(segment: segment)
        }
        .background { TimelineKeyboardFocusHost(onMove: moveSelection) }
    }

    private func revealSelection(_ proxy: ScrollViewProxy) {
        revealTracker.markRevealed(columnLayout)
        proxy.scrollTo(selectedDay)
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard let day = DashboardDaySelection.moving(
            selectedDay,
            by: offset,
            in: dashboard.days,
            today: .now
        ) else {
            return .ignored
        }
        onSelectDay(day)
        return .handled
    }
}

/// Keyboard focus target for arrow-key day navigation. It sits behind the calendar as a sibling,
/// so disabling its oversized focus ring leaves native focus effects on day and block buttons.
private struct TimelineKeyboardFocusHost: View {
    let onMove: (Int) -> KeyPress.Result

    var body: some View {
        Color.clear
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { onMove(-1) }
            .onKeyPress(.rightArrow) { onMove(1) }
            .accessibilityLabel("Timeline days")
            .accessibilityHint("Use the Left and Right arrow keys to change the selected day")
    }
}

private struct TimelineAxis: View {
    let scale: DashboardTimeScale
    let ticks: [DashboardAxisTick]
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(ticks, id: \.offset) { tick in
                Text(tick.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .position(
                        x: 40,
                        y: scale.position(for: tick.offset) * height
                    )
            }
            ForEach(scale.bands.filter(\.isCompressed), id: \.startOffset) { band in
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .position(
                        x: 26,
                        y: (
                            scale.position(for: band.startOffset)
                                + scale.position(for: band.endOffset)
                        ) * height / 2
                    )
            }
        }
    }
}

/// One selection target per day: header, whole column background, and daily summary.
/// Work blocks sit above it and select the day before opening their popover.
private struct TimelineDayView: View {
    let day: DashboardDay
    let range: DashboardRange
    let tickOffsets: [Int]
    let width: CGFloat
    let headerHeight: CGFloat
    let timelineHeight: CGFloat
    let summaryHeight: CGFloat
    let isSelected: Bool
    let onSelectDay: (Date) -> Void
    @Binding var selectedSegment: DashboardSegment?
    @State private var isHovered = false

    private var highlight: Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        }
        return isHovered ? Color.accentColor.opacity(0.06) : Color.clear
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                onSelectDay(day.date)
            } label: {
                VStack(spacing: 0) {
                    DayHeaderView(day: day, isSelected: isSelected)
                        .frame(width: width, height: headerHeight)
                    Divider()
                    TimelineDayBackground(
                        day: day,
                        tickOffsets: tickOffsets,
                        width: width,
                        height: timelineHeight
                    )
                    Divider()
                    DailySummaryView(summary: day.summary, range: range)
                        .frame(width: width, height: summaryHeight)
                }
                .background(highlight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { isHovered = $0 }
            .help("Show details for this day")
            .accessibilityLabel(
                DashboardPresentation.dayAccessibilityLabel(for: day, calendar: .current)
            )
            .accessibilityValue(DashboardPresentation.dayAccessibilityValue(for: day))
            .accessibilityHint("Shows this day's details")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            ForEach(day.segments) { segment in
                let frame = DashboardLayout.segmentFrame(
                    segment,
                    scale: day.scale,
                    height: timelineHeight
                )
                Button {
                    onSelectDay(day.date)
                    selectedSegment = segment
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.isOvertime ? Color.red : Color.blue)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(
                                    Color.primary.opacity(segment.isOngoing ? 0.7 : 0.18),
                                    style: StrokeStyle(
                                        lineWidth: segment.isOngoing ? 1.5 : 1,
                                        dash: segment.isOngoing ? [3, 2] : []
                                    )
                                )
                        }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .frame(
                    width: max(18, width - 20),
                    height: max(5, frame.height)
                )
                .position(
                    x: width / 2,
                    y: headerHeight + 1 + frame.y + frame.height / 2
                )
                .help(segment.isOngoing ? "\(segment.typeLabel), ongoing" : segment.typeLabel)
                .accessibilityLabel(
                    DashboardPresentation.accessibilityLabel(for: segment, calendar: .current)
                )
                .accessibilityValue(
                    DashboardPresentation.accessibilityValue(for: segment)
                )
            }
        }
        .frame(width: width, height: headerHeight + timelineHeight + summaryHeight + 2)
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) { Divider() }
    }
}

private struct DayHeaderView: View {
    let day: DashboardDay
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(day.date, format: .dateTime.weekday(.abbreviated))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            HStack(spacing: 3) {
                Text(day.date, format: .dateTime.day())
                if !day.isStandardLength {
                    Text("\(Int(day.duration / 3_600))h")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct TimelineDayBackground: View {
    let day: DashboardDay
    let tickOffsets: [Int]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.015))

            ForEach(tickOffsets, id: \.self) { offset in
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 1)
                    .position(
                        x: width / 2,
                        y: day.scale.position(for: Double(offset)) * height
                    )
            }

            ForEach(day.scale.bands.filter(\.isCompressed), id: \.startOffset) { band in
                let top = day.scale.position(for: band.startOffset)
                let bottom = day.scale.position(for: band.endOffset)
                Rectangle()
                    .fill(Color.secondary.opacity(0.07))
                    .overlay {
                        Rectangle()
                            .stroke(
                                Color.secondary.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                    }
                    .frame(height: max(2, (bottom - top) * height))
                    .position(
                        x: width / 2,
                        y: (top + bottom) * height / 2
                    )
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

private struct DailySummaryView: View {
    let summary: DashboardDaySummary
    let range: DashboardRange

    var body: some View {
        let lines = DashboardPresentation.daySummaryLines(
            for: summary,
            style: DashboardLayout.daySummaryStyle(for: range)
        )
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Text(lines.active)
                    .font(.caption.weight(.semibold))
                if summary.hasOngoingWork {
                    Image(systemName: "circle.dashed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(lines.overtime)
                .font(.caption2)
                .foregroundStyle(summary.overtimeDuration > 0 ? Color.red : Color.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.06))
    }
}

private struct DayDetailPanel: View {
    let day: DashboardDay
    let isToday: Bool

    private var summary: DashboardDaySummary { day.summary }

    private var title: String {
        DashboardPresentation.dayTitle(for: day, calendar: .current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Day details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isToday {
                        Text("Today")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(title)
                    .font(.headline)
                if let note = DashboardPresentation.dayLengthNote(for: day) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 12)

            DetailRow(
                title: "Active time",
                value: DashboardPresentation.summaryDuration(summary.activeDuration)
            )
            Divider()
            DetailRow(
                title: "Overtime",
                value: DashboardPresentation.summaryDuration(summary.overtimeDuration),
                tint: summary.overtimeDuration > 0 ? .red : nil
            )
            Divider()
            DetailRow(
                title: "Longest completed",
                value: summary.longestCompletedStretch
                    .map(DashboardPresentation.summaryDuration) ?? "-"
            )
            Divider()
            DetailRow(
                title: "Most active",
                value: DashboardPresentation.mostActiveHourLabel(
                    for: day,
                    calendar: .current
                ) ?? "-"
            )

            if let note = DashboardPresentation.ongoingNote(for: summary) {
                Label(note, systemImage: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            } else if summary.activeDuration == 0 {
                Text("No validated work on this day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.05))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details for \(title)")
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(tint ?? Color.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityPopover: View {
    let segment: DashboardSegment

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Start").foregroundStyle(.secondary)
                Text(
                    DashboardPresentation.popoverTimestamp(
                        for: segment.start,
                        calendar: .current
                    )
                )
            }
            GridRow {
                Text("End").foregroundStyle(.secondary)
                Text(
                    DashboardPresentation.popoverTimestamp(
                        for: segment.end,
                        calendar: .current
                    )
                )
            }
            GridRow {
                Text("Duration").foregroundStyle(.secondary)
                Text(Duration.seconds(segment.duration).formatted(.time(pattern: .hourMinuteSecond)))
                    .monospacedDigit()
            }
            GridRow {
                Text("Type").foregroundStyle(.secondary)
                Label(
                    segment.typeLabel,
                    systemImage: segment.isOvertime ? "exclamationmark.circle.fill" : "clock.fill"
                )
                .foregroundStyle(segment.isOvertime ? .red : .blue)
            }
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Text(segment.isOngoing ? "Ongoing" : "Completed")
            }
        }
        .font(.callout)
        .padding(14)
    }
}

private struct PointingHandCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}
