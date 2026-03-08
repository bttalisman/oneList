import os
import SwiftUI

private let logger = Logger(subsystem: "com.onelist", category: "Accounts")

struct AccountsView: View {
    let taskServices: [any TaskServiceProtocol]
    let eventServices: [any EventServiceProtocol]
    var onReconnect: ((ServiceProvider) -> Void)?
    @State private var connectionStatus: [ServiceProvider: Bool] = [:]
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        List {
            Section("Accounts") {
                ForEach(ServiceProvider.allCases) { provider in
                    providerRow(provider)
                }
            }

            Section {
                Text("OneList connects to your existing task and calendar services and helps you keep them in sync. It never modifies anything without your approval.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Accounts")
        .task { await refreshStatus() }
        .alert("Connection Failed", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: ServiceProvider) -> some View {
        HStack {
            Image(systemName: provider.iconSystemName)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(provider.displayName)
                Text(providerSubtitle(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connectionStatus[provider] == true {
                HStack(spacing: 12) {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                    Button {
                        Task {
                            await reconnectProvider(provider)
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Connect") {
                    Task {
                        await connectProvider(provider)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func providerSubtitle(_ provider: ServiceProvider) -> String {
        switch provider {
        case .apple: "Reminders & Calendar"
        case .google: "Tasks & Calendar"
        case .microsoft: "To Do & Calendar"
        }
    }

    private func connectProvider(_ provider: ServiceProvider) async {
        logger.info("Connecting \(provider.displayName)...")
        do {
            switch provider {
            case .apple:
                // Apple needs separate permission requests for Reminders and Calendar
                if let taskService = taskServices.first(where: { $0.serviceType == .appleReminders }) {
                    try await taskService.connect()
                }
                if let eventService = eventServices.first(where: { $0.serviceType == .appleCalendar }) {
                    try await eventService.connect()
                }
            case .google:
                // Single OAuth flow via shared auth manager handles both
                try await GoogleAuthManager.shared.connect()
            case .microsoft:
                // Single OAuth flow via shared auth manager handles both
                try await MicrosoftAuthManager.shared.connect()
            }
            logger.info("\(provider.displayName) connected successfully")
        } catch {
            logger.error("\(provider.displayName) connection failed: \(error.localizedDescription)")
            errorMessage = "\(provider.displayName): \(error.localizedDescription)"
            showingError = true
        }
        await refreshStatus()
    }

    private func reconnectProvider(_ provider: ServiceProvider) async {
        logger.info("Reconnecting \(provider.displayName)...")

        // Disconnect both services for this provider
        switch provider {
        case .apple:
            taskServices.first(where: { $0.serviceType == .appleReminders })?.disconnect()
            eventServices.first(where: { $0.serviceType == .appleCalendar })?.disconnect()
        case .google:
            GoogleAuthManager.shared.disconnect()
        case .microsoft:
            MicrosoftAuthManager.shared.disconnect()
        }

        // Notify parent to clear sessions and links
        onReconnect?(provider)

        // Re-authenticate
        await connectProvider(provider)
    }

    private func refreshStatus() async {
        logger.info("Refreshing connection status...")
        for provider in ServiceProvider.allCases {
            let connected: Bool
            switch provider {
            case .apple:
                let taskConnected = await taskServices.first(where: { $0.serviceType == .appleReminders })?.isConnected ?? false
                let eventConnected = await eventServices.first(where: { $0.serviceType == .appleCalendar })?.isConnected ?? false
                connected = taskConnected && eventConnected
            case .google:
                connected = await GoogleAuthManager.shared.isConnected
            case .microsoft:
                connected = await MicrosoftAuthManager.shared.isConnected
            }
            logger.info("  \(provider.displayName): \(connected ? "connected" : "not connected")")
            connectionStatus[provider] = connected
        }
    }
}
