import SwiftUI

struct SubscriptionSheet: View {
    private struct Lookup: Equatable {
        let address: String
        let url: URL?
        let scope: UUID
        let retry: Int
    }

    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    @Environment(\.dismiss) private var dismiss
    let didSubscribe: (Feed) -> Void

    @BasketState private var address = ""
    @BasketState private var result: (lookup: Lookup, preview: SubscriptionPreview)?
    @BasketState private var selectedFeedURL = ""
    @BasketState private var error: String?
    @BasketState private var lookup = false
    @BasketState private var retry = 0
    @BasketState private var saving = false
    @FocusState private var addressFocused: Bool

    private var requestedLookup: Lookup {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return Lookup(address: text, url: store.canUseAPI ? subscriptionURL(text) : nil,
                      scope: store.updateScope, retry: retry)
    }

    private func subscriptionURL(_ text: String) -> URL? {
        let address = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), host.contains("."), !host.hasSuffix("."),
              url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    private var preview: SubscriptionPreview? {
        guard let result, result.lookup == requestedLookup else { return nil }
        return result.preview
    }

    private var selectedFeed: SubscriptionPreview.Candidate? {
        preview?.feeds.first { $0.url == selectedFeedURL }
    }

    private var alreadySubscribed: Bool {
        guard let preview else { return false }
        let url = selectedFeed?.url ?? preview.url
        let checked = selectedFeed?.already_subscribed ?? (preview.feeds.isEmpty && preview.already_subscribed == true)
        return checked || store.library.feeds.values.contains { $0.url == url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 11) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(style.accent)
                        .frame(width: 38, height: 38)
                        .background(style.color(BasketTokens.subtle), in: .rect(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add subscription").font(.title2.weight(.semibold))
                        Text("Find and preview a website’s updates.")
                            .foregroundStyle(style.color(BasketTokens.muted))
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Website or feed URL").fontWeight(.semibold).accessibilityHidden(true)
                    TextField("Website or feed URL", text: $address, prompt: Text("https://example.com"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($addressFocused)
                        .disabled(saving)
                }
                if lookup {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text("Checking the website and looking for feeds…")
                    }.foregroundStyle(style.color(BasketTokens.muted))
                }
                if let preview { review(preview) }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    if preview == nil && requestedLookup.url != nil {
                        Button("Retry lookup") { retry += 1 }.buttonStyle(BasketButton())
                    }
                }
            }.padding(20)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(BasketButton())
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                if alreadySubscribed {
                    Label("Already subscribed", systemImage: "checkmark.circle")
                        .foregroundStyle(style.color(BasketTokens.muted))
                } else if let preview {
                    Button(saving ? "Adding…" : (preview.feeds.isEmpty ? "Follow website" : "Subscribe")) { saving = true }
                        .buttonStyle(BasketButton(primary: true))
                        .disabled(saving || !store.canUseAPI || (!preview.feeds.isEmpty && selectedFeed == nil))
                }
            }.padding(.horizontal, 20).padding(.vertical, 11)
        }
        .frame(width: 510)
        .background(style.color(BasketTokens.surface))
        .interactiveDismissDisabled(saving)
        .onAppear { addressFocused = true }
        .task(id: requestedLookup) { [request = requestedLookup] in await findFeeds(request) }
        .task(id: saving) {
            if saving { await confirmSubscription() }
        }
    }

    private func review(_ preview: SubscriptionPreview) -> some View {
        let publisher = preview.publisher
        let card = PublisherCardStyle.preview
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: CGFloat(card.gap)) {
                Text(publisher.monogram)
                    .font(.system(size: CGFloat(card.badgeFont), weight: .semibold, design: .serif))
                    .foregroundStyle(style.color(PublisherCardStyle.badgeText))
                    .frame(width: CGFloat(card.badgeSize), height: CGFloat(card.badgeSize))
                    .background(style.color(PublisherCardStyle.badgeBackground(style)),
                                in: .rect(cornerRadius: CGFloat(card.badgeRadius)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(publisher.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Text(publisher.domain).foregroundStyle(style.color(PublisherCardStyle.secondaryText)).lineLimit(1)
                    if !preview.description.isEmpty {
                        Text(preview.description).foregroundStyle(style.color(PublisherCardStyle.secondaryText)).lineLimit(3)
                    }
                }.textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CGFloat(card.horizontalInset))
            .padding(.vertical, CGFloat(card.verticalInset))
            .background(style.color(PublisherCardStyle.background), in: .rect(cornerRadius: CGFloat(card.cornerRadius)))

            if let feed = selectedFeed {
                VStack(alignment: .leading, spacing: 5) {
                    if preview.feeds.count > 1 {
                        Picker("Feed", selection: $selectedFeedURL) {
                            ForEach(preview.feeds) { candidate in Text(candidate.title).tag(candidate.url) }
                        }.disabled(saving)
                    } else {
                        Text(feed.title).fontWeight(.semibold).lineLimit(2)
                    }
                    Text("\(feed.format) · \(feed.url)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(style.color(BasketTokens.muted)).textSelection(.enabled).lineLimit(2)
                }
            } else if preview.feeds.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No RSS or Atom feed found").fontWeight(.semibold)
                    Text("Follow the website to check for changes on this page.")
                        .foregroundStyle(style.color(BasketTokens.muted))
                    Button("Enter a feed URL instead") { address = ""; addressFocused = true }
                        .buttonStyle(.link).disabled(saving)
                }
            }
        }
    }

    private func findFeeds(_ request: Lookup) async {
        guard !Task.isCancelled, !saving, request == requestedLookup else { return }
        lookup = false
        result = nil
        error = nil
        guard let url = request.url else {
            if store.canUseAPI && !request.address.isEmpty {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, request == requestedLookup else { return }
                error = "Enter a complete website or feed URL."
            }
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, request == requestedLookup else { return }
            lookup = true
            let preview = try await store.previewSubscription(url)
            guard !Task.isCancelled, request == requestedLookup else { return }
            selectedFeedURL = preview.feeds.first?.url ?? ""
            result = (request, preview)
            lookup = false
        } catch {
            guard !Task.isCancelled, request == requestedLookup else { return }
            self.error = error.localizedDescription
            lookup = false
        }
    }

    private func confirmSubscription() async {
        guard let preview, !alreadySubscribed else { saving = false; return }
        error = nil
        do {
            let feed = try await store.subscribe(url: selectedFeed?.url ?? preview.url,
                                                 title: selectedFeed?.title ?? preview.title,
                                                 website: preview.feeds.isEmpty)
            guard !Task.isCancelled else { return }
            didSubscribe(feed)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            saving = false
        }
    }
}
