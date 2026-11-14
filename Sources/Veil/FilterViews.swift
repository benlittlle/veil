import SwiftUI
import VeilCore

/// One filter profile: an action per category, strictness and photos. Used for the default
/// profile (Settings) and a chat's own settings (Chats).
struct FilterPolicyEditor: View {
    @EnvironmentObject var model: AppModel
    let policy: FilterPolicy
    let onChange: (FilterPolicy) -> Void
    /// Start as a one-line summary with a Show button (Settings). Warnings stay visible either way.
    var collapsible = false
    @State private var confirmCodes = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if collapsible && !expanded {
                Card {
                    row("Categories", summary) {
                        Button("Show") { expanded = true }.buttonStyle(QuietButtonStyle())
                    }
                }
                if policy.action(.codes) == .allow { codesWarning }
                if policy.attachments == .allow { photosWarning }
            } else {
                editor
                if collapsible {
                    Button("Hide categories") { expanded = false }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent).padding(.leading, 4)
                }
            }
        }
        .alert("Let \(model.assistantName) see PINs and verification codes?", isPresented: $confirmCodes) {
            Button("Allow codes", role: .destructive) { var p = policy; p.set(.codes, .allow); onChange(p) }
            Button("Keep masking", role: .cancel) {}
        } message: {
            Text("An assistant that can read one-time codes can use them to sign in to your accounts, reset passwords or approve payments. Only allow this if you're sure.")
        }
    }

    /// "11 of 11 kinds filtered · Balanced · Photos: Check"
    var summary: String {
        let cats = FilterCategory.detectorCategories + FilterCategory.modelCategories
        let on = cats.filter { policy.action($0) != .allow }.count
        return "\(on) of \(cats.count) kinds of content filtered · \(policy.strictness.title) · Photos: \(policy.attachments.title)"
    }

    @ViewBuilder var editor: some View {
            Card {
                header("Found by pattern", "Matched on this Mac. Mask keeps the message and replaces just the match.")
                ForEach(FilterCategory.detectorCategories) { c in
                    Divider().padding(.leading, 16)
                    categoryRow(c)
                }
            }
            if policy.action(.codes) == .allow { codesWarning }
            Card {
                header("Judged by Apple Intelligence", "Checked by Apple's on-device model. Nothing leaves this Mac. Withhold hides the whole message.")
                ForEach(FilterCategory.modelCategories) { c in
                    Divider().padding(.leading, 16)
                    categoryRow(c)
                }
                Divider().padding(.leading, 16)
                row("How strict", policy.strictness.detail + " Messages the model can't judge are always withheld.") {
                    Picker("", selection: Binding(get: { policy.strictness }, set: { var p = policy; p.strictness = $0; onChange(p) })) {
                        ForEach(FilterStrictness.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            Card {
                row("Photos & files", photosDetail) {
                    Picker("", selection: Binding(get: { policy.attachments }, set: { var p = policy; p.attachments = $0; onChange(p) })) {
                        ForEach(PhotoMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityLabel("Photos & files")
                }
                if policy.attachments == .check {
                    Divider().padding(.leading, 16)
                    PhotoCheckStatus().padding(.horizontal, 16).padding(.vertical, 10)
                    Divider().padding(.leading, 16)
                    header("Seen in photos", "Apple Intelligence looks at each photo, and any text in it is checked like a message. Withhold keeps the photo back.")
                    ForEach(FilterCategory.photoCategories) { c in
                        Divider().padding(.leading, 16)
                        categoryRow(c)
                    }
                }
            }
            if policy.attachments == .allow { photosWarning }
    }

    var photosDetail: String {
        switch policy.attachments {
        case .allow: return "Shared unchecked if “See photos & files” is on. File names are masked."
        case .check: return "Each photo is checked on this Mac and shared only if it's clean. Videos and other files are withheld."
        case .withhold: return "Withheld in this chat, even with “See photos & files” on."
        }
    }

    var photosWarning: some View {
        warning("Photos aren't checked. A photo of a card or a screenshot of a code gets through. Choose Check to have each photo looked at first.")
    }

    func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var codesWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
            Text("PINs and verification codes are allowed. An assistant that can read one-time codes can take over your accounts. Set this back to Mask unless you need it.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    func categoryRow(_ c: FilterCategory) -> some View {
        row(c.title, c.detail) {
            Picker("", selection: Binding(get: { policy.action(c) }, set: { a in
                if c == .codes && a == .allow { confirmCodes = true; return }
                var p = policy; p.set(c, a); onChange(p)
            })) {
                ForEach(c.choices, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityLabel(c.title)
        }
    }

    func row<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 200, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Plain-language line about whether Apple Intelligence can check messages.
struct FilterModelStatus: View {
    @EnvironmentObject var model: AppModel
    let policy: FilterPolicy

    var body: some View {
        switch model.filterStatus {
        case .available:
            Label("Apple Intelligence is ready. Messages are checked on this Mac.", systemImage: "checkmark.seal")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .unavailable(let why):
            if policy.needsModel {
                Label("\(why) Until it's available, every message in filtered chats is withheld unless you set the Apple Intelligence topics to Allow.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("\(why) Not needed: every Apple Intelligence topic is set to Allow.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Plain-language line about whether photos can be checked.
struct PhotoCheckStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.photoStatus {
        case .available:
            Label("Photos are checked on this Mac by Apple Intelligence and text recognition.", systemImage: "checkmark.seal")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .unavailable(let why):
            Label("\(why) Until photos can be checked, every photo in these chats is withheld.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The content-filter part of a chat's page: on/off, settings, and the user's review.
struct ChatFilterSection: View {
    @EnvironmentObject var model: AppModel
    let chat: Conversation
    @State private var customizing = false

    var body: some View {
        let a = model.access(chat.id)
        let policy = model.filterPolicy(chat.id)
        let custom = a.filterPolicy != nil
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Content filter")
            Card {
                ToggleRow(icon: "line.3.horizontal.decrease.circle", title: "Filter sensitive content",
                          detail: a.filtered
                            ? "Card numbers, codes, passwords and chosen topics are removed on this Mac first."
                            : "Off: messages are shared exactly as they are.",
                          isOn: Binding(get: { a.filtered }, set: { model.setFiltered($0, for: chat.id) }), disabled: a.hidden)
                if a.filtered && !a.hidden {
                    Divider().padding(.leading, 60)
                    FilterModelStatus(policy: policy).padding(.horizontal, 16).padding(.vertical, 10)
                    Divider().padding(.leading, 16)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(custom ? "This chat's own settings" : "Default settings").font(.system(size: 13, weight: .medium))
                            Text(custom ? "Changes here apply only to \(chat.displayName)." : "Change the default under Settings → Content filter.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if custom {
                            Button("Use default") { model.setChatFilterPolicy(nil, for: chat.id); customizing = false }.buttonStyle(QuietButtonStyle())
                        } else {
                            Button(customizing ? "Done" : "Customize") { customizing.toggle() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            if a.filtered && !a.hidden {
                if custom || customizing {
                    FilterPolicyEditor(policy: policy) { model.setChatFilterPolicy($0, for: chat.id) }
                }
                if !a.read && !a.waiting && !a.attachments {
                    Text("Read is off, so nothing is shared yet. The filter applies once you turn Read on.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4)
                }
                FilterReviewList(chatID: chat.id)
            }
        }
    }
}

/// What the filter changed in a chat, and why. Only the user sees this.
struct FilterReviewList: View {
    @EnvironmentObject var model: AppModel
    let chatID: String
    @State private var showAll = false

    var body: some View {
        let items = model.filterReview[chatID] ?? []
        let photos = model.photoReview[chatID] ?? []
        let shown = showAll ? items : Array(items.prefix(3))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Filtered recently")
                Spacer()
                if model.filterReviewLoading.contains(chatID) { ProgressView().controlSize(.small) }
                Button("Refresh") { model.loadFilterReview(chatID) }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
            }
            Text("Only you see this list. \(model.assistantName) gets [removed] or [withheld] instead, with no reason.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !photos.isEmpty {
                Card {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 84) }
                        photoRow(item)
                    }
                }
            }
            if items.isEmpty && !photos.isEmpty {
                EmptyView()
            } else if items.isEmpty {
                Text(model.filterReviewLoading.contains(chatID) ? "Checking recent messages…" : "Nothing filtered in recent messages.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Card {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 16) }
                        reviewRow(item)
                    }
                }
                if items.count > shown.count || showAll {
                    Button(showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
        }
        .onAppear { if model.filterReview[chatID] == nil { model.loadFilterReview(chatID) } }
    }

    func photoRow(_ item: Gate.PhotoReviewItem) -> some View {
        let policy = model.filterPolicy(chatID)
        return HStack(alignment: .top, spacing: 12) {
            PhotoThumb(image: model.photoThumbs[item.id])
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.from == Gate.meLabel ? "You" : item.from).font(.system(size: 12, weight: .semibold))
                    Text(item.date.relative).font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    if item.allowedByUser { Pill(text: "Allowed by you", color: Theme.accent) }
                    ForEach(item.reasons) { Pill(text: $0.title, color: Theme.caution) }
                    if let why = Self.photoProblem(item.outcome, canCheck: model.photoStatus.isAvailable) { Pill(text: why, color: Theme.caution) }
                }
                Text(item.name ?? "Photo").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text("\(model.assistantName) sees: " + (item.allowedByUser ? "the photo" : "nothing (photo held back)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(item.allowedByUser ? "Check again" : "Allow this photo") {
                        model.setPhotoAllowed(!item.allowedByUser, attachment: item.id, in: chatID)
                    }
                    // Codes are left out: allowing them needs the warning in the settings editor.
                    ForEach(item.reasons.filter { policy.action($0) != .allow && $0 != .codes }) { c in
                        Button("Always allow \(c.title.lowercased()) here") { model.alwaysAllow(c, in: chatID) }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Why a photo couldn't be cleared, in plain words (the user only).
    static func photoProblem(_ o: PhotoOutcome, canCheck: Bool) -> String? {
        if o.pending { return canCheck ? "Not checked yet" : "Couldn't be checked" }
        switch o.problem {
        case .refused?: return "Apple Intelligence wouldn't look at it"
        case .tooLarge?: return "Too large to check"
        case .unreadable?, .unsupported?: return "Couldn't be read"
        case nil: return o.notCleared ? "Couldn't be checked" : nil
        }
    }

    func reviewRow(_ item: Gate.FilterReviewItem) -> some View {
        let policy = model.filterPolicy(chatID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.from == Gate.meLabel ? "You" : item.from).font(.system(size: 12, weight: .semibold))
                Text(item.date.relative).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if item.allowedByUser { Pill(text: "Allowed by you", color: Theme.accent) }
                ForEach(item.reasons) { Pill(text: $0.title, color: item.withheld ? Theme.caution : .secondary) }
                if item.notCleared { Pill(text: "Couldn't be checked", color: Theme.caution) }
            }
            Text(item.original).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("\(model.assistantName) sees: " + (item.allowedByUser ? item.original : item.shown))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 12) {
                Button(item.allowedByUser ? "Filter again" : "Allow this message") {
                    model.setFilterAllowed(!item.allowedByUser, message: item.id, in: chatID)
                }
                // Codes are left out: allowing them needs the warning in the settings editor.
                ForEach(item.reasons.filter { policy.action($0) != .allow && $0 != .codes }) { c in
                    Button("Always allow \(c.title.lowercased()) here") { model.alwaysAllow(c, in: chatID) }
                }
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// A small rounded preview of a photo, for the user's review list.
struct PhotoThumb: View {
    let image: CGImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.12))
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}
