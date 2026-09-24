import SwiftUI

/// Everywhere you have been, and everything you have kept. Two lists in the
/// same white-and-hairline panel as the rest, and in both cases the point is
/// as much being able to remove a line as to read one.

enum When {
    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func said(_ date: Date) -> String {
        ago.localizedString(for: date, relativeTo: Date())
    }

    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    /// The time of day. Once a list is grouped by day, that is all a row needs.
    static func clock(_ date: Date) -> String { hour.string(from: date) }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return plain.string(from: date)
    }
}

struct HistoryPanel: View {
    @ObservedObject var browser: Browser

    @FocusState private var hunting: Bool
    @State private var traces: [History.Trace] = []
    @State private var clearing = false

    var body: some View {
        Plate("History", width: 600, close: { browser.recalling = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Hunt(text: $browser.recallHunt, prompt: "Search everywhere you have been", focus: $hunting)

                if traces.isEmpty {
                    Card { Nothing(browser.recallHunt.isEmpty ? "Nothing yet." : "Nothing matches.") }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(days, id: \.0) { day, rows in
                                VStack(alignment: .leading, spacing: 6) {
                                    Caption(day)
                                    Card {
                                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, trace in
                                            if index > 0 { Rule() }
                                            Row(
                                                trace: trace,
                                                go: {
                                                    browser.recalling = false
                                                    browser.active?.go(to: trace.url)
                                                },
                                                forget: {
                                                    browser.history.forget(trace.key)
                                                    refresh()
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 420)
                }
            }
        } foot: {
            if clearing {
                sweeps
            } else {
                HStack {
                    Text(traces.count == 1 ? "1 page" : "\(traces.count) pages")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Pill("Clear…") { withAnimation(Motion.settle) { clearing = true } }
                }
            }
        }
        .animation(Motion.settle, value: clearing)
        .onAppear {
            hunting = true
            refresh()
        }
        .onChange(of: browser.recallHunt) { _, _ in refresh() }
    }

    /// Three separate things, worded so nobody has to guess which one signs
    /// them out of their bank.
    private var sweeps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                Line("History", "Everywhere you have been") {
                    Pill("Clear") {
                        browser.clearHistory()
                        refresh()
                        withAnimation(Motion.settle) { clearing = false }
                    }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
            HStack {
                Spacer()
                Pill("Back") { withAnimation(Motion.settle) { clearing = false } }
            }
        }
        .transition(.opacity)
    }

    private var days: [(String, [History.Trace])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: traces) { calendar.startOfDay(for: $0.last) }
        return grouped.keys.sorted(by: >).map { day in
            (When.day(day), grouped[day]!.sorted { $0.last > $1.last })
        }
    }

    private func refresh() {
        traces = browser.history.everything(matching: browser.recallHunt)
    }

    /// One line. A title, where it came from, and when — the three things you
    /// scan for, in the order you scan them.
    private struct Row: View {
        let trace: History.Trace
        let go: () -> Void
        let forget: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Mark(icon: Favicons.shared.cached(trace.url.host()?.lowercased() ?? ""),
                     letter: trace.key.first.map { String($0).uppercased() } ?? "•", size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trace.title.isEmpty ? trace.key : trace.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(trace.key)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Remove", tint: .red.opacity(0.75), act: forget)
                } else {
                    Text(When.clock(trace.last))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: go)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

struct DownloadsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var loot: Loot

    @FocusState private var hunting: Bool
    @State private var query = ""

    private var shown: [Keep] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return loot.kept }
        return loot.kept.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.from.localizedCaseInsensitiveContains(q)
        }
    }

    private var empty: Bool { browser.fetching.isEmpty && shown.isEmpty }

    var body: some View {
        Plate("Downloads", width: 560, close: { browser.hoarding = false }) {
            VStack(alignment: .leading, spacing: 14) {
                if !loot.kept.isEmpty || !browser.fetching.isEmpty {
                    Hunt(text: $query, prompt: "Search downloads", focus: $hunting)
                }

                if empty {
                    Card {
                        Nothing(
                            loot.kept.isEmpty && browser.fetching.isEmpty
                                ? "Nothing downloaded yet."
                                : "Nothing matches."
                        )
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            if !browser.fetching.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Caption("In progress")
                                    Card {
                                        ForEach(Array(browser.fetching.enumerated()), id: \.element.id) { index, fetch in
                                            if index > 0 { Rule() }
                                            LiveRow(fetch: fetch, cancel: { browser.cancel(fetch) })
                                        }
                                    }
                                }
                            }

                            if !shown.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Caption(browser.fetching.isEmpty ? "Recent" : "History")
                                    Card {
                                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, keep in
                                            if index > 0 { Rule() }
                                            Row(
                                                keep: keep,
                                                open: { loot.open(keep) },
                                                reveal: { loot.reveal(keep) },
                                                forget: { loot.forget(keep) }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 420)
                }
            }
        } foot: {
            HStack {
                Text(foot)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Pill("Show folder") {
                    NSWorkspace.shared.open(browser.downloadsFolder)
                }
                if !loot.kept.isEmpty {
                    Pill("Clear list") { loot.forgetAll() }
                }
            }
        }
        .onAppear { hunting = loot.kept.count > 8 }
    }

    private var foot: String {
        let folder = browser.downloadsFolder.lastPathComponent
        if !browser.fetching.isEmpty {
            let n = browser.fetching.count
            return n == 1 ? "1 file arriving · \(folder)" : "\(n) files arriving · \(folder)"
        }
        if loot.kept.isEmpty {
            return "Files land in \(folder)"
        }
        return "Clearing the list leaves the files where they are"
    }

    private struct LiveRow: View {
        @ObservedObject var fetch: Fetch
        let cancel: () -> Void

        @State private var hovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(Palette.faint.opacity(0.55), lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        Circle()
                            .trim(from: 0, to: min(max(fetch.fraction, 0.04), 1))
                            .stroke(Palette.ink.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 18, height: 18)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fetch.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(fetch.progressSaid)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if hovering {
                        Quick("Cancel", tint: .red.opacity(0.75), act: cancel)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Palette.hairline)
                        Capsule()
                            .fill(Palette.ink.opacity(0.72))
                            .frame(width: max(3, geo.size.width * min(max(fetch.fraction, 0), 1)))
                    }
                }
                .frame(height: 3)
                .padding(.leading, 30)
                .animation(Motion.quick, value: fetch.fraction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    private struct Row: View {
        let keep: Keep
        let open: () -> Void
        let reveal: () -> Void
        let forget: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: keep.stillThere ? "doc" : "doc.badge.ellipsis")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(keep.stillThere ? Palette.muted : Palette.faint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(keep.name)
                        .font(.system(size: 13))
                        .foregroundStyle(keep.stillThere ? Palette.ink : Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(keep.from.isEmpty ? When.said(keep.date) : "\(keep.from) · \(When.said(keep.date))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hovering {
                    if keep.stillThere {
                        Quick("Open", act: open)
                        Quick("Show in Finder", act: reveal)
                    }
                    Quick("Remove", tint: .red.opacity(0.75), act: forget)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture { if keep.stillThere { open() } }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

