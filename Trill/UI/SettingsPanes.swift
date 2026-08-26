import AppKit
import SwiftUI

// MARK: - The panes

/// The sidebar's contents, in the order they appear.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case providers
    case banners
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .providers: return "Sources"
        case .banners: return "Apple’s Banners"
        case .files: return "Files"
        }
    }

    /// The line under the pane's title: what this pane is for, in one breath.
    var summary: String {
        switch self {
        case .general:
            return "How trill starts, and what it keeps."
        case .providers:
            return "Where trill's events come from, and whether each one is actually working."
        case .banners:
            return "What macOS itself still shows for the apps trill draws — trill reads this, it never writes it."
        case .files:
            return "Every dial trill has is a file you can edit. This is where they live."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .providers: return "antenna.radiowaves.left.and.right"
        case .banners: return "bell.slash.fill"
        case .files: return "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .providers: return .blue
        case .banners: return .orange
        case .files: return .purple
        }
    }
}

extension SettingsPane {
    /// "10m", "1h 30m", "At start" — one lead time, in the fewest words that
    /// stay unambiguous.
    static func leadLabel(_ minutes: Int) -> String {
        guard minutes > 0 else { return "At start" }
        guard minutes >= 60 else { return "\(minutes)m" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// The same number as a clause: "10m before", or "just as" for zero.
    static func leadDescription(_ minutes: Int) -> String {
        minutes > 0 ? "\(leadLabel(minutes)) before" : "just as"
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.general.title, subtitle: SettingsPane.general.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "power",
                    title: "Launch trill at login",
                    subtitle: "trill comes back in the menu bar — no window, no Dock icon. A compositor that isn’t running draws nothing."
                ) {
                    Toggle("Launch trill at login", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "internaldrive",
                    title: "Keep history on disk",
                    subtitle: "Off means nothing about any event ever touches disk — and the Inbox has nothing to show you."
                ) {
                    Toggle("Keep history on disk", isOn: $settings.persistHistory)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "eye.slash",
                    title: "Shy while the screen is watched",
                    subtitle: "Every card drops its body — the same thing `--redact` does — while something is looking at this screen. Titles stay; the Inbox is untouched."
                ) {
                    Toggle("Shy while the screen is watched", isOn: $settings.shyWhenWatched)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "moon.fill",
                    title: "Follow the Mac’s Focus",
                    subtitle: "While a Focus is on, chatter stops interrupting and goes to the Inbox, faults still land, and a question parks on the ledge instead of vanishing. trill reads the Focus — it never turns one on or off."
                ) {
                    Toggle("Follow the Mac’s Focus", isOn: $settings.focusAware)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "newspaper",
                    title: "Catch me up when I come back",
                    subtitle: "One card on unlock, counting what landed while you were away — “2 asks, 1 fault, 14 notes”. Nothing arrived, no card."
                ) {
                    Toggle("Catch me up when I come back", isOn: $settings.catchUpCard)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "terminal",
                    title: "Put `trill` on PATH",
                    subtitle: "The app is also the command line tool. trill links it into a directory of yours that is already on PATH — unless something else already answers `trill`, which it never overwrites."
                ) {
                    Toggle("Put trill on PATH", isOn: $settings.cliLink)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .disabled(settings.isManagedExternally)

            CLILinkNote(state: settings.cliLinkState)

            ScreenWatchNote()

            FocusNote(followingFocus: settings.focusAware)

            SettingsWriteStatus(settings: settings)

            SettingsFootnote(
                """
                Every switch here is a line in \(settings.configFileURL.path). Edit the file \
                and trill follows it while it runs; click a switch and the file is what gets \
                written. There is no second copy.
                """
            )
        }
    }
}

/// Where `trill` actually resolves — the half a toggle can't tell you.
///
/// A symlink in a directory nobody's PATH names is a file that exists and a
/// command that doesn't run, and reporting the first as if it were the second
/// is the same shape of lie as `doctor` exiting 0 while it's blind. So this
/// says which of the two happened, and when it's the useless one it says the
/// line to add.
struct CLILinkNote: View {
    let state: SystemIntegration.CLILinkState

    var body: some View {
        switch state {
        case .off:
            EmptyView()
        case .managed(let path):
            note("`trill` is already installed by something else — \(path). trill left it alone.", symbol: "checkmark.circle", tint: .secondary)
        case .linked(let path):
            note("`trill` resolves to \(path).", symbol: "checkmark.circle", tint: .green)
        case .linkedNotOnPath(let path):
            let directory = (path as NSString).deletingLastPathComponent
            note("Linked at \(path), but \(directory) is on no PATH your login shell has, so `trill` still won't run. Add it:  export PATH=\"\(directory):$PATH\"", symbol: "exclamationmark.triangle", tint: .orange)
        case .blocked(let reason):
            note(reason, symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// What trill can see about who is watching the screen, said plainly.
///
/// It is shown whether or not shyness is switched on, and it names the signal
/// rather than the conclusion — macOS has no "is my screen being captured"
/// API, only the one in-use indicator it draws for the screen, the camera and
/// the mic alike (see `ScreenWatch`). A user whose banners went quiet has to
/// be able to find out why in one glance, and a user whose camera is on has
/// to be able to see that that is what trill is reacting to.
struct ScreenWatchNote: View {
    @ObservedObject private var sentinel = ScreenWatchSentinel.shared

    var body: some View {
        // The reading has to be live *here* too: with no banner on screen the
        // compositor isn't polling, and a readout that only updates when a
        // notification happens to arrive would be furniture.
        let note = Group {
            if let reason = sentinel.watch.reason {
                SettingsNote(
                    symbol: sentinel.isShy ? "eye.slash.fill" : "eye.fill",
                    tint: sentinel.isShy ? .accentColor : .secondary,
                    text: sentinel.isShy
                        ? "Cards are redacted right now: \(reason)"
                        : "\(reason) Shyness is off, so cards are showing their bodies anyway."
                )
            }
        }
        note
            .onAppear {
                sentinel.refresh()
                sentinel.setPolling(true, by: .settings)
            }
            .onDisappear { sentinel.setPolling(false, by: .settings) }
    }
}

/// Which Focus macOS is in, said plainly — and the door to the only place
/// it can be changed.
///
/// The same contract as `ScreenWatchNote`: shown whether or not the switch is
/// on, because a switch has to be understandable before it is flipped, and
/// naming the *signal* rather than the conclusion. It has three things to say
/// and not two — the store is a file, and "trill can’t tell" is a verdict
/// (see `SystemFocus`), never rendered as "no Focus".
///
/// The button opens System Settings → Focus and nothing else. trill holds no
/// way to turn a Focus on or off and is not going to grow one: that dial is
/// the desktop’s (haus’s "Hush" lane drives it here) and the user’s.
struct FocusNote: View {
    let followingFocus: Bool
    @ObservedObject private var sentinel = FocusSentinel.shared

    var body: some View {
        let note = Group {
            if let reason = sentinel.state.reason {
                HStack(alignment: .top, spacing: 10) {
                    SettingsNote(
                        symbol: symbol,
                        tint: tint,
                        text: followingFocus || !sentinel.state.isOn
                            ? reason
                            : "\(reason) trill isn’t following it, so everything banners as usual."
                    )
                    Button("Focus…") { SystemIntegration.openFocusSettings() }
                        .padding(.top, 6)
                }
            }
        }
        note
            .onAppear {
                sentinel.refresh()
                sentinel.setPolling(true)
            }
            .onDisappear { sentinel.setPolling(false) }
    }

    private var symbol: String {
        switch sentinel.state {
        case .off: "moon"
        case .on: followingFocus ? "moon.fill" : "moon"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch sentinel.state {
        case .off: .secondary
        case .on: followingFocus ? .accentColor : .secondary
        case .unknown: .orange
        }
    }
}

/// The one thing a file-backed settings window owes the user: whether the
/// click actually reached the file. Silent on the happy path.
struct SettingsWriteStatus: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        if settings.isManagedExternally {
            SettingsNote(
                symbol: "lock.fill",
                tint: .secondary,
                text: """
                These switches are read-only on this Mac: config.json is generated by your \
                desktop and a rebuild would put it straight back. Change it where it’s declared, \
                then rebuild.
                """
            )
        } else if let error = settings.writeError {
            SettingsNote(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error)
        }
    }
}

// MARK: - Sources

struct ProvidersPane: View {
    @ObservedObject var settings: AppSettings
    let status: [String: String?]
    let hasFullDiskAccess: Bool
    let celebrating: Bool
    let onRequestFullDiskAccess: () -> Void

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.providers.title, subtitle: SettingsPane.providers.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "terminal.fill",
                    tint: .green,
                    title: "Socket",
                    subtitle: "The `trill` command, and anything scripted through it. Always on."
                ) {
                    ProviderHealthBadge(reason: status["socket"].flatMap { $0 })
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: .blue,
                    title: "GitHub Bridge",
                    subtitle: "Webhook deliveries become banners: a review request parks as an ask, an approval is done, a red run is a fault, a mention is a chat. trill listens on localhost behind your tunnel and never writes GitHub state."
                ) {
                    Toggle("GitHub Bridge", isOn: $settings.githubBridgeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(settings.isManagedExternally)
                }
                // Health, not hope: the toggle alone promises nothing without
                // github.json and a free port, so say what's missing.
                if settings.githubBridgeEnabled, let reason = status["github"].flatMap({ $0 }) {
                    SettingsDivider()
                    ProviderReason(reason)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "calendar",
                    tint: .red,
                    title: "Calendar",
                    subtitle: "Your next meeting, \(SettingsPane.leadDescription(settings.calendarLeadMinutes)) it starts — with a pill that opens it, and one that joins it when the invite carries a link trill knows. EventKit pushes, so a meeting moved on your phone moves the banner."
                ) {
                    Toggle("Calendar", isOn: $settings.calendarEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(settings.isManagedExternally)
                }
                if settings.calendarEnabled {
                    SettingsDivider()
                    SettingsRow(
                        symbol: "clock",
                        tint: .red,
                        title: "Lead time",
                        subtitle: "How much warning you get. Zero means the banner lands as the meeting starts."
                    ) {
                        Stepper(
                            value: $settings.calendarLeadMinutes,
                            in: AppConfig.calendarLeadRange,
                            step: 5
                        ) {
                            Text(SettingsPane.leadLabel(settings.calendarLeadMinutes))
                                .monospacedDigit()
                        }
                        .disabled(settings.isManagedExternally)
                    }
                    // Which door this row opens depends on what macOS has
                    // been asked. Apple's sheet appears exactly once, so after
                    // a "Don't Allow" the Privacy pane is the only road back
                    // — but *before* the ask there is no road at all: that
                    // pane lists an app only once the app has requested, so
                    // sending someone there while trill has never asked shows
                    // them a list trill isn't in. Ask first; point second.
                    if let reason = status["calendar"].flatMap({ $0 }) {
                        SettingsDivider()
                        SettingsRow(
                            symbol: "exclamationmark.triangle.fill",
                            tint: .orange,
                            title: "Not running",
                            subtitle: reason
                        ) {
                            switch CalendarProvider.authorization {
                            case .fullAccess:
                                EmptyView()
                            case .notDetermined:
                                Button("Ask macOS…") {
                                    Task { await CalendarProvider.requestAccess() }
                                }
                            default:
                                Button("Open Settings…") {
                                    SystemIntegration.openCalendarPrivacySettings()
                                }
                            }
                        }
                    }
                }
            }

            SettingsWriteStatus(settings: settings)

            if hasFullDiskAccess {
                systemMirrorUnlocked
            } else {
                systemMirrorLocked
            }
        }
    }

    // MARK: System Mirror, unlocked

    @ViewBuilder
    private var systemMirrorUnlocked: some View {
        SettingsCard {
            SettingsRow(
                symbol: "rectangle.on.rectangle",
                tint: .green,
                title: "System Mirror (experimental)",
                subtitle: "Reads macOS’s private notification store, read-only, to redraw other apps’ banners. A mirrored card lands about five seconds late — macOS batches its writes and nothing outside that daemon can hurry it, though the time on the card is exact. May stop working on any macOS update — trill stays fully useful without it."
            ) {
                Toggle("System Mirror", isOn: $settings.systemMirrorEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(settings.isManagedExternally)
            }
            SettingsDivider()
            SettingsRow(
                symbol: "lock.open.fill",
                tint: .green,
                title: celebrating ? "Unlocked — System Mirror is live" : "Full Disk Access granted",
                subtitle: nil
            ) {}
                .scaleEffect(celebrating ? 1.03 : 1, anchor: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(celebrating ? 0.12 : 0))
        )
    }

    // MARK: System Mirror, locked

    /// Deliberately *not* a disabled switch with a button underneath: a
    /// switch that silently refuses to move reads as a bug, and a button
    /// below it reads as unrelated. Until Full Disk Access exists there is
    /// exactly one thing to do here, so the card shows exactly that —
    /// what the feature buys, the two steps to it, and one button.
    @ViewBuilder
    private var systemMirrorLocked: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("System Mirror")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Locked · experimental")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text("Unlock it and trill redraws **every other app’s** banners in its own quiet style — Messages, Mail, Calendar, the lot, about five seconds after macOS gets them. macOS keeps that store behind Full Disk Access, so it has to be granted once.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                unlockStep(1, "Grant trill Full Disk Access", isCurrent: true)
                unlockStep(2, "trill switches System Mirror on for you", isCurrent: false)
            }

            Button(action: onRequestFullDiskAccess) {
                Label("Unlock System Mirror…", systemImage: "lock.open.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let reason = status["system-mirror"].flatMap({ $0 }) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private func unlockStep(_ number: Int, _ text: String, isCurrent: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: 17, height: 17)
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isCurrent ? Color.white : Color.secondary)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
    }
}

/// A provider's health in one glance: healthy is a tick, unhealthy is the
/// reason, never a spinner that never stops.
struct ProviderHealthBadge: View {
    let reason: String?

    var body: some View {
        if reason == nil {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(.green)
        } else {
            Label("Off", systemImage: "exclamationmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }
}

/// Why a source that's switched on still isn't running.
struct ProviderReason: View {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Apple's own per-app settings

/// What macOS says right now about the apps trill is meant to be quiet for.
/// Read-only by design — every button here opens System Settings, none of
/// them writes a preference (see `NotificationSettingsAudit`).
struct BannersPane: View {
    let findings: [NativeNotificationSettings]
    let scopeIsEmpty: Bool
    let unreadable: Bool
    let onRequestAuditAccess: () -> Void
    /// Hand the walkthrough back to the app rather than presenting it here,
    /// for the same reason the Full Disk Access flow does: the helper panel
    /// stands *beside* System Settings, and this window is what it would
    /// otherwise stand in front of. Only the app owns that window, so only
    /// the app can get it out of the way. Defaults to presenting it
    /// unchanged, so a pane hosted without an app (previews, tests) still
    /// works.
    var onSilenceNative: ([NativeNotificationSettings]) -> Void = {
        SystemIntegration.presentNativeBannerAssistant(findings: $0)
    }

    /// The apps a user can actually do something about — the walkthrough and
    /// the "Silence…" button are offered on these and nothing else.
    private var actionable: [NativeNotificationSettings] {
        NotificationSettingsAudit.walkable(findings)
    }

    /// The apps macOS keeps the switch to itself for. Reported, never offered
    /// as a step: there is no row in System Settings to open, so a "Silence…"
    /// button here would open a helper whose only content is "you can't".
    private var unlisted: [NativeNotificationSettings] {
        NotificationSettingsAudit.unlisted(findings)
    }

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.banners.title, subtitle: SettingsPane.banners.summary) {
            SettingsCard {
                if unreadable {
                    // The store lives in an Apple group container, which is
                    // TCC-protected — the same grant System Mirror needs. Say
                    // that rather than showing a reassuring green tick trill
                    // can't stand behind.
                    SettingsRow(
                        symbol: "questionmark.circle",
                        title: "Can’t tell",
                        subtitle: "trill needs Full Disk Access to read macOS’s notification settings."
                    ) {
                        // Its own button, not a pointer at the System Mirror
                        // one: that grant flips System Mirror on when it
                        // lands, and a user who came here to make the audit
                        // work didn't ask for an experimental provider.
                        Button("Grant…", action: onRequestAuditAccess)
                    }
                } else if actionable.isEmpty {
                    // "Nothing doubling up" is only true when nothing is
                    // noisy at all. An unlisted app *is* doubling up — it
                    // just isn't something to click — so when that's all
                    // there is, this card says nothing and the notice below
                    // carries it.
                    if unlisted.isEmpty {
                        SettingsRow(
                            symbol: scopeIsEmpty ? "list.bullet" : "checkmark.circle.fill",
                            tint: scopeIsEmpty ? .secondary : .green,
                            title: scopeIsEmpty ? "Nothing listed yet" : "Nothing doubling up",
                            subtitle: scopeIsEmpty
                                ? "No apps in rules.json, so there is nothing to check."
                                : "macOS is quiet for every listed app."
                        ) {}
                    } else {
                        SettingsRow(
                            symbol: "checkmark.circle.fill",
                            tint: .green,
                            title: "Nothing left to click",
                            subtitle: "Every app with a switch of its own is already quiet."
                        ) {}
                    }
                } else {
                    ForEach(Array(actionable.enumerated()), id: \.element.bundleID) { index, finding in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(
                            symbol: "bell.badge.fill",
                            tint: .orange,
                            title: NotificationSettingsAudit.displayName(for: finding.bundleID),
                            subtitle: finding.complaint
                        ) {
                            Button("Silence…") {
                                onSilenceNative([finding])
                            }
                        }
                    }
                }
            }

            if actionable.count > 1 {
                Button {
                    onSilenceNative(actionable)
                } label: {
                    Label("Walk me through all \(actionable.count)", systemImage: "bell.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // The other kind of finding: noisy, and macOS offers nobody a
            // switch. It's stated here, once, standing still — not walked
            // through, because a walkthrough step for it is a demo of two
            // controls that aren't on the pane and a Done button asking the
            // user to affirm a change nobody could make.
            if !unlisted.isEmpty {
                SettingsCard {
                    SettingsRow(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        title: unlisted.count == 1
                            ? "macOS draws this one itself"
                            : "macOS draws \(unlisted.count) of these itself",
                        subtitle: "System Settings lists no row for them under Application "
                            + "Notifications, so there is nothing to untick — here or there."
                    ) {}
                    ForEach(unlisted, id: \.bundleID) { finding in
                        SettingsDivider()
                        SettingsRow(
                            symbol: "bell.slash",
                            title: NotificationSettingsAudit.displayName(for: finding.bundleID),
                            subtitle: finding.complaint
                        ) {}
                    }
                }

                SettingsFootnote(
                    """
                    The one lever that is yours: route them to the inbox in ~/.config/trill/rules.json \
                    — "delivery": "inbox" on the rule naming the app — and you’ll see macOS’s \
                    banner once, with trill’s copy waiting in history instead of on screen.
                    """
                )
            }

            SettingsCard {
                SettingsRow(
                    symbol: "gear",
                    title: "macOS’s own dials",
                    subtitle: "Notifications is where an app’s native banner is turned off. Focus is what silences everything at once."
                ) {
                    HStack {
                        Button("Notifications…") {
                            SystemIntegration.openNotificationSettings()
                        }
                        Button("Focus…") {
                            SystemIntegration.openFocusSettings()
                        }
                    }
                }
            }

            SettingsFootnote(
                """
                trill can’t turn another app’s native banner off for you — that dial is Apple’s, \
                and trill only ever reads it. Opening the pane and showing you the two clicks is \
                the whole offer.
                """
            )
        }
    }
}

// MARK: - Files

/// Where every dial actually lives. A file-backed app that never tells you
/// the paths is a file-backed app you can't edit.
struct FilesPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.files.title, subtitle: SettingsPane.files.summary) {
            SettingsCard {
                FileRow(
                    symbol: "switch.2",
                    tint: .gray,
                    title: "config.json",
                    subtitle: "The switches on the General and Sources panes. Read live: edit it and trill follows without a restart.",
                    url: settings.configFileURL
                )
                SettingsDivider()
                FileRow(
                    symbol: "list.bullet.rectangle",
                    tint: .green,
                    title: "rules.json",
                    subtitle: "Which events banner, which park on the ledge, which go straight to the inbox. Everything about an event is decided here.",
                    url: AppPaths.rulesFile
                )
                SettingsDivider()
                FileRow(
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: .blue,
                    title: "github.json",
                    subtitle: "The bridge’s webhook secret and port. Needed before the GitHub source can start.",
                    url: AppPaths.configDirectory.appendingPathComponent("github.json")
                )
            }

            SettingsWriteStatus(settings: settings)

            SettingsFootnote(
                """
                All three are plain JSON in ~/.config/trill, and all three are read while trill \
                runs — nothing here needs a restart, and nothing you type is overwritten by \
                something you click.
                """
            )
        }
    }
}

/// One config file: what it holds, and the button that gets you to it.
private struct FileRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let url: URL

    private var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
            // "Reveal" on a file that isn't there yet would open a Finder
            // window on nothing; the directory is the honest destination, and
            // it is also where you'd create it.
            Button(exists ? "Reveal" : "Open Folder") {
                if exists {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            }
        }
    }
}
