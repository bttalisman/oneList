import Foundation
import os
import StoreKit

private let logger = Logger(subsystem: "com.onelist", category: "Subscription")

@MainActor
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    // MARK: - Product IDs

    static let monthlyID = "com.onelist.pro.monthly"
    static let yearlyID = "com.onelist.pro.yearly"

    // MARK: - State

    #if DEBUG
    private static let devOverrideKey = "OneList_DevProOverride"
    var devProOverride: Bool {
        get { UserDefaults.standard.bool(forKey: Self.devOverrideKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.devOverrideKey) }
    }
    #endif

    var isProUser = false
    var products: [Product] = []
    var purchaseError: String?

    // MARK: - Trial

    private static let syncCountKey = "OneList_SyncCount"
    static let freeSyncLimit = 10

    var syncCount: Int {
        get { UserDefaults.standard.integer(forKey: Self.syncCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.syncCountKey) }
    }

    var freeTrialRemaining: Int {
        max(0, Self.freeSyncLimit - syncCount)
    }

    var hasTrialSyncsLeft: Bool {
        syncCount < Self.freeSyncLimit
    }

    var isPro: Bool {
        #if DEBUG
        if devProOverride { return true }
        #endif
        return isProUser
    }

    var canSync: Bool {
        isPro || hasTrialSyncsLeft
    }

    // MARK: - Init

    private var updateTask: Task<Void, Never>?

    private init() {
        updateTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    // MARK: - Load Products

    func loadProducts() async {
        do {
            let storeProducts = try await Product.products(for: [
                Self.monthlyID,
                Self.yearlyID,
            ])
            products = storeProducts.sorted { $0.price < $1.price }
            logger.info("Loaded \(storeProducts.count) products")
        } catch {
            logger.error("Failed to load products: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async -> Bool {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlement()
                logger.info("Purchase successful: \(product.id)")
                return true
            case .userCancelled:
                logger.info("User cancelled purchase")
                return false
            case .pending:
                logger.info("Purchase pending approval")
                return false
            @unknown default:
                return false
            }
        } catch {
            logger.error("Purchase failed: \(error.localizedDescription)")
            purchaseError = error.localizedDescription
            return false
        }
    }

    // MARK: - Restore

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    // MARK: - Entitlement Check

    func refreshEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                if transaction.productID == Self.monthlyID || transaction.productID == Self.yearlyID {
                    isProUser = true
                    logger.info("Pro entitlement active: \(transaction.productID)")
                    return
                }
            }
        }
        isProUser = false
        logger.info("No active pro entitlement")
    }

    // MARK: - Record Sync

    func recordSync() {
        if !isPro {
            syncCount += 1
            logger.info("Free sync used: \(self.syncCount)/\(Self.freeSyncLimit)")
        }
    }

    // MARK: - Helpers

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if let transaction = try? checkVerified(result) {
                await transaction.finish()
                await refreshEntitlement()
            }
        }
    }

    enum StoreError: LocalizedError {
        case verificationFailed

        var errorDescription: String? {
            "Transaction verification failed."
        }
    }
}
