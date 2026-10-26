import Foundation

/// Décision « la session de ce processus est-elle celle de la console ? », sans rien lire du
/// système : l'exécutable lui passe ce qu'il a lu (`IOConsoleUsers`, `CGSessionCopyCurrentDictionary`).
///
/// Ordre des sources :
/// 1. `IOConsoleUsers` répond quand une de ses entrées est à la console. Cette entrée fait foi :
///    à un autre uid, la console est occupée par quelqu'un d'autre, et c'est un blocage (changement
///    rapide d'utilisateur) ;
/// 2. sinon (registre introuvable, propriété absente, liste vide, aucune entrée à la console), la
///    session graphique courante dit elle-même si elle est à la console ;
/// 3. sinon, rien ne répond : on laisse passer. Bloquer sur une lecture muette couperait la
///    publication sans raison, alors qu'un blocage vrai est déjà rapporté par les deux sources.
public enum ConsoleOwnership {
    public static let onConsoleKey = "kCGSSessionOnConsoleKey"
    public static let userIDKey = "kCGSSessionUserIDKey"

    /// D'où vient le verdict.
    public enum Source: Equatable {
        case registry, cgSession
        /// Aucune source n'a répondu : le verdict est un laisser-passer.
        case none
    }

    public struct Verdict: Equatable {
        public let onConsole: Bool
        public let source: Source

        public init(onConsole: Bool, source: Source) {
            self.onConsole = onConsole
            self.source = source
        }
    }

    /// - `consoleUsers` : la propriété `IOConsoleUsers` du registre, `nil` si elle est illisible.
    /// - `cgSession` : le dictionnaire de la session graphique courante, `nil` hors session.
    /// - `uid` : l'uid réel du processus (0 pour root, qui n'a pas de session à lui).
    public static func decide(consoleUsers: [[String: Any]]?, cgSession: [String: Any]?, uid: UInt32) -> Verdict {
        if let consoleUsers,
           let console = consoleUsers.first(where: { flag($0[onConsoleKey]) == true }) {
            return Verdict(onConsole: ownerAllows(console, uid: uid), source: .registry)
        }
        if let cgSession, let onConsole = flag(cgSession[onConsoleKey]) {
            let allowed = onConsole ? ownerAllows(cgSession, uid: uid) : uid == 0
            return Verdict(onConsole: allowed, source: .cgSession)
        }
        return Verdict(onConsole: true, source: .none)
    }

    /// Root : toute console compte. Propriétaire illisible : on ne bloque pas par erreur.
    private static func ownerAllows(_ entry: [String: Any], uid: UInt32) -> Bool {
        guard uid != 0 else { return true }
        guard let owner = (entry[userIDKey] as? NSNumber)?.uint32Value else { return true }
        return owner == uid
    }

    private static func flag(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}
