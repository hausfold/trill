import AppKit
import SwiftUI

/// The Settings window: a sidebar of panes on the left, one scrolling pane on
/// the right — the same shape perch uses, because two apps in one family with
/// two different settings windows is two things to learn.
///
/// This view owns everything that has to be *polled* (provider health, and
/// what macOS currently says about other apps' banners) and hands each pane
/// the answer. The panes themselves are stateless, so a pane can be read
/// top-to-bottom without chasing a task modifier.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Live provider health, fed from the repository (name → reason string,
    /// nil = healthy). Experimental providers surface their honest state
    /// here instead of pretending.
    let providerStatus: [String: String?]
    var fetchProviderStatus: (() async -> [String: String?])? = nil
    let onRequestFullDiskAccess: () -> Void
    /// The same grant, asked for from the audit rather than from System
    /// Mirror — and *only* the grant. Separate closure because the System
    /// Mirror button switches that provider on when the grant lands, and a
    /// user who came here to make `doctor` work never asked to turn an
    /// experimental provider on.
    var onRequestAuditAccess: () -> Void = {}
    /// Start the "silence Apple's own banners" walkthrough for these apps.
    /// The app handles it rather than the pane, because the helper panel is
    /// meant to be read next to System Settings and this window is in its
    /// way — the same reason the Full Disk Access flow routes out here.
    var onSilenceNative: ([NativeNotificationSettings]) -> Void = {
        SystemIntegration.presentNativeBannerAssistant(findings: $0)
    }
    /// The bundle ids trill is meant to keep macOS quiet for. Supplied by the
    /// caller (which owns the live rule set) so this view stays ignorant of
    /// where "listed" comes from.
    var listedApps: () -> [String] = { [] }
    /// True when this window was reopened by the Full Disk Access assistant
    /// right after the grant landed — the one moment the unlock is worth
    /// celebrating rather than just stating.
    var celebrateUnlock: Bool = false

    @State private var liveStatus: [String: String?]? = nil
    @State private var celebrating = false
    @State private var auditFindings: [NativeNotificationSettings] = []
    /// True when there's nothing to audit *because nothing is listed* — a
    /// different answer from "checked, all quiet", and the one that should
    /// send the user to rules.json rather than reassure them.
    @State private var auditScopeIsEmpty = true
    /// True when macOS's settings store couldn't be read at all — the answer
    /// is "can't tell", which is not the same as "nothing to fix".
    @State private var auditUnreadable = false
    /// Which pane the window comes back to. Persisted, like every mac settings
    /// window: reopening lands where you left off, not on the first tab.
    @AppStorage(SettingsView.selectedPaneDefaultsKey) private var selectedPaneID = SettingsPane.general.rawValue

    private var currentStatus: [String: String?] {
        liveStatus ?? providerStatus
    }

    private var hasFullDiskAccess: Bool {
        currentStatus["system-mirror"].flatMap { $0 } == nil
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                        .padding(.leading, 2)
                } icon: {
                    SettingsPaneChip(symbol: pane.symbol, tint: pane.tint)
                }
                .padding(.vertical, 3)
            }
            // Nothing to toggle: a settings window with a collapsible sidebar
            // is a settings window you can hide the navigation of.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsSidebarFooter(version: Self.version)
            }
            // Outermost, and fixed: this is the width that has to hold
            // "Apple’s Banners" without an ellipsis, and a settings sidebar
            // has no reason to be draggable.
            .navigationSplitViewColumnWidth(210)
        } detail: {
            pane
                .frame(minWidth: 460, idealWidth: 520)
        }
        .frame(
            minWidth: 670, maxWidth: .infinity,
            minHeight: 400, maxHeight: .infinity
        )
        .navigationTitle(Self.windowTitle)
        .task {
            guard let fetchProviderStatus else { return }
            while !Task.isCancelled {
                let status = await fetchProviderStatus()
                await MainActor.run {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        self.liveStatus = status
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // Polled rather than read once: the user fixes these in System
        // Settings with this window still open, and a stale "still noisy" row
        // is worse than no row at all.
        .task {
            while !Task.isCancelled {
                let listed = listedApps()
                let findings = NotificationSettingsAudit.liveFindings(scope: .only(listed))
                withAnimation(.easeOut(duration: 0.25)) {
                    auditScopeIsEmpty = listed.isEmpty
                    // nil is "couldn't read", which is a third answer — not an
                    // empty worklist. Rendering it as "all quiet" would be
                    // trill reassuring someone about a file it never opened.
                    auditUnreadable = findings == nil
                    auditFindings = findings ?? []
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .task {
            guard celebrateUnlock else { return }
            // Land on the pane the unlock actually happened on, whatever pane
            // the window was last closed on — the payoff is unreadable from
            // the wrong tab.
            selectedPaneID = SettingsPane.providers.rawValue
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { celebrating = true }
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            withAnimation(.easeOut(duration: 0.8)) { celebrating = false }
        }
    }

    static let windowTitle = "Trill Settings"
    /// Where the selected pane is remembered. Named so the app can put the
    /// window on a specific pane before building it (`presentSettings`).
    static let selectedPaneDefaultsKey = "settingsSelectedPane"
    /// What the window opens at the first time, before anyone has resized it.
    static let defaultWindowSize = NSSize(width: 770, height: 560)

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    @ViewBuilder
    private var pane: some View {
        switch SettingsPane(rawValue: selectedPaneID) ?? .general {
        case .general:
            GeneralPane(settings: settings)
        case .providers:
            ProvidersPane(
                settings: settings,
                status: currentStatus,
                hasFullDiskAccess: hasFullDiskAccess,
                celebrating: celebrating,
                onRequestFullDiskAccess: onRequestFullDiskAccess
            )
        case .banners:
            BannersPane(
                findings: auditFindings,
                scopeIsEmpty: auditScopeIsEmpty,
                unreadable: auditUnreadable,
                onRequestAuditAccess: onRequestAuditAccess,
                onSilenceNative: onSilenceNative
            )
        case .files:
            FilesPane(settings: settings)
        }
    }

    /// `List` selects by element ID, and a pane's ID is its raw value — so the
    /// stored default *is* the selection. A nil set (clicking the sidebar's
    /// empty space) is dropped: there is always a pane on screen.
    private var selection: Binding<String?> {
        Binding(
            get: { selectedPaneID },
            set: { newValue in
                guard let newValue else { return }
                selectedPaneID = newValue
            }
        )
    }
}

/// The sidebar's foot: which trill this is, in the place every mac app puts
/// it.
private struct SettingsSidebarFooter: View {
    let version: String

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.6)
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Trill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(version)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}
