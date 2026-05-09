// voxline/Wizard/WizardStep.swift
enum WizardStep: CaseIterable {
    case welcome
    case permissions
    case apiKey
    case modelDownload
    case done

    static let first: WizardStep = .welcome

    var next: WizardStep? {
        let all = WizardStep.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    var previous: WizardStep? {
        let all = WizardStep.allCases
        guard let i = all.firstIndex(of: self), i > 0 else { return nil }
        return all[i - 1]
    }
}
