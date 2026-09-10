import SwiftUI
import KairoKit

/// Where the agents live, and proof of whether they are answering.
///
/// This screen exists because the app is usable either way. Without it, a phone
/// that has quietly lost the backend looks exactly like one that never had it —
/// and the whole claim of the project is that five roles reasoned about your day,
/// so "did they actually?" has to be answerable.
struct BackendSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isChecking = false
    @State private var source = DataSource.current

    var body: some View {
        @Bindable var backend = model.backend

        Form {
            Section {
                Picker("Readings", selection: $source) {
                    ForEach(DataSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Data")
            } footer: {
                Text(source.detail)
            }
            .onChange(of: source) { _, new in DataSource.store(new) }

            Section {
                StatusRow(state: backend.state)
            } header: {
                Text("Status")
            } footer: {
                Text(backend.state.detail)
            }

            Section {
                TextField("http://192.168.1.10:8080", text: $backend.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Bearer token (optional)", text: $backend.token)
                Button {
                    Task {
                        isChecking = true
                        await model.backend.check()
                        if model.backend.state.isConnected {
                            await model.runArbitration()
                        }
                        isChecking = false
                    }
                } label: {
                    HStack {
                        Text("Connect")
                        if isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(isChecking)
            } header: {
                Text("Agent backend")
            } footer: {
                Text("The address of the machine running `python -m kairo`. Leave it empty "
                     + "to stay on the device. On a phone this must be the Mac's address on "
                     + "your network, not localhost — localhost on a phone is the phone.")
            }

            Section {
                LabeledContent("Serving this screen") {
                    Text(sourceLabel).foregroundStyle(.secondary)
                }
                if !model.contributingRoles.isEmpty {
                    LabeledContent("Roles that contributed") {
                        Text("\(Set(model.contributingRoles).count)").monospacedDigit()
                    }
                }
                if let last = model.backend.lastServedByBackend {
                    LabeledContent("Last answered") {
                        Text(last, style: .relative).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Readings from") {
                    Text(source.title).foregroundStyle(.secondary)
                }
            } header: {
                Text("Provenance")
            } footer: {
                Text("Kairo keeps working when the backend is gone — the arbiter also runs "
                     + "on this phone, which is what makes it usable offline. The difference "
                     + "is that the bids are no longer being reasoned about, and that is "
                     + "worth knowing rather than hiding.\n\n"
                     + "The two rows above are separate questions. The agents decide which "
                     + "nudge wins and how it is worded; where the readings come from is set "
                     + "under Data. Agents reasoning over the demo scenario still return an "
                     + "answer about a day nobody lived.")
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceLabel: String {
        switch model.arbitrationSource {
        case let .agents(recordID): "the agents · \(recordID)"
        case .onDevice:             "this phone"
        }
    }
}

private struct StatusRow: View {
    let state: BackendConnection.State

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text(state.label)
            Spacer()
            if case .checking = state { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.label)
    }

    private var tint: Color {
        switch state {
        case .onDevice:    .secondary
        case .checking:    .orange
        case .connected:   .green
        case .unreachable: .red
        }
    }
}
