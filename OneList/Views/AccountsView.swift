import os
import SwiftUI

private let logger = Logger(subsystem: "com.onelist", category: "Accounts")

struct AccountsView: View {
    let taskServices: [any TaskServiceProtocol]
    let eventServices: [any EventServiceProtocol]
    var onReconnect: ((ServiceProvider) -> Void)?
    @State private var connectionStatus: [ServiceProvider: Bool] = [:]
    @State private var providerEmails: [ServiceProvider: String] = [:]
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        List {
            Section {
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
        let isConnected = connectionStatus[provider] == true
        let statusText = isConnected ? "Connected" : "Not connected"
        let subtitle = isConnected ? (providerEmails[provider] ?? statusText) : providerSubtitle(provider)

        HStack {
            Image(systemName: provider.iconSystemName)
                .font(.title3)
                .foregroundStyle(providerColor(provider))
                .frame(width: 28)
                .padding(.trailing, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                if isConnected, let email = providerEmails[provider] {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(providerColor(provider))
                } else {
                    Text(providerSubtitle(provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if isConnected {
                if provider != .apple {
                    Button {
                        Task {
                            await reconnectProvider(provider)
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Reconnect \(provider.displayName)")
                }
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Connected")
            } else {
                Button("Connect") {
                    Task {
                        await connectProvider(provider)
                    }
                }
                .buttonStyle(.bordered)
                .tint(providerColor(provider))
                .controlSize(.small)
                .accessibilityLabel("Connect \(provider.displayName)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName), \(subtitle), \(statusText)")
    }

    private func providerColor(_ provider: ServiceProvider) -> Color {
        provider.taskServiceType.color
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
                if let taskService = taskServices.first(where: { $0.serviceType == .appleReminders }) {
                    try await taskService.connect()
                }
                if let eventService = eventServices.first(where: { $0.serviceType == .appleCalendar }) {
                    try await eventService.connect()
                }
            case .google:
                try await GoogleAuthManager.shared.connect()
            case .microsoft:
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

        switch provider {
        case .apple:
            break // Apple permissions are system-managed, can't reconnect
        case .google:
            GoogleAuthManager.shared.disconnect()
        case .microsoft:
            MicrosoftAuthManager.shared.disconnect()
        }

        onReconnect?(provider)

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

            // Update emails from auth managers (fetch if missing)
            if connected {
                switch provider {
                case .apple:
                    providerEmails[provider] = "System Account"
                case .google:
                    if GoogleAuthManager.shared.userEmail == nil {
                        await GoogleAuthManager.shared.fetchUserEmail()
                    }
                    providerEmails[provider] = GoogleAuthManager.shared.userEmail ?? "Connected"
                case .microsoft:
                    if MicrosoftAuthManager.shared.userEmail == nil {
                        await MicrosoftAuthManager.shared.fetchUserEmail()
                    }
                    providerEmails[provider] = MicrosoftAuthManager.shared.userEmail ?? "Connected"
                }
            } else {
                providerEmails[provider] = nil
            }
        }
    }
}
