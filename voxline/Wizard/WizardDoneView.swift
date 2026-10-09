// voxline/Wizard/WizardDoneView.swift
import SwiftUI

struct WizardDoneView: View {
    let chord: HotkeyChord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're set up").font(.title.bold())
            Text("Hold **\(chord.displayName)** in any text field, talk, release. Voxline will transcribe it and paste cleaned-up text.")
                .foregroundStyle(.secondary)
            Text("Choose Settings… in the menu bar to change the hotkey, pick a different mic, or add words Voxline should recognize.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
