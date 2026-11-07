import Foundation

/// Contrôle des commandes de remplacement `off_command` et `wake_command`.
///
/// `Process` ne consulte pas le `PATH` : une commande dont le premier élément n'est pas un chemin absolu vers un
/// exécutable ne peut pas partir. Elle est écartée au chargement de la config, avec un avertissement, plutôt que
/// d'échouer à chaque OFF ou ON (et de laisser croire que la surcharge agit).
public enum CommandOverride {
    /// Vrai pour un fichier ordinaire exécutable (pas un dossier).
    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    /// - un `argv` vide reste vide, sans avertissement ;
    /// - un `argv[0]` relatif ou non exécutable donne `[]` et l'avertissement
    ///   « <label> ignoré : <chemin échappé> n'est pas un chemin absolu exécutable » ;
    /// - sinon `argv` est gardé tel quel.
    public static func validate(_ argv: [String], label: String,
                                isExecutable: (String) -> Bool) -> (argv: [String], warning: String?) {
        guard let first = argv.first else { return (argv, nil) }
        if first.hasPrefix("/"), isExecutable(first) { return (argv, nil) }
        return ([], "\(label) ignoré : \(escapeForLog(first, limit: 64)) n'est pas un chemin absolu exécutable")
    }
}
