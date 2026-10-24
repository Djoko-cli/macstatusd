import Foundation
import SystemConfiguration

/// Noms sous lesquels le Mac se désigne lui-même, acceptés dans l'en-tête `Host` en plus
/// des adresses littérales et de `localhost`. Lus une fois, au démarrage, sans résolution DNS.
enum LocalNames {
    /// Nom Bonjour (`SCDynamicStoreCopyLocalHostName`, suivi de `.local`) et nom d'hôte
    /// (`gethostname`, tel quel, plus `.local` s'il n'a pas de domaine). Sans doublon, sans casse.
    static func current() -> [String] {
        var names: [String] = []
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty {
            names.append(withLocalSuffix(local))
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let hostname = String(cString: buffer)
            if !hostname.isEmpty {
                names.append(hostname)
                if !hostname.contains(".") { names.append(withLocalSuffix(hostname)) }
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func withLocalSuffix(_ name: String) -> String {
        name.lowercased().hasSuffix(".local") ? name : name + ".local"
    }
}
