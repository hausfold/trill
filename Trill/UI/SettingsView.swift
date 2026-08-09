import SwiftUI

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

    private var currentStatus: [String: String?] {
        liveStatus ?? providerStatus
    }

    private var hasFullDiskAccess: Bool {
        currentStatus["system-mirror"].flatMap { $0 } == nil
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start at login", isOn: $settings.launchAtLogin)
                Toggle("Keep history on disk", isOn: $settings.persistHistory)
            }

            Section("Providers") {
                LabeledContent("Socket (trill CLI)", value: currentStatus["socket"].flatMap { $0 } ?? "ready")

                if hasFullDiskAccess {
                    systemMirrorUnlocked
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    systemMirrorLocked
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Section("Apple's banners") {
                Text("trill can't turn other apps' native banners off for you — that dial is Apple's. This is what it currently says.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                nativeBannerAudit

                HStack {
                    Button("Notification Settings…") {
                        SystemIntegration.openNotificationSettings()
                    }
                    Button("Focus Settings…") {
                        SystemIntegration.openFocusSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
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
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { celebrating = true }
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            withAnimation(.easeOut(duration: 0.8)) { celebrating = false }
        }
    }

    // MARK: - Apple's own per-app settings

    /// What macOS says right now about the apps trill is meant to be quiet
    /// for. Read-only by design — every button here opens System Settings,
    /// none of them writes a preference (see `NotificationSettingsAudit`).
    @ViewBuilder
    private var nativeBannerAudit: some View {
        if auditUnreadable {
            // The store lives in an Apple group container, which is
            // TCC-protected — the same grant System Mirror needs. Say that
            // rather than showing a reassuring green tick trill can't stand
            // behind.
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Can't tell — trill needs Full Disk Access to read macOS's notification settings.",
                    systemImage: "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                // Its own button, not a pointer at the System Mirror one:
                // that grant flips System Mirror on when it lands, and a user
                // who came here to make the audit work didn't ask for an
                // experimental provider.
                Button("Grant Full Disk Access…", action: onRequestAuditAccess)
                    .controlSize(.small)
            }
        } else if auditFindings.isEmpty {
            Label(
                auditScopeIsEmpty
                    ? "No apps listed in rules.json yet — nothing to check."
                    : "Nothing doubling up. macOS is quiet for every listed app.",
                systemImage: auditScopeIsEmpty ? "list.bullet" : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(auditScopeIsEmpty ? Color.secondary : Color.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(auditFindings, id: \.bundleID) { finding in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(NotificationSettingsAudit.displayName(for: finding.bundleID))
                                .font(.caption)
                                .fontWeight(.medium)
                            if let complaint = finding.complaint {
                                Text(complaint)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Silence…") {
                            SystemIntegration.presentNativeBannerAssistant(findings: [finding])
                        }
                        .controlSize(.small)
                    }
                }

                if auditFindings.count > 1 {
                    Button {
                        SystemIntegration.presentNativeBannerAssistant(findings: auditFindings)
                    } label: {
                        Label("Walk me through all \(auditFindings.count)", systemImage: "bell.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
        }
    }

    // MARK: - System Mirror, unlocked

    @ViewBuilder
    private var systemMirrorUnlocked: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("System Mirror (experimental)", isOn: $settings.systemMirrorEnabled)

            HStack(spacing: 6) {
                Image(systemName: "lock.open.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(celebrating ? "Unlocked — System Mirror is live" : "Full Disk Access granted")
                    .font(.caption)
                    .fontWeight(celebrating ? .semibold : .regular)
                    .foregroundStyle(.green)
                    .contentTransition(.opacity)
            }
            .scaleEffect(celebrating ? 1.06 : 1, anchor: .leading)

            Text("Reads macOS's private notification store, read-only, to redraw other apps' banners. May stop working on any macOS update — trill stays fully useful without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(celebrating ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(celebrating ? 0.12 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.green.opacity(celebrating ? 0.35 : 0), lineWidth: 1)
                )
        )
    }

    // MARK: - System Mirror, locked

    /// Deliberately *not* a disabled switch with a button underneath: a
    /// switch that silently refuses to move reads as a bug, and a button
    /// below it reads as unrelated. Until Full Disk Access exists there is
    /// exactly one thing to do here, so the section shows exactly that —
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

            Text("Unlock it and trill redraws **every other app's** banners in its own quiet style — Messages, Mail, Calendar, the lot. macOS keeps that store behind Full Disk Access, so it has to be granted once.")
                .font(.caption)
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

            if let reason = currentStatus["system-mirror"].flatMap({ $0 }) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
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
                .font(.caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
    }
}
