import SwiftUI

struct LeaveATipView: View {
    @Environment(ProEntitlement.self) private var entitlement
    @State private var purchasing = false
    @State private var message: String?
    @State private var retryOffer: ProOffer?

    var body: some View {
        Form {
            Section {
                Text(verbatim: String(localized: "pro.tip.body",
                                      defaultValue: "Tips are optional, repeatable support for development. They do not unlock Supporter or artwork.",
                                      comment: "Consumable tips support development only, never Supporter or artwork."))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach([ProOffer.tipSmall, .tipMedium, .tipLarge, .tipExtra], id: \.self) { offer in
                    Button { purchase(offer) } label: {
                        if let product = entitlement.products[offer] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: product.displayName)
                                Text(verbatim: product.displayPrice).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        } else { ProgressView() }
                    }
                    .disabled(purchasing || entitlement.products[offer] == nil)
                }
                if purchasing { ProgressView() }
                if let message { Text(verbatim: message).font(.footnote) }
                if let retryOffer { Button("Retry") { purchase(retryOffer) }.disabled(purchasing) }
                if retryOffer == nil && !entitlement.isLoadingProducts && (entitlement.productLoadingFailed || !entitlement.products.isEmpty) &&
                    [ProOffer.tipSmall, .tipMedium, .tipLarge, .tipExtra].contains(where: { entitlement.products[$0] == nil }) {
                    Text(verbatim: SupportStoreCopy.loadFailed).font(.footnote)
                    Button("Retry") {
                        message = nil
                        retryOffer = nil
                        Task {
                            try? await entitlement.loadProducts()
                        }
                    }.disabled(purchasing)
                }
            }
        }
        .navigationTitle("Leave a Tip")
        .task {
            if entitlement.products.isEmpty { try? await entitlement.loadProducts() }
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
                message = SupportStoreCopy.message(for: result, thankingTip: true)
                if result == .unavailable || result == .unverified { retryOffer = offer }
            } catch {
                message = error.localizedDescription
                retryOffer = offer
            }
        }
    }
}

