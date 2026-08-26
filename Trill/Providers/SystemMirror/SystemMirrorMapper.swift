import Foundation

/// The pure half of System Mirror: what one usernoted row becomes on screen.
///
/// Every decision that isn't SQLite lives here — which rows are trill's own
/// and must never come back in, what the source slug is that `rules.json`
/// matches on, which pills a mirrored card can honestly offer, and what a
/// notification with no title of its own is called. All of it is a function of
/// plain values, so it is tested headless.
enum SystemMirrorMapper {
    /// usernoted files notifications posted by system daemons under a
    /// prefixed identifier, so `com.apple.SoftwareUpdateNotification` shows up
    /// twice — once bare, once as `_SYSTEM_CENTER_:com.apple.…`. They are the
    /// same app to the person reading the banner, and asking someone to write
    /// a rule naming an internal prefix would be asking them to know that.
    /// The raw identifier survives in `metadata`.
    static let systemCenterPrefix = "_system_center_:"

    /// trill's own bundle ids, across both the hausfold and nebelhaus
    /// families and both build configurations. A mirror that reads its own
    /// banners is a feedback loop: trill draws a card, macOS records it,
    /// the mirror reads it back, trill draws it again. Excluded by identity
    /// rather than by "did we just send this", because the loop has to be
    /// impossible, not merely unlikely.
    static let ownBundleIDs: Set<String> = [
        "com.hausfold.trill", "com.hausfold.trill.debug",
        "com.nebelhaus.trill", "com.nebelhaus.trill.dev",
    ]

    /// The slug a rule matches: lowercased, and without usernoted's internal
    /// prefix. `RuleSet.Match` lowercases its own side too, so a rules file
    /// may say `com.apple.MobileSMS` and still match.
    static func source(for bundleID: String) -> String {
        let lowered = bundleID.lowercased()
        guard lowered.hasPrefix(systemCenterPrefix) else { return lowered }
        return String(lowered.dropFirst(systemCenterPrefix.count))
    }

    /// Is this app one the mirror is allowed to draw?
    ///
    /// `nil` means nobody has narrowed the list, so every app is — which is
    /// what System Mirror has always done and what flipping the switch on
    /// still gets you. A set means *exactly these*, so an empty one draws
    /// nothing: the user unticked every app, and inventing a card for one of
    /// them would be overruling that. Compared on the same slug `rules.json`
    /// matches on, so a list written by hand may spell an id in any case.
    static func isAllowed(_ bundleID: String, allowing allowed: Set<String>?) -> Bool {
        guard let allowed else { return true }
        return allowed.contains(source(for: bundleID))
    }

    /// Is this row one trill must not read back in? Its own, and anything
    /// whose identifier didn't survive to a usable slug.
    static func isOwn(_ bundleID: String, runningBundleID: String? = nil) -> Bool {
        let slug = source(for: bundleID)
        if ownBundleIDs.contains(slug) { return true }
        if let runningBundleID, slug == source(for: runningBundleID) { return true }
        return false
    }

    /// A name for the app when macOS won't give us one. `com.apple.tips` →
    /// "Tips". Deliberately dumb: the provider asks `NSWorkspace` for the
    /// real localized name first, and this is only what's left when the app
    /// that posted the notification isn't installed any more.
    static func fallbackAppName(for bundleID: String) -> String {
        let slug = source(for: bundleID)
        let last = slug.split(separator: ".").last.map(String.init) ?? slug
        guard let first = last.first else { return slug }
        return first.uppercased() + last.dropFirst()
    }

    /// Apple's own name for "a person wrote words at you". Matching the
    /// content *type* rather than a list of chat apps is what keeps trill
    /// from having opinions about which apps are Slack.
    static let messagingContentTypePrefix = "UNNotificationContentTypeMessaging"

    static func kind(forContentType contentType: String?, category: String?) -> NotificationEvent.Kind {
        if contentType?.hasPrefix(messagingContentTypePrefix) == true { return .chat }
        // Some senders never set a content type but do name a category that
        // says the same thing — Messages' own is the measured example.
        if category?.localizedCaseInsensitiveContains("message") == true { return .chat }
        return .note
    }

    /// One row, as a card. Nil for rows trill refuses to mirror.
    ///
    /// - Parameter appName: the app's display name, resolved by the provider
    ///   (`NSWorkspace`) so this stays pure. Nil falls back to the bundle id.
    /// - Parameter runningBundleID: this build's own id, so a rename of the
    ///   app can't reopen the feedback loop `ownBundleIDs` closes.
    static func event(
        for record: UsernotedRecord,
        appName: String? = nil,
        runningBundleID: String? = nil
    ) -> NotificationEvent? {
        guard !isOwn(record.bundleID, runningBundleID: runningBundleID) else { return nil }

        let slug = source(for: record.bundleID)
        guard !slug.isEmpty else { return nil }
        let name = appName ?? fallbackAppName(for: record.bundleID)

        // A row with no title of its own is titled with the app — Tips and
        // Find My both post that way, and "Tips" over the sentence reads far
        // better than the sentence alone with no idea who said it.
        let title = record.title ?? name

        var metadata: [String: String] = [
            "bundleId": record.bundleID,
            // Did macOS draw this itself? The answer is the whole point of
            // the Silence Native Banners helper, so it is carried, not acted
            // on — trill mirrors the event either way and says so.
            "nativeStyle": String(record.nativeStyle),
        ]
        if let category = record.category { metadata["category"] = category }
        if let destination = record.destinationURL { metadata["destination"] = destination }

        return NotificationEvent(
            id: record.uuid?.uuidString ?? "usernoted-\(record.recordID)",
            source: slug,
            timestamp: record.deliveredAt,
            title: title,
            subtitle: record.subtitle,
            body: record.body,
            // Threads are usernoted's, and usernoted's are per-app: two apps
            // may both call a thread "1" and they are not the same thread.
            thread: record.threadID.map { "\(slug):\($0)" },
            kind: kind(forContentType: record.contentType, category: record.category),
            actions: actions(bundleID: record.bundleID, appName: name),
            metadata: metadata
        )
    }

    /// The two pills a mirrored card can honestly offer.
    ///
    /// Not three: `req.durl` is a private scheme (`messages://open?…`), and
    /// `Action.openableSchemes` is http/https/file on purpose — a pill that
    /// opens nothing is worse than one that isn't drawn. Activating the app
    /// lands the user in the same place a click on Apple's own banner would.
    static func actions(bundleID: String, appName: String) -> [NotificationEvent.Action] {
        [
            NotificationEvent.Action(
                id: "open-source", label: "Open \(appName)", kind: .openApp, target: bundleID
            ),
            NotificationEvent.Action(
                id: "hush",
                label: "Silence \(appName)’s own banners",
                kind: .silenceNative,
                target: bundleID
            ),
        ]
    }
}
