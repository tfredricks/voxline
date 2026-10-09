// voxline/Wizard/WizardStep.swift
enum WizardStep: CaseIterable {
    case welcome
    case permissions
    case apiKey
    case modelDownload
    case done

    static let first: WizardStep = .welcome

    /// The steps one wizard run walks through. The engine step
    /// (`.modelDownload`) is dropped when the engine is already ready.
    static func sequence(skippingEngineStep: Bool) -> [WizardStep] {
        skippingEngineStep ? allCases.filter { $0 != .modelDownload } : allCases
    }

    var next: WizardStep? { next(in: Self.allCases) }

    var previous: WizardStep? { previous(in: Self.allCases) }

    func next(in steps: [WizardStep]) -> WizardStep? {
        guard let i = steps.firstIndex(of: self), i + 1 < steps.count else { return nil }
        return steps[i + 1]
    }

    func previous(in steps: [WizardStep]) -> WizardStep? {
        guard let i = steps.firstIndex(of: self), i > 0 else { return nil }
        return steps[i - 1]
    }
}
