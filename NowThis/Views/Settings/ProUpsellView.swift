import SwiftUI
import StoreKit

/// Optional support remains within Settings. Functional iOS access is permanent.
struct ProUpsellView: View {
    @Environment(ProEntitlement.self) private var entitlement
    @State private var purchasing = false
    @State private var message: String?
    @State private var retryOffer: ProOffer?
    @State private var managing = false
    @State private var confirmingLifetime = false
    @ScaledMetric(relativeTo: .caption) private var iconPreviewMinimumWidth: CGFloat = 80

    private var presentation: SupportPurchasePresentation {
        SupportPurchasePresentation.make(snapshot: entitlement.snapshot, at: Date())
    }

    var body: some View {
        Section("Support Development") {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: String(localized: "pro.support.title", defaultValue: "Help support continued development",
                                      comment: "Heading: optional support funds ongoing development. Keep NowThis and Supporter unchanged."))
                    .font(.headline)
                Text(verbatim: String(localized: "pro.ios.body",
                                      defaultValue: "All iOS productivity features, including future additions, are included with the app. Supporter is an optional way to support continued development.",
                                      comment: "Permanent promise: all functional iOS features, including future ones, require no Supporter. Icons are optional cosmetics."))
                Text(verbatim: String(localized: "pro.watch.body",
                                      defaultValue: "Viewing tasks and using complications on Apple Watch are always free. Supporter adds checking off and adding tasks on Apple Watch, including by voice, plus supporter app icons.",
                                      comment: "Watch viewing and complications are permanently free. Only Watch task editing and cosmetic icons are paid benefits."))
                Text(verbatim: String(localized: "pro.artwork.body",
                                      defaultValue: "New supporter artwork arrives each year. Subscribers keep collections earned during paid periods. Lifetime Supporter includes all current and future Supporter features and artwork.",
                                      comment: "Paid-period artwork stays owned after expiry; lifetime includes all future Supporter benefits and art."))
                Text(verbatim: String(localized: "pro.legacy.body",
                                      defaultValue: "Pro has been renamed to Supporter. Previous Pro and Apple Watch unlock purchases have automatically become Lifetime Supporter, including all current and future Supporter features and artwork. No subscription or repurchase is needed.",
                                      comment: "Explicit rename announcement: original Pro and Watch unlock purchases automatically become Lifetime Supporter with all future benefits, without paying again."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(verbatim: String(localized: "pro.support.body",
                                      defaultValue: "NowThis has no ads and no tracking. Becoming a Supporter helps fund continued development.",
                                      comment: "Optional support funds development; no ads or tracking."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)

            artworkPreview

            if entitlement.isUnlocked && entitlement.snapshot.isUnlocked(at: Date()) {
                Label {
                    Text(entitlement.snapshot.access.supportStatus)
                } icon: { Image(systemName: "checkmark.seal.fill") }
            }
            if let subscription = entitlement.snapshot.subscription {
                subscriptionStatus(subscription)
            }

            ForEach(presentation.proOffers, id: \.self) { offer in
                Button {
                    if offer == .lifetime && presentation.requiresLifetimeRenewalNotice {
                        confirmingLifetime = true
                    } else { purchase(offer) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(offer.supportTitle).font(.headline)
                        if offer == .lifetime { Text("One-time purchase").font(.caption) }
                        if let product = entitlement.products[offer] {
                            Text(verbatim: offer.billingPrice(product.displayPrice))
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if entitlement.isLoadingProducts {
                            ProgressView()
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                }
                .disabled(purchasing || entitlement.products[offer] == nil)
                .accessibilityHint(String(localized: "pro.buy.a11y.hint",
                                          defaultValue: "Optional support. Adds Apple Watch task editing and supporter app icons.",
                                          comment: "Spoken purchase hint. Functional iOS and Watch viewing remain free."))
            }

            if purchasing { ProgressView() }
            if let message { Text(verbatim: message).font(.footnote).foregroundStyle(.secondary) }
            if let retryOffer {
                Button("Retry") { purchase(retryOffer) }.disabled(purchasing)
            }
            if retryOffer == nil && !entitlement.isLoadingProducts && (entitlement.productLoadingFailed || !entitlement.products.isEmpty) &&
                presentation.proOffers.contains(where: { entitlement.products[$0] == nil }) {
                Text(verbatim: SupportStoreCopy.loadFailed).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { reloadProducts() }.disabled(purchasing)
            }

            Button("Restore Purchases") {
                purchasing = true
                message = nil
                retryOffer = nil
                Task {
                    defer { purchasing = false }
                    do { try await entitlement.restorePurchases() }
                    catch { message = error.localizedDescription }
                }
            }
            .disabled(purchasing)
            .accessibilityHint("Restores a previous NowThis Supporter or Pro purchase.")

            if presentation.showsManageSubscription {
                Button("Manage Subscription") { managing = true }
            }
            NavigationLink("Leave a Tip") { LeaveATipView() }
            HStack {
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Spacer()
                Link("Privacy Policy", destination: URL(string: "https://nowthis.app/privacy")!)
            }
            .font(.footnote)
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .confirmationDialog("One-time purchase", isPresented: $confirmingLifetime, titleVisibility: .visible) {
            Button("Continue") { purchase(.lifetime) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: String(localized: "pro.lifetime.notice",
                                  defaultValue: "Buying lifetime does not cancel your subscription. Manage your subscription to stop future renewal charges.",
                                  comment: "Before lifetime purchase by a renewing subscriber: subscription renewal continues until separately cancelled."))
        }
        .task {
            if entitlement.products.isEmpty { try? await entitlement.loadProducts() }
        }
    }

    private var artworkPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: String(localized: "icon.preview.title", defaultValue: "Supporter icons", comment: "Heading for the optional Supporter app icon preview gallery."))
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: iconPreviewMinimumWidth), spacing: 16, alignment: .top)], spacing: 12) {
                ForEach(AppIconCatalog.icons.filter { $0.collectionID != nil }, id: \.id) { icon in
                    VStack(spacing: 6) {
                        Image(icon.previewAssetName)
                            .resizable().scaledToFit()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .accessibilityHidden(true)
                        Text(icon.title).font(.caption)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .accessibilityElement(children: .combine)
                }
            }
            Text(verbatim: String(localized: "icon.preview.body", defaultValue: "Choose a look you love. Earned icons are yours to keep, even after a subscription ends.", comment: "Optional cosmetic reward. Earned artwork remains owned after a paid subscription expires."))
                .font(.footnote).foregroundStyle(.secondary)
            NavigationLink {
                AppIconPickerView()
            } label: {
                Text(verbatim: String(localized: "icon.preview.action", defaultValue: "Preview App Icons", comment: "Opens the app icon picker so everyone can preview the designs."))
            }
            .accessibilityHint(String(localized: "icon.preview.hint", defaultValue: "Shows all app icon designs, including previews of Supporter artwork.", comment: "Spoken hint for the icon preview navigation link."))
            .accessibilityIdentifier("preview-app-icons")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func subscriptionStatus(_ status: VerifiedSubscriptionStatus) -> some View {
        if presentation.usesLifetimeSubscriptionCopy {
            Text(verbatim: String(localized: "pro.status.lifetime.subscription",
                                  defaultValue: "Lifetime Supporter continues regardless of this separate subscription. Manage your subscription to stop future renewal charges.",
                                  comment: "Lifetime owners retain permanent Supporter even if a separate subscription expires or has a billing issue. Subscription cancellation is separate."))
                .font(.footnote)
        } else if status.state == .grace {
            Text(verbatim: String(localized: "pro.status.grace",
                                  defaultValue: "Your payment needs attention. Supporter remains available through the grace period.",
                                  comment: "Verified billing grace keeps Supporter temporarily active."))
                .font(.footnote)
        } else if status.state == .billingRetry {
            Text(verbatim: String(localized: "pro.status.retry",
                                  defaultValue: "Your subscription payment needs attention. Manage your subscription to check billing.",
                                  comment: "Billing retry without grace does not extend Supporter access."))
                .font(.footnote)
        }
        if status.state == .subscribed && Date() < status.expirationDate {
            Text(verbatim: String(format: !status.willAutoRenew && presentation.usesLifetimeSubscriptionCopy
                                  ? String(localized: "pro.status.lifetime.ends", defaultValue: "Your separate subscription ends on %@. Lifetime Supporter continues.", comment: "Cancellation ends only the separate subscription, never purchased lifetime Supporter. Placeholder is its expiry date.")
                                  : status.willAutoRenew
                                  ? String(localized: "pro.status.renews", defaultValue: "Renews on %@.", comment: "Subscription renewal date.")
                                  : String(localized: "pro.status.ends", defaultValue: "Access ends on %@.", comment: "Paid access expiry date after cancellation."),
                                  status.expirationDate.formatted(date: .abbreviated, time: .omitted)))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func reloadProducts() {
        message = nil
        retryOffer = nil
        Task {
            try? await entitlement.loadProducts()
        }
    }

    private func purchase(_ offer: ProOffer) {
        purchasing = true
        message = nil
        retryOffer = nil
        Task {
            defer { purchasing = false }
            do {
                let result = try await entitlement.purchase(offer)
                message = SupportStoreCopy.message(for: result, thankingTip: false)
                if result == .unavailable || result == .unverified { retryOffer = offer }
            } catch {
                message = error.localizedDescription
                retryOffer = offer
            }
        }
    }
}

extension ProOffer {
    var supportTitle: LocalizedStringResource {
        switch self {
        case .monthly: "Monthly"
        case .annual: "Annual"
        case .lifetime: "Lifetime"
        default: "Leave a Tip"
        }
    }

    func billingPrice(_ price: String) -> String {
        let format: String
        switch self {
        case .monthly:
            format = String(localized: "pro.monthly.price", defaultValue: "%@ per month. Renews automatically.", comment: "Full localized monthly charge; automatically renewing.")
        case .annual:
            format = String(localized: "pro.annual.price", defaultValue: "%@ per year, billed annually. Renews automatically.", comment: "Full annual charge, not a monthly equivalent; automatically renewing.")
        default:
            format = String(localized: "pro.lifetime.price", defaultValue: "%@ once. No renewal.", comment: "Full lifetime one-time charge.")
        }
        return String(format: format, price)
    }
}

private extension ProAccessKind {
    var supportStatus: LocalizedStringResource {
        switch self {
        case .monthly: LocalizedStringResource("pro.status.monthly", defaultValue: "Monthly Supporter — thank you!", comment: "Verified monthly supporter status.")
        case .annual: LocalizedStringResource("pro.status.annual", defaultValue: "Annual Supporter — thank you!", comment: "Verified annual supporter status.")
        default: LocalizedStringResource("pro.status.lifetime", defaultValue: "Lifetime Supporter — thank you!", comment: "Verified lifetime supporter status, including existing owners.")
        }
    }
}

enum SupportStoreCopy {
    static var loadFailed: String {
        String(localized: "pro.error.loadFailed", defaultValue: "The App Store couldn't load support options. Please try again in a moment.", comment: "Store product loading failed or products are unavailable. Offer retry without assuming a connection problem.")
    }

    static func message(for result: ProPurchaseResult, thankingTip: Bool) -> String? {
        switch result {
        case .verified(let transaction):
            guard thankingTip, transaction.revocationDate == nil else { return nil }
            return String(localized: "pro.tip.thanks", defaultValue: "Thank you for supporting NowThis!", comment: "Thank-you only after a verified tip, never pending or cancelled.")
        case .pending:
            return String(localized: "pro.pending", defaultValue: "Purchase awaiting approval. Access updates after verification.", comment: "Pending purchase is not a successful purchase.")
        case .unverified:
            return String(localized: "pro.unverified", defaultValue: "The purchase could not be verified. Try Restore Purchases.", comment: "Unverified purchase grants no benefits.")
        case .unavailable: return loadFailed
        case .cancelled: return nil
        }
    }
}
