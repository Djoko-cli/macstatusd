import Foundation

/// État de l'agent du daemon auprès de macOS (`SMAppService.Status`), tel que le publient `/status` (champ `service`)
/// et `--status-service`. Le type est pur : les appels à SMAppService vivent dans `ServiceRegistry` (cible de
/// l'exécutable), jamais appelé par un test.
public enum ServiceState: String {
    case enabled
    case requiresApproval = "requires-approval"
    case notRegistered = "not-registered"
    case notFound = "not-found"
    case unknown

    /// `rawStatus` : valeur de `SMAppService.Status` (0 non enregistré, 1 activé, 2 à autoriser, 3 introuvable).
    /// Toute autre valeur, y compris une valeur ajoutée par un macOS futur, donne `unknown`.
    public init(rawStatus: Int) {
        switch rawStatus {
        case 0: self = .notRegistered
        case 1: self = .enabled
        case 2: self = .requiresApproval
        case 3: self = .notFound
        default: self = .unknown
        }
    }

    /// Phrase affichée à l'utilisateur.
    public var message: String {
        switch self {
        case .enabled: return "activé"
        case .requiresApproval: return "à autoriser : Réglages Système > Général > Ouverture et extensions"
        case .notRegistered: return "non enregistré : lancer macstatusd --register"
        case .notFound: return "introuvable : l'app doit être dans ~/Applications ou /Applications"
        case .unknown: return "inconnu"
        }
    }

    /// Phrase pour un code brut de SMAppService : comme `message`, avec le code pour un état inconnu
    /// (un enum à valeurs brutes ne peut pas le porter).
    public static func message(rawStatus: Int) -> String {
        let state = ServiceState(rawStatus: rawStatus)
        return state == .unknown ? "inconnu (code \(rawStatus))" : state.message
    }

    /// Code de sortie des options `--register`, `--unregister` et `--status-service`.
    public var exitCode: Int32 {
        switch self {
        case .enabled: return 0
        case .requiresApproval: return 3
        case .notRegistered: return 4
        case .notFound: return 5
        case .unknown: return 1
        }
    }
}

/// Comment le binaire a été lancé.
public enum LaunchMode: Equatable {
    /// Par launchd, comme agent enregistré (`--agent`) : lance le daemon.
    case agent
    /// Par un double-clic dans le Finder : enregistre l'agent, montre une alerte, quitte.
    case finder
    /// Par une ligne de commande ; sans argument, lance le daemon comme avant.
    case commandLine

    /// Un lancement par le Finder tourne sous un travail launchd dont le nom commence par `application.`
    /// (relevé à l'essai du 09/11). L'agent enregistré, lui, a pour `XPC_SERVICE_NAME` son label.
    public static func decide(arguments: [String], environment: [String: String]) -> LaunchMode {
        if arguments.contains("--agent") { return .agent }
        if arguments.isEmpty, environment["XPC_SERVICE_NAME"]?.hasPrefix("application.") == true { return .finder }
        return .commandLine
    }
}
