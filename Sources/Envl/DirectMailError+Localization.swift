import Foundation

extension DirectMailError {
    func message(language: AppLanguage) -> String {
        switch self {
        case .unconfigured(let provider):
            return L10n.text("%@ sign-in is not configured in this build.", language: language, arguments: [provider.name])
        case .status(429, .some(let seconds)):
            return L10n.text("The mail provider is busy. Try again in %d seconds.", language: language, arguments: [seconds])
        case .status(let code, _) where code != 403 && code != 429:
            return L10n.text("The mail provider could not complete this operation (HTTP %d). Please try again.", language: language, arguments: [code])
        case .tokenStorage(let code):
            return L10n.text("Could not access this connection in Keychain (%d).", language: language, arguments: [code])
        default:
            return L10n.text(errorDescription ?? "The mail provider returned an unreadable response. Please try again.", language: language)
        }
    }
}
