import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    let subscriptionManager = SubscriptionManager.shared
    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    featureList
                    productButtons
                    restoreButton
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle("OneList Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                if subscriptionManager.products.isEmpty {
                    await subscriptionManager.loadProducts()
                }
            }
            .alert("Purchase Error", isPresented: .init(
                get: { subscriptionManager.purchaseError != nil },
                set: { if !$0 { subscriptionManager.purchaseError = nil } }
            )) {
                Button("OK") { subscriptionManager.purchaseError = nil }
            } message: {
                Text(subscriptionManager.purchaseError ?? "")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Text("Unlock Unlimited Syncing")
                .font(.title2.weight(.bold))

            Text("Your free trial of \(SubscriptionManager.freeSyncLimit) syncs has ended. Subscribe to keep your tasks and events in sync across all your services.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Features

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureRow(icon: "arrow.triangle.2.circlepath", text: "Unlimited pulls and pushes")
            featureRow(icon: "checklist", text: "Sync tasks across Apple, Google, and Microsoft")
            featureRow(icon: "calendar", text: "Sync calendar events across all services")
            featureRow(icon: "person.2", text: "Human-in-the-loop conflict resolution")
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Products

    private var productButtons: some View {
        VStack(spacing: 12) {
            if subscriptionManager.products.isEmpty {
                ProgressView()
                    .frame(height: 100)
            } else {
                ForEach(subscriptionManager.products, id: \.id) { product in
                    productButton(product)
                }
            }
        }
    }

    private func productButton(_ product: Product) -> some View {
        let isYearly = product.id == SubscriptionManager.yearlyID
        return Button {
            guard !isPurchasing else { return }
            isPurchasing = true
            Task {
                let success = await subscriptionManager.purchase(product)
                isPurchasing = false
                if success { dismiss() }
            }
        } label: {
            VStack(spacing: 4) {
                HStack {
                    Text(isYearly ? "Yearly" : "Monthly")
                        .font(.headline)
                    Spacer()
                    Text(product.displayPrice)
                        .font(.headline)
                }
                HStack {
                    if isYearly {
                        Text("Best value")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    if let sub = product.subscription {
                        Text("per \(sub.subscriptionPeriod.unit == .month ? "month" : "year")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isYearly ? .blue : .secondary)
        .disabled(isPurchasing)
    }

    // MARK: - Restore

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task { await subscriptionManager.restore() }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
