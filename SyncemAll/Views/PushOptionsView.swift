import SwiftUI

/// Reusable push destination picker shown as a sheet.
struct PushOptionsView: View {
    let changeCount: Int
    let onPush: (Set<ServiceProvider>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviders: Set<ServiceProvider> = Set(ServiceProvider.allCases)

    var body: some View {
        NavigationStack {
            List {
                Section("Push to") {
                    ForEach(ServiceProvider.allCases) { provider in
                        Toggle(isOn: binding(for: provider)) {
                            HStack {
                                ServiceLogo(provider: provider, size: 16)
                                    .frame(width: 24)
                                Text(provider.displayName)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        onPush(selectedProviders)
                        dismiss()
                    } label: {
                        Text("Push \(changeCount) Changes")
                            .frame(maxWidth: .infinity)
                            .font(.body.weight(.semibold))
                    }
                    .disabled(selectedProviders.isEmpty)
                } footer: {
                    Text("This will update the selected services with your approved merge results.")
                }
            }
            .navigationTitle("Push Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func binding(for provider: ServiceProvider) -> Binding<Bool> {
        Binding(
            get: { selectedProviders.contains(provider) },
            set: { isOn in
                if isOn {
                    selectedProviders.insert(provider)
                } else {
                    selectedProviders.remove(provider)
                }
            }
        )
    }
}
