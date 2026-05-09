import SwiftUI

struct ModesSettingsView: View {

    @State private var vm: ModesSettingsViewModel
    @State private var selection: Mode.ID?
    @State private var showingRunningApps = false

    init(vm: ModesSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                modesList
                    .frame(minWidth: 200)
                if let mode = bindingForSelection() {
                    ModeEditor(mode: mode)
                        .frame(minWidth: 320)
                        .padding()
                } else {
                    Text("Select a mode to edit")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 320)
                }
            }
            Divider()
            HStack {
                Button { vm.addNewDraft() } label: { Image(systemName: "plus") }
                Button { showingRunningApps = true } label: { Label("Add from running apps", systemImage: "rectangle.stack") }
                Button {
                    if let selection, let i = vm.modes.firstIndex(where: { $0.id == selection }) {
                        vm.delete(at: IndexSet(integer: i))
                    }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
                Button("Save") { saveWithErrorBanner() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
            if let err = vm.lastError {
                Text(err).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }
        }
        .frame(width: 720, height: 480)
        .sheet(isPresented: $showingRunningApps) {
            RunningAppsPickerView { entry in
                vm.addOrUpdate(.newDraft(bundleID: entry.bundleID, displayName: entry.displayName))
                showingRunningApps = false
            } cancel: {
                showingRunningApps = false
            }
        }
    }

    private var modesList: some View {
        List(selection: $selection) {
            ForEach(vm.modes) { mode in
                VStack(alignment: .leading) {
                    Text(mode.displayName.isEmpty ? "(unnamed)" : mode.displayName)
                    Text(mode.bundleID).font(.caption).foregroundStyle(.secondary)
                }
                .tag(mode.id)
            }
        }
    }

    private func bindingForSelection() -> Binding<Mode>? {
        guard
            let selection,
            let i = vm.modes.firstIndex(where: { $0.id == selection })
        else { return nil }
        return Binding(
            get: { vm.modes[i] },
            set: { vm.modes[i] = $0 }
        )
    }

    private func saveWithErrorBanner() {
        do {
            try vm.save()
            vm.lastError = nil
        } catch {
            vm.lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}

private struct ModeEditor: View {
    @Binding var mode: Mode
    var body: some View {
        Form {
            TextField("Display name", text: $mode.displayName)
            TextField("Bundle ID (or *)", text: $mode.bundleID).monospaced()
            Section("Prompt") {
                TextEditor(text: $mode.prompt).frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RunningAppsPickerView: View {
    let onPick: (RunningAppEntry) -> Void
    let cancel: () -> Void

    @State private var apps: [RunningAppEntry] = []

    var body: some View {
        VStack {
            Text("Pick a running app").font(.headline).padding(.top)
            List(apps) { app in
                Button {
                    onPick(app)
                } label: {
                    VStack(alignment: .leading) {
                        Text(app.displayName)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 420, height: 360)
        .onAppear { apps = RunningAppsHelper.snapshot() }
    }
}
