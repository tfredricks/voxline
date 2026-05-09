// voxline/Wizard/WizardDoneView.swift
import SwiftUI

struct WizardDoneView: View {
    let chord: HotkeyChord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're set up").font(.title.bold())
            Text("Hold **\(chord.displayName)** in any text field, talk, release. voxline will transcribe locally and paste cleaned text.")
                .foregroundStyle(.secondary)
            Text("Open Settings from the menu bar to add per-app prompts, change the chord, or pick a different mic.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
