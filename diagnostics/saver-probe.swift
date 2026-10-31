// Sonde de l'économiseur d'écran pour le banc du lot 4 (macOS 27, Apple Silicon).
//
// Relève, à intervalle régulier, tous les signaux candidats qui permettraient de
// distinguer « un économiseur dessine devant l'utilisateur » de « un process
// d'économiseur survit derrière l'écran de verrouillage » : process hôtes
// (legacyScreenSaver, Aerial, Wallpaper…), fenêtres, écrans, verrouillage, saisie
// sécurisée, inactivité, notifications. La sonde ne fait qu'observer : aucune
// requête réseau, aucune commande, aucun privilège.
//
//   swiftc -O -o <binaire> diagnostics/saver-probe.swift
//   <binaire> [--duree S] [--sortie DOSSIER] [--intervalle S]
//
//   --duree S         durée totale en secondes, démarrage compris (défaut 3600)
//   --sortie DOSSIER  dossier du journal (défaut $TMPDIR/macstatusd-banc, créé en 700)
//   --intervalle S    pas du relevé en secondes, 0,05 au minimum (défaut 0,25)
//
// Le journal est <sortie>/sonde-AAAAMMJJ-HHMMSS.log (600), recopié sur la sortie standard.
// Chaque ligne : heure locale HH:MM:SS.mmm, temps monotone écoulé en secondes (veille
// comprise), étiquette, texte. Étiquettes : CHANGEMENT (l'empreinte a changé : tout
// l'état sauf l'inactivité et le nombre de fenêtres), BATTEMENT (rappel toutes les 2 s),
// PROCESSUS (apparition et disparition d'un process d'économiseur), NOTIFICATION, MARQUE,
// INFO, ALERTE, DEBUT, FIN.
//
// Pour baliser une étape du banc, ajouter une ligne au fichier <sortie>/marques.txt
// (echo "texte" >> marques.txt) : elle est recopiée dans le journal sous la forme
// « MARQUE texte ». Seules les lignes ajoutées après le démarrage comptent.
//
// Seule émission de la sonde : au démarrage, une notification distribuée à nom privé, pour
// savoir si l'observateur de toutes les notifications distribuées reçoit quelque chose.

import AppKit
import Carbon
import CoreGraphics
import Foundation
import IOKit

// MARK: - Constantes

enum Constantes {
    /// Fragments (en minuscules) qui désignent un process d'économiseur ou de fond
    /// d'écran quand ils figurent dans son chemin complet. « legacyscreensaver »
    /// est déjà couvert par « screensaver » : il reste écrit pour la lisibilité.
    static let motsProcessus = ["screensaver", "legacyscreensaver", "aerial", "wallpaper"]

    /// Notifications distribuées écoutées par leur nom (liste fixe).
    static let notificationsListe = [
        "com.apple.screensaver.didstart", "com.apple.screensaver.didstop",
        "com.apple.screensaver.willstop", "com.apple.screenIsLocked",
        "com.apple.screenIsUnlocked",
    ]

    /// L'observateur sans nom reçoit tout : on n'en garde que les notifications dont
    /// le nom (en minuscules) contient l'un de ces fragments.
    static let motsNotifications = ["screensaver", "screenis", "lock", "display"]

    /// Notifications de NSWorkspace écoutées.
    static let notificationsWorkspace: [Notification.Name] = [
        NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
        NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification,
    ]

    /// Propriétaires de fenêtres retenus (fragments en minuscules).
    static let motsProprietaires = ["screensaver", "login", "securityagent"]

    /// Clés connues de l'entrée à la console de IOConsoleUsers ; toute autre clé
    /// apparue pendant l'économiseur est signalée.
    static let clesConnues: Set<String> = [
        "CGSSessionUniqueSessionUUID", "kCGSSessionAuditIDKey", "kCGSSessionGroupIDKey",
        "kCGSSessionIDKey", "kCGSSessionLoginwindowSafeLogin", "kCGSSessionOnConsoleKey",
        "kCGSSessionSystemSafeBoot", "kCGSSessionUserIDKey", "kCGSSessionUserNameKey",
        "kCGSessionLoginDoneKey", "kCGSessionLongUserNameKey", "kSCSecuritySessionID",
        "CGSSessionScreenIsLocked", "kCGSSessionSecureInputPID",
    ]

    static let battement = 2.0
    static let tailleMaxChemin = 4 * Int(MAXPATHLEN)

    static let architecture: String = {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "inconnue"
        #endif
    }()
}

// MARK: - Arguments

struct Configuration {
    var duree = 3600.0
    var dossier = (NSTemporaryDirectory() as NSString).appendingPathComponent("macstatusd-banc")
    var intervalle = 0.25
}

let texteUsage = """
Usage : saver-probe [--duree S] [--sortie DOSSIER] [--intervalle S]
  --duree S         durée totale en secondes, démarrage compris (défaut 3600)
  --sortie DOSSIER  dossier du journal (défaut $TMPDIR/macstatusd-banc, créé en 700)
  --intervalle S    pas du relevé en secondes, 0,05 au minimum (défaut 0,25)
La sonde ne fait qu'observer. Pour poser une marque dans le journal :
  echo "texte" >> DOSSIER/marques.txt
"""

/// Chemin absolu et normalisé (le « ~ » d'un chemin entre guillemets est développé).
func cheminAbsolu(_ chemin: String) -> String {
    URL(fileURLWithPath: (chemin as NSString).expandingTildeInPath).standardizedFileURL.path
}

func quitter(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func lireArguments(_ arguments: [String]) -> Configuration {
    var configuration = Configuration()
    var index = 1

    func nombre(_ texte: String, _ option: String) -> Double {
        // La virgule décimale française est acceptée.
        guard let valeur = Double(texte.replacingOccurrences(of: ",", with: ".")),
              valeur.isFinite, valeur > 0
        else { quitter("\(option) attend un nombre de secondes strictement positif, reçu « \(texte) »\n\(texteUsage)", code: 2) }
        return valeur
    }

    while index < arguments.count {
        // Les deux formes --option valeur et --option=valeur sont acceptées.
        let brut = arguments[index]
        let morceaux = brut.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let option = String(morceaux[0])
        func valeur() -> String {
            if morceaux.count == 2 { return String(morceaux[1]) }
            index += 1
            guard index < arguments.count else { quitter("\(option) attend une valeur\n\(texteUsage)", code: 2) }
            return arguments[index]
        }
        switch option {
        case "--duree": configuration.duree = nombre(valeur(), option)
        case "--intervalle":
            configuration.intervalle = nombre(valeur(), option)
            guard configuration.intervalle >= 0.05 else { quitter("--intervalle vaut 0,05 s au minimum\n\(texteUsage)", code: 2) }
        case "--sortie":
            let dossier = valeur()
            guard !dossier.isEmpty else { quitter("--sortie attend un dossier non vide", code: 2) }
            configuration.dossier = cheminAbsolu(dossier)
        case "-h", "--aide", "--help":
            print(texteUsage)
            exit(0)
        default:
            quitter("option inconnue : \(brut)\n\(texteUsage)", code: 2)
        }
        index += 1
    }
    return configuration
}

// MARK: - Horloges et texte

func horlogeMonotone() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

func maintenant() -> timeval {
    var instant = timeval()
    gettimeofday(&instant, nil)
    return instant
}

/// Heure locale `HH:MM:SS.mmm`, précédée de `AAAA-MM-JJ ` si `avecDate`.
func heureLocale(_ instant: timeval, avecDate: Bool = false) -> String {
    var secondes = instant.tv_sec
    var local = tm()
    localtime_r(&secondes, &local)
    var texte = String(format: "%02d:%02d:%02d.%03d", local.tm_hour, local.tm_min, local.tm_sec,
                       Int32(instant.tv_usec / 1000))
    if avecDate {
        texte = String(format: "%04d-%02d-%02d ", local.tm_year + 1900, local.tm_mon + 1, local.tm_mday) + texte
    }
    return texte
}

/// `AAAAMMJJ-HHMMSS` en heure locale, pour le nom du journal.
func horodatageFichier() -> String {
    var secondes = maintenant().tv_sec
    var local = tm()
    localtime_r(&secondes, &local)
    return String(format: "%04d%02d%02d-%02d%02d%02d", local.tm_year + 1900, local.tm_mon + 1, local.tm_mday,
                  local.tm_hour, local.tm_min, local.tm_sec)
}

/// Durée en unités lisibles : « 12.3 s », « 5 min 12 s », « 3 h 05 min », « 17 j 20 h ».
func dureeLisible(_ secondes: Double) -> String {
    let total = max(0, secondes)
    if total < 60 { return String(format: "%.1f s", total) }
    let entier = Int(total)
    if entier < 3600 { return "\(entier / 60) min \(entier % 60) s" }
    if entier < 86400 { return String(format: "%d h %02d min", entier / 3600, entier % 3600 / 60) }
    return "\(entier / 86400) j \(entier % 86400 / 3600) h"
}

/// Remplace les caractères de contrôle (séquences d'échappement du terminal comprises)
/// par « ? » : une ligne du journal reste une ligne.
func assainir(_ texte: String) -> String {
    var resultat = ""
    for scalaire in texte.unicodeScalars {
        resultat.unicodeScalars.append(scalaire.value < 0x20 || scalaire.value == 0x7F ? "?" : scalaire)
    }
    return resultat
}

/// Écrit tous les octets, sans lever d'erreur : un descripteur fermé (tube cassé)
/// ne doit pas arrêter la sonde.
func ecrireTout(_ descripteur: Int32, _ octets: [UInt8]) {
    var debut = 0
    while debut < octets.count {
        let ecrits = octets.withUnsafeBytes { write(descripteur, $0.baseAddress! + debut, $0.count - debut) }
        if ecrits < 0 {
            if errno == EINTR { continue }
            return
        }
        debut += ecrits
    }
}

/// Chaîne C stockée dans un tuple de `CChar` (comme `p_comm`).
func chaineDepuisTuple<T>(_ valeur: T) -> String {
    var copie = valeur
    return withUnsafeBytes(of: &copie) { brut -> String in
        String(cString: brut.bindMemory(to: CChar.self).baseAddress!)
    }
}

/// Booléen à trois états : 1, 0, ou « - » quand la clé est absente.
func tricoche(_ valeur: Any?) -> String {
    guard let nombre = valeur as? NSNumber else { return "-" }
    return nombre.boolValue ? "1" : "0"
}

func texteRect(_ rect: CGRect) -> String {
    "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.size.width))x\(Int(rect.size.height))"
}

// MARK: - Journal

final class Journal {
    let chemin: String
    private let descripteur: Int32
    private let origine = horlogeMonotone()

    init(chemin: String, descripteur: Int32) {
        self.chemin = chemin
        self.descripteur = descripteur
    }

    /// Secondes écoulées depuis le démarrage (horloge monotone : la veille compte).
    var ecoule: Double { Double(horlogeMonotone() &- origine) / 1e9 }

    func ligne(_ etiquette: String, _ texte: String = "") {
        var complet = heureLocale(maintenant()) + String(format: " +%09.3f ", ecoule) + etiquette
        if !texte.isEmpty { complet += " " + texte }
        let octets = Array((complet + "\n").utf8)
        ecrireTout(descripteur, octets)
        ecrireTout(STDOUT_FILENO, octets)
    }
}

/// Crée le dossier de sortie (700) s'il manque ; rend les droits du dossier, ou nil s'il
/// est inutilisable.
func preparerDossier(_ chemin: String) -> mode_t? {
    var info = stat()
    if stat(chemin, &info) != 0 {
        do {
            try FileManager.default.createDirectory(atPath: chemin, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        // Les attributs ne s'appliquent pas forcément au dernier niveau : on l'impose.
        chmod(chemin, 0o700)
        guard stat(chemin, &info) == 0 else { return nil }
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
    return info.st_mode & 0o777
}

/// Ouvre `sonde-AAAAMMJJ-HHMMSS.log` (600), sans jamais écraser un journal existant.
func ouvrirJournal(dans dossier: String) -> Journal? {
    let base = "sonde-" + horodatageFichier()
    for essai in 1...50 {
        let chemin = dossier + "/" + base + (essai == 1 ? "" : "-\(essai)") + ".log"
        let descripteur = open(chemin, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o600)
        if descripteur >= 0 { return Journal(chemin: chemin, descripteur: descripteur) }
        if errno != EEXIST { return nil }
    }
    return nil
}

// MARK: - Marques

/// Surveille `marques.txt` : chaque ligne ajoutée après le démarrage est rendue une fois.
final class SurveillanceMarques {
    let chemin: String
    private var decalage: Int64 = 0
    private var inode: UInt64 = 0
    private var residu: [UInt8] = []
    private var dernierAjout = 0.0
    let tailleInitiale: Int64

    init(chemin: String) {
        self.chemin = chemin
        var info = stat()
        if stat(chemin, &info) == 0 {
            // Les lignes déjà présentes (d'une session précédente) ne sont pas des marques.
            decalage = Int64(info.st_size)
            inode = UInt64(info.st_ino)
        }
        tailleInitiale = decalage
    }

    /// Les lignes complètes apparues depuis le dernier appel, et un message d'information
    /// éventuel (fichier remplacé ou tronqué).
    func nouvellesLignes(ecoule: Double) -> (lignes: [String], information: String?) {
        var info = stat()
        guard stat(chemin, &info) == 0 else { return ([], nil) }
        var message: String?
        if UInt64(info.st_ino) != inode {
            if inode != 0 { message = "marques.txt remplacé : relu depuis le début" }
            inode = UInt64(info.st_ino)
            decalage = 0
            residu = []
        } else if Int64(info.st_size) < decalage {
            message = "marques.txt tronqué : relu depuis le début"
            decalage = 0
            residu = []
        }
        let taille = Int64(info.st_size)
        if taille > decalage {
            let descripteur = open(chemin, O_RDONLY)
            if descripteur >= 0 {
                var tampon = [UInt8](repeating: 0, count: Int(min(taille - decalage, 1 << 20)))
                let lus = pread(descripteur, &tampon, tampon.count, off_t(decalage))
                close(descripteur)
                if lus > 0 {
                    residu += tampon[..<lus]
                    decalage += Int64(lus)
                    dernierAjout = ecoule
                }
            }
        }
        var lignes: [String] = []
        while let fin = residu.firstIndex(of: 10) {
            var brute = Array(residu[..<fin])
            residu.removeSubrange(...fin)
            if brute.last == 13 { brute.removeLast() }
            lignes.append(String(decoding: brute, as: UTF8.self))
        }
        // Une dernière ligne sans retour à la ligne est rendue après une seconde de calme.
        if !residu.isEmpty, ecoule - dernierAjout > 1.0 {
            lignes.append(String(decoding: residu, as: UTF8.self))
            residu = []
        }
        let propres = lignes
            .map { String(assainir($0).trimmingCharacters(in: .whitespaces).prefix(1000)) }
            .filter { !$0.isEmpty }
        return (propres, message)
    }
}

// MARK: - Process

struct CleProcessus: Hashable {
    let pid: Int32
    let debutSecondes: Int
    let debutMicro: Int32
    /// Empreinte de `p_comm` : elle change à un exec, ce qui invalide le chemin en cache.
    let empreinteNom: UInt64
}

struct ProcessusSurveille {
    let cle: CleProcessus
    let chemin: String
    let traduit: Bool
    let debut: timeval

    var pid: Int32 { cle.pid }
    var nom: String { chemin.split(separator: "/").last.map(String.init) ?? chemin }
    /// Forme courte pour les lignes d'état : `pid:nom`, suivi de `(R)` sous Rosetta.
    var court: String { "\(pid):\(nom)" + (traduit ? "(R)" : "") }
}

/// Chemin complet d'un process (`proc_pidpath`), ou nil s'il a disparu.
func cheminDuProcessus(_ pid: Int32) -> String? {
    var tampon = [CChar](repeating: 0, count: Constantes.tailleMaxChemin)
    let longueur = proc_pidpath(pid, &tampon, UInt32(tampon.count))
    guard longueur > 0 else { return nil }
    return tampon.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// Empreinte FNV-1a d'une chaîne C stockée dans un tuple (jusqu'à l'octet nul), sans créer de `String`.
func empreinteChaineC<T>(_ valeur: T) -> UInt64 {
    withUnsafeBytes(of: valeur) { brut in
        var empreinte: UInt64 = 0xcbf2_9ce4_8422_2325
        for octet in brut {
            if octet == 0 { break }
            empreinte = (empreinte ^ UInt64(octet)) &* 0x100_0000_01b3
        }
        return empreinte
    }
}

/// Relève les process de l'utilisateur dont le chemin complet contient l'un des
/// fragments de `Constantes.motsProcessus`. Un relevé voit un millier de process
/// quatre fois par seconde : le tampon du noyau est réutilisé, et le chemin de chaque
/// process (avec sa correspondance au filtre) n'est lu qu'une fois, puis gardé.
final class ScruteurProcessus {
    private struct EntreeChemin {
        let chemin: String
        let correspond: Bool
    }

    private static let empreinteLoginwindow = empreinteChaineC(Array("loginwindow".utf8))

    private var entrees: [CleProcessus: EntreeChemin] = [:]
    private var dernierReleve: (surveilles: [ProcessusSurveille], loginwindow: Int32) = ([], 0)
    private var tampon = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: 1)
    private var capacite = 1
    private var dernierNettoyage = 0.0

    deinit { tampon.deallocate() }

    /// Remplit le tampon avec les process de l'utilisateur courant et rend leur nombre.
    private func lireProcessus() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        for _ in 0..<5 {
            var octets = capacite * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, UInt32(mib.count), tampon, &octets, nil, 0) == 0 {
                return octets / MemoryLayout<kinfo_proc>.stride
            }
            guard errno == ENOMEM else { return 0 }
            // Tampon trop petit : on demande la taille, avec une marge (des process naissent
            // entre les deux appels), et on recommence.
            var taille = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &taille, nil, 0) == 0, taille > 0 else { return 0 }
            tampon.deallocate()
            capacite = taille / MemoryLayout<kinfo_proc>.stride + 64
            tampon = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacite)
        }
        return 0
    }

    func relever(ecoule: Double) -> (surveilles: [ProcessusSurveille], loginwindow: Int32) {
        var surveilles: [ProcessusSurveille] = []
        var loginwindow: Int32 = 0
        let nettoyer = ecoule - dernierNettoyage > 300
        var vus: [CleProcessus] = []
        let nombre = lireProcessus()
        // Un utilisateur a toujours des process : zéro veut dire que la lecture a échoué. On
        // garde alors le relevé précédent, pour ne pas journaliser de fausses disparitions.
        guard nombre > 0 else { return dernierReleve }
        for indice in 0..<nombre {
            let proc = tampon[indice].kp_proc
            if Int32(proc.p_stat) == SZOMB { continue }
            let empreinteNom = empreinteChaineC(proc.p_comm)
            if empreinteNom == Self.empreinteLoginwindow, chaineDepuisTuple(proc.p_comm) == "loginwindow" {
                loginwindow = proc.p_pid
            }
            let cle = CleProcessus(pid: proc.p_pid, debutSecondes: proc.p_starttime.tv_sec,
                                   debutMicro: proc.p_starttime.tv_usec, empreinteNom: empreinteNom)
            if nettoyer { vus.append(cle) }
            let entree: EntreeChemin
            if let connue = entrees[cle] {
                entree = connue
            } else if let chemin = cheminDuProcessus(proc.p_pid) {
                let minuscules = chemin.lowercased()
                entree = EntreeChemin(chemin: chemin,
                                      correspond: Constantes.motsProcessus.contains { minuscules.contains($0) })
                entrees[cle] = entree
            } else {
                continue
            }
            guard entree.correspond else { continue }
            surveilles.append(ProcessusSurveille(cle: cle, chemin: entree.chemin,
                                                 traduit: (proc.p_flag & P_TRANSLATED) != 0, debut: proc.p_starttime))
        }
        if nettoyer {
            // Les process disparus quittent la mémoire tampon des chemins, de temps en temps.
            dernierNettoyage = ecoule
            let presents = Set(vus)
            entrees = entrees.filter { presents.contains($0.key) }
        }
        surveilles.sort { $0.pid < $1.pid }
        dernierReleve = (surveilles, loginwindow)
        return dernierReleve
    }
}

// MARK: - Écrans

struct Ecran {
    let id: CGDirectDisplayID
    let bornes: CGRect
    let integre: Bool
    let principal: Bool
    let endormi: Bool
    let miroir: String

    var texte: String {
        "[id=\(id) integre=\(integre ? 1 : 0) principal=\(principal ? 1 : 0) endormi=\(endormi ? 1 : 0) "
            + "\(texteRect(bornes)) miroir=\(miroir)]"
    }
}

func listerEcrans() -> [Ecran] {
    var identifiants = [CGDirectDisplayID](repeating: 0, count: 16)
    var nombre: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(identifiants.count), &identifiants, &nombre) == .success else { return [] }
    return identifiants.prefix(Int(nombre)).map { id in
        let enMiroir = CGDisplayIsInMirrorSet(id) != 0
        let miroirDe = CGDisplayMirrorsDisplay(id)
        let miroir = !enMiroir ? "non" : (miroirDe == kCGNullDirectDisplay ? "primaire" : "de:\(miroirDe)")
        return Ecran(id: id, bornes: CGDisplayBounds(id), integre: CGDisplayIsBuiltin(id) != 0,
                     principal: CGDisplayIsMain(id) != 0, endormi: CGDisplayIsAsleep(id) != 0, miroir: miroir)
    }
}

// MARK: - Fenêtres

struct EtatFenetres {
    /// Fenêtres retenues, entrées dans l'empreinte.
    var retenues: String
    /// Nombres de fenêtres (visibles, au total), hors de l'empreinte : ils bougent
    /// à chaque fenêtre ouverte par n'importe quelle application.
    var compteurs: String
}

/// Fenêtres des acteurs du verrouillage et de l'économiseur : propriétaires dont le
/// nom contient « screensaver », « login » ou « securityagent », et, parmi les
/// fenêtres visibles, tout ce qui flotte au niveau de l'économiseur ou au-dessus.
/// `retenues` : les visibles, dans l'ordre d'empilement (devant d'abord) ; `cachees` :
/// les fenêtres de ces propriétaires qui ne sont pas à l'écran. Pour chacune :
/// propriétaire, numéro, niveau, origine et taille, alpha, visible, et l'identifiant de
/// l'écran qu'elle couvre entièrement (« - » s'il n'y en a pas).
///
/// Le système rend plus de deux mille fenêtres : on les lit sans les convertir toutes en
/// types Swift (seul le propriétaire est lu pour chacune), et le jugement sur un
/// propriétaire n'est fait qu'une fois.
final class ReleveFenetres {
    private let niveauEconomiseur = Int(CGWindowLevelForKey(.screenSaverWindow))
    private var proprietairesJuges: [String: Bool] = [:]

    private func acteurDuVerrouillage(_ proprietaire: String) -> Bool {
        if let jugement = proprietairesJuges[proprietaire] { return jugement }
        let minuscules = proprietaire.lowercased()
        let jugement = Constantes.motsProprietaires.contains { minuscules.contains($0) }
        if proprietairesJuges.count < 5000 { proprietairesJuges[proprietaire] = jugement }
        return jugement
    }

    private func lister(_ option: CGWindowListOption) -> NSArray? {
        guard let liste = CGWindowListCopyWindowInfo(option, kCGNullWindowID) else { return nil }
        return liste as NSArray
    }

    private func proprietaire(_ fenetre: NSDictionary) -> String {
        fenetre[kCGWindowOwnerName as String] as? String ?? "?"
    }

    private func visible(_ fenetre: NSDictionary) -> Bool {
        (fenetre[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    }

    private func detail(_ fenetre: NSDictionary, ecrans: [Ecran]) -> String {
        let bornes = (fenetre[kCGWindowBounds as String] as? [String: Any])
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        let couvre = bornes.isEmpty ? [] : ecrans.filter { !$0.bornes.isEmpty && bornes.contains($0.bornes) }
        let alpha = (fenetre[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
        let numero = (fenetre[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
        let pid = (fenetre[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
        let niveau = (fenetre[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return "[\(proprietaire(fenetre)) pid=\(pid) n=\(numero) l=\(niveau) \(texteRect(bornes)) "
            + "a=\(String(format: "%.2f", alpha)) vis=\(visible(fenetre) ? 1 : 0) "
            + "ecran=\(couvre.isEmpty ? "-" : couvre.map { String($0.id) }.joined(separator: "+"))]"
    }

    func etudier(ecrans: [Ecran]) -> EtatFenetres {
        let visibles = lister(.optionOnScreenOnly)
        let toutes = lister(.optionAll)

        var retenues = "nil"
        if let visibles {
            var details: [String] = []
            for indice in 0..<visibles.count {
                guard let fenetre = visibles[indice] as? NSDictionary else { continue }
                let nom = proprietaire(fenetre)
                guard nom != "Window Server" else { continue }
                let niveau = (fenetre[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                if acteurDuVerrouillage(nom) || niveau >= niveauEconomiseur {
                    details.append(detail(fenetre, ecrans: ecrans))
                }
            }
            retenues = details.isEmpty ? "-" : details.joined(separator: " ")
        }
        var cachees = "nil"
        if let toutes {
            var details: [String] = []
            for indice in 0..<toutes.count {
                guard let fenetre = toutes[indice] as? NSDictionary, !visible(fenetre) else { continue }
                let nom = proprietaire(fenetre)
                if nom != "Window Server", acteurDuVerrouillage(nom) { details.append(detail(fenetre, ecrans: ecrans)) }
            }
            cachees = details.isEmpty ? "-" : details.joined(separator: " ")
        }
        return EtatFenetres(
            retenues: "retenues=[\(retenues)] cachees=[\(cachees)]",
            compteurs: "fenetresVisibles=\(visibles.map { String($0.count) } ?? "nil") "
                + "fenetresTotal=\(toutes.map { String($0.count) } ?? "nil")")
    }
}

// MARK: - Observateurs de notifications

/// Reçoit les notifications (méthodes Objective-C) et les passe à la sonde.
final class Observateur: NSObject {
    var surListe: (Notification) -> Void = { _ in }
    var surToutes: (Notification) -> Void = { _ in }
    var surWorkspace: (Notification) -> Void = { _ in }
    var surTemoin: (Notification) -> Void = { _ in }
    var surTemoinWorkspace: (Notification) -> Void = { _ in }

    @objc func recuListe(_ notification: Notification) { surListe(notification) }
    @objc func recuToutes(_ notification: Notification) { surToutes(notification) }
    @objc func recuWorkspace(_ notification: Notification) { surWorkspace(notification) }
    @objc func recuTemoin(_ notification: Notification) { surTemoin(notification) }
    @objc func recuTemoinWorkspace(_ notification: Notification) { surTemoinWorkspace(notification) }
}

/// Objet (texte court) et clés du dictionnaire d'une notification : jamais les valeurs.
func decrire(_ notification: Notification) -> String {
    var morceaux: [String] = []
    if let objet = notification.object as? String, !objet.isEmpty {
        morceaux.append("objet=" + assainir(String(objet.prefix(80))))
    }
    if let infos = notification.userInfo, !infos.isEmpty {
        morceaux.append("cles=[" + infos.keys.map { assainir("\($0)") }.sorted().joined(separator: ",") + "]")
    }
    return morceaux.joined(separator: " ")
}

// MARK: - La sonde

final class Sonde {
    let configuration: Configuration
    let journal: Journal
    private let avertissementDossier: String?

    private let observateur = Observateur()
    private let scruteur = ScruteurProcessus()
    private let releveFenetres = ReleveFenetres()
    private let surveillanceMarques: SurveillanceMarques
    private let racineRegistre = IORegistryGetRootEntry(kIOMainPortDefault)
    private var sourcesSignaux: [DispatchSourceSignal] = []
    private var activite: NSObjectProtocol?

    // login.framework (API privée, chargée dynamiquement)
    private typealias SACIsRunning = @convention(c) (UnsafeMutablePointer<UInt8>) -> Int32
    private var sacIsRunning: SACIsRunning?

    // État du relevé
    private var processusConnus: [CleProcessus: ProcessusSurveille] = [:]
    private var premierReleve = true
    private var empreintePrecedente: String?
    private var prochainBattement = 0.0
    private var dernierPassage = 0.0
    private var releves = 0
    private var changements = 0
    private var battements = 0
    private var marquesVues = 0

    // Compteurs des notifications
    private var recuesListe = 0
    private var recuesToutes = 0
    private var recuesToutesDeLaListe = 0
    private var recuesWorkspace = 0
    private var nomsDistincts = Set<String>()
    private let nomAutotest = "fr.macstatusd.sonde.autotest.\(getpid())"
    /// Instants (secondes depuis le démarrage) où l'autotest est arrivé par chaque canal.
    private var autotestSansNom: Double?
    private var autotestParNom: Double?
    private var activationsWorkspace = 0

    init(configuration: Configuration, journal: Journal, avertissementDossier: String?) {
        self.configuration = configuration
        self.journal = journal
        self.avertissementDossier = avertissementDossier
        surveillanceMarques = SurveillanceMarques(chemin: configuration.dossier + "/marques.txt")
    }

    // MARK: Démarrage

    func demarrer() {
        journal.ligne("DEBUT", "sonde de l'économiseur d'écran, banc du lot 4")
        journal.ligne("INFO", "durée=\(String(format: "%g", configuration.duree)) s "
                      + "intervalle=\(String(format: "%g", configuration.intervalle)) s "
                      + "pid=\(getpid()) uid=\(getuid()) architecture=\(Constantes.architecture)")
        journal.ligne("INFO", "macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        journal.ligne("INFO", "journal=\(journal.chemin)")
        if let avertissementDossier { journal.ligne("ALERTE", avertissementDossier) }
        journal.ligne("INFO", "légende : CHANGEMENT = l'empreinte a changé ; BATTEMENT = rappel toutes les "
                      + "\(Int(Constantes.battement)) s ; 1/0/- = vrai/faux/absent ; (R) = process traduit par Rosetta ; "
                      + "hidIdle en secondes")
        journal.ligne("INFO", "marques : echo \"texte\" >> \"\(surveillanceMarques.chemin)\" "
                      + "(\(surveillanceMarques.tailleInitiale) octets déjà présents, ignorés)")

        installerSignaux()
        // Sans cette activité, macOS peut ralentir les minuteries d'un outil lancé depuis un
        // Terminal masqué (App Nap), justement quand l'économiseur recouvre l'écran. Elle
        // n'empêche ni la veille du système ni celle de l'écran : rien ne change pour le banc.
        activite = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "relevés réguliers de la sonde")
        chargerLoginFramework()
        installerObservateurs()
        verifierCanalDistribue()
        if let toutes = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]], !toutes.isEmpty {
            journal.ligne("INFO", "fenêtres : \(toutes.count) relevées au démarrage")
        } else {
            journal.ligne("ALERTE", "fenêtres : CGWindowListCopyWindowInfo ne rend rien (autorisation manquante ?)")
        }

        passer()
        let minuterie = Timer(timeInterval: configuration.intervalle, repeats: true) { [weak self] _ in self?.passer() }
        RunLoop.main.add(minuterie, forMode: .common)
    }

    private func chargerLoginFramework() {
        if let cadre = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
           let symbole = dlsym(cadre, "SACScreenSaverIsRunning") {
            sacIsRunning = unsafeBitCast(symbole, to: SACIsRunning.self)
            journal.ligne("INFO", "SACScreenSaverIsRunning : chargée")
        } else {
            journal.ligne("ALERTE", "SACScreenSaverIsRunning : INDISPONIBLE (login.framework ou symbole absent)")
        }
    }

    private func installerObservateurs() {
        observateur.surListe = { [weak self] notification in self?.notificationDeLaListe(notification) }
        observateur.surToutes = { [weak self] notification in self?.notificationSansNom(notification) }
        observateur.surWorkspace = { [weak self] notification in self?.notificationWorkspace(notification) }
        observateur.surTemoin = { [weak self] _ in
            if let self, self.autotestParNom == nil { self.autotestParNom = self.journal.ecoule }
        }
        observateur.surTemoinWorkspace = { [weak self] _ in self?.temoinWorkspace() }

        let centre = DistributedNotificationCenter.default()
        for nom in Constantes.notificationsListe {
            centre.addObserver(observateur, selector: #selector(Observateur.recuListe(_:)),
                               name: Notification.Name(nom), object: nil, suspensionBehavior: .deliverImmediately)
        }
        // Observateur sans nom : toutes les notifications distribuées.
        centre.addObserver(observateur, selector: #selector(Observateur.recuToutes(_:)),
                           name: nil, object: nil, suspensionBehavior: .deliverImmediately)
        // Témoin du canal nommé : l'autotest, écouté par son nom.
        centre.addObserver(observateur, selector: #selector(Observateur.recuTemoin(_:)),
                           name: Notification.Name(nomAutotest), object: nil, suspensionBehavior: .deliverImmediately)
        let centreWorkspace = NSWorkspace.shared.notificationCenter
        for nom in Constantes.notificationsWorkspace {
            centreWorkspace.addObserver(observateur, selector: #selector(Observateur.recuWorkspace(_:)),
                                        name: nom, object: nil)
        }
        // Témoin de NSWorkspace : une activation d'application (la plus fréquente) prouve que
        // ce canal livre bien ses notifications à un outil sans interface ; on la compte seulement.
        centreWorkspace.addObserver(observateur, selector: #selector(Observateur.recuTemoinWorkspace(_:)),
                                    name: NSWorkspace.didActivateApplicationNotification, object: nil)
        journal.ligne("INFO", "notifications : \(Constantes.notificationsListe.count) distribuées par leur nom, "
                      + "\(Constantes.notificationsWorkspace.count) de NSWorkspace, plus un observateur sans nom")
    }

    private func temoinWorkspace() {
        activationsWorkspace += 1
        if activationsWorkspace == 1 {
            journal.ligne("INFO", "NSWorkspace : témoin reçu (activation d'une application), ce canal livre ses notifications")
        }
    }

    /// Les observateurs de notifications distribuées reçoivent-ils quelque chose ? On le sait
    /// tout de suite : la sonde poste une fois une notification distribuée à nom privé (que
    /// personne d'autre n'écoute, c'est sa seule émission) et attend, au plus 1,5 s, de la voir
    /// arriver par l'observateur sans nom et par un observateur nommé, qui sert de témoin.
    /// Si le nommé reçoit et que le sans nom reste muet, le canal sans nom est refusé ou sourd :
    /// la liste fixe reste la seule source (l'observateur sans nom reste en place et on compte
    /// ce qu'il reçoit).
    private func verifierCanalDistribue() {
        let depart = journal.ecoule
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(nomAutotest), object: nil, userInfo: nil, deliverImmediately: true)
        while autotestSansNom == nil || autotestParNom == nil, journal.ecoule - depart < 1.5 {
            if !RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) { usleep(10_000) }
        }
        func delai(_ instant: Double?) -> String { instant.map { "\(Int(($0 - depart) * 1000)) ms" } ?? "jamais" }
        let bilan = "nommé : \(delai(autotestParNom)), sans nom : \(delai(autotestSansNom))"
        switch (autotestSansNom, autotestParNom) {
        case (.some, _):
            journal.ligne("INFO", "observateur sans nom : FONCTIONNE (autotest reçu ; \(bilan)) ; il journalise les "
                          + "notifications dont le nom contient \(Constantes.motsNotifications.joined(separator: ", "))")
        case (nil, .some):
            journal.ligne("ALERTE", "observateur sans nom : RIEN reçu en 1,5 s, pas même l'autotest que l'observateur nommé "
                          + "a reçu (\(bilan)) : canal sans nom refusé ou sourd ; la liste fixe reste la seule source "
                          + "de notifications distribuées")
        case (nil, nil):
            journal.ligne("ALERTE", "notifications distribuées : l'autotest n'est reçu par aucun observateur en 1,5 s, "
                          + "nommé compris : canal indisponible dans ce contexte, la liste fixe ne reçoit sans doute rien non plus")
        }
    }

    private func installerSignaux() {
        for numero in [SIGINT, SIGTERM] {
            signal(numero, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: numero, queue: .main)
            source.setEventHandler { [weak self] in self?.terminer(numero == SIGINT ? "SIGINT" : "SIGTERM") }
            source.resume()
            sourcesSignaux.append(source)
        }
    }

    // MARK: Notifications

    private func notificationDeLaListe(_ notification: Notification) {
        recuesListe += 1
        journalNotification(notification, via: "liste")
    }

    private func notificationWorkspace(_ notification: Notification) {
        recuesWorkspace += 1
        journalNotification(notification, via: "workspace")
    }

    private func notificationSansNom(_ notification: Notification) {
        let nom = notification.name.rawValue
        if nom == nomAutotest {
            if autotestSansNom == nil { autotestSansNom = journal.ecoule }
            return
        }
        recuesToutes += 1
        if nomsDistincts.count < 5000 { nomsDistincts.insert(nom) }
        // Celles de la liste fixe sont déjà journalisées par leur propre observateur.
        if Constantes.notificationsListe.contains(nom) {
            recuesToutesDeLaListe += 1
            return
        }
        let minuscules = nom.lowercased()
        guard Constantes.motsNotifications.contains(where: { minuscules.contains($0) }) else { return }
        journalNotification(notification, via: "toutes")
    }

    private func journalNotification(_ notification: Notification, via: String) {
        let detail = decrire(notification)
        journal.ligne("NOTIFICATION", "\(notification.name.rawValue) via=\(via)" + (detail.isEmpty ? "" : " " + detail))
    }

    // MARK: Relevé

    private func proprieteRegistre(_ cle: String) -> Any? {
        IORegistryEntryCreateCFProperty(racineRegistre, cle as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// `SACScreenSaverIsRunning` appelée avec un pointeur valide : couvre les deux
    /// signatures plausibles (`OSStatus f(Boolean*)`, ou `Boolean f(void)` qui
    /// ignorerait l'argument). `0xAA` = octet non écrit.
    private func appelSAC() -> String {
        guard let sacIsRunning else { return "SAC(indisponible)" }
        var sortie: UInt8 = 0xAA
        let retour = withUnsafeMutablePointer(to: &sortie) { sacIsRunning($0) }
        return "SAC(ret=\(retour) out=\(sortie == 0xAA ? "nonÉcrit" : String(sortie)))"
    }

    private func nomDuProcessus(_ pid: Int32) -> String {
        cheminDuProcessus(pid).flatMap { $0.split(separator: "/").last.map(String.init) } ?? "?"
    }

    private func verrous() -> String {
        var parties = ["ioLocked=" + tricoche(proprieteRegistre("IOConsoleLocked"))]
        if let sessions = proprieteRegistre("IOConsoleUsers") as? [[String: Any]] {
            let resume = sessions.map { session -> String in
                let uid = (session["kCGSSessionUserIDKey"] as? NSNumber)?.stringValue ?? "?"
                return "\(uid)/\(tricoche(session["kCGSSessionOnConsoleKey"]))"
            }
            parties.append("sessions[uid/onConsole]=[" + resume.joined(separator: ",") + "]")
            if let console = sessions.first(where: { ($0["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true }) {
                var details = ["uid=" + ((console["kCGSSessionUserIDKey"] as? NSNumber)?.stringValue ?? "?"),
                               "usersLocked=" + tricoche(console["CGSSessionScreenIsLocked"])]
                if let pid = (console["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value {
                    details.append("secureInputPid=\(pid)(\(nomDuProcessus(pid)))")
                } else {
                    details.append("secureInputPid=-")
                }
                let inattendues = console.keys.filter { !Constantes.clesConnues.contains($0) }.sorted()
                if !inattendues.isEmpty { details.append("clésInattendues=[" + inattendues.joined(separator: ",") + "]") }
                parties.append("console{" + details.joined(separator: " ") + "}")
            } else {
                parties.append("console{aucune}")
            }
        } else {
            parties.append("IOConsoleUsers=absent")
        }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            parties.append("cgLocked=" + tricoche(session["CGSSessionScreenIsLocked"]))
            parties.append("cgOnConsole=" + tricoche(session["kCGSSessionOnConsoleKey"]))
        } else {
            parties.append("cgLocked=nil")
        }
        return parties.joined(separator: " ")
    }

    private func inactivite() -> Double {
        var iterateur: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterateur) == KERN_SUCCESS
        else { return -1 }
        defer { IOObjectRelease(iterateur) }
        let entree = IOIteratorNext(iterateur)
        guard entree != 0 else { return -1 }
        defer { IOObjectRelease(entree) }
        guard let valeur = IORegistryEntryCreateCFProperty(entree, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return -1 }
        return Double(valeur.uint64Value) / 1_000_000_000
    }

    /// Apparition et disparition de chaque process surveillé, comme événements.
    private func suivreProcessus(_ surveilles: [ProcessusSurveille]) {
        var actuels: [CleProcessus: ProcessusSurveille] = [:]
        for processus in surveilles { actuels[processus.cle] = processus }
        let maintenantDate = maintenant()
        func age(_ debut: timeval) -> String {
            dureeLisible(Double(maintenantDate.tv_sec - debut.tv_sec) + Double(maintenantDate.tv_usec - debut.tv_usec) / 1e6)
        }
        func detail(_ p: ProcessusSurveille) -> String {
            "pid=\(p.pid) rosetta=\(p.traduit ? "oui" : "non") lancé=\(heureLocale(p.debut, avecDate: true)) chemin=\(p.chemin)"
        }
        for processus in surveilles where processusConnus[processus.cle] == nil {
            journal.ligne("PROCESSUS", (premierReleve ? "PRESENT " : "APPARITION ") + detail(processus)
                          + (premierReleve ? " âge=\(age(processus.debut))" : ""))
        }
        for processus in processusConnus.values.sorted(by: { $0.pid < $1.pid }) where actuels[processus.cle] == nil {
            journal.ligne("PROCESSUS", "DISPARITION " + detail(processus) + " vécu=\(age(processus.debut))")
        }
        processusConnus = actuels
    }

    /// Un passage : marques, relevé de tous les signaux, ligne si l'empreinte change
    /// ou si le battement est dû.
    private func passer() {
        let ecoule = journal.ecoule
        if ecoule >= configuration.duree {
            terminer("échéance")
            return
        }
        if !premierReleve, ecoule - dernierPassage > max(1.0, 4 * configuration.intervalle) {
            journal.ligne("INFO", String(format: "retard de %.1f s entre deux relevés (veille du Mac ou sonde ralentie)",
                                         ecoule - dernierPassage))
        }
        dernierPassage = ecoule

        let (lignes, information) = surveillanceMarques.nouvellesLignes(ecoule: ecoule)
        if let information { journal.ligne("INFO", information) }
        for texte in lignes {
            marquesVues += 1
            journal.ligne("MARQUE", texte)
        }

        let (surveilles, loginwindow) = scruteur.relever(ecoule: ecoule)
        suivreProcessus(surveilles)
        let ecrans = listerEcrans()
        let fenetres = releveFenetres.etudier(ecrans: ecrans)
        let sac = appelSAC()
        let verrouillage = verrous()
        let saisie = IsSecureEventInputEnabled()

        // L'empreinte ne contient ni l'heure, ni l'inactivité, ni le nombre de fenêtres : ils
        // changent sans cesse et noieraient les vrais changements.
        let empreinte = "processus=[" + surveilles.map(\.court).joined(separator: " ") + "] loginwindowPid=\(loginwindow) "
            + "\(sac) \(verrouillage) secureInput=\(saisie ? 1 : 0) "
            + "ecrans=" + ecrans.map(\.texte).joined(separator: " ") + " fenetres{\(fenetres.retenues)}"
        let changement = empreinte != empreintePrecedente
        let battementDu = ecoule >= prochainBattement
        if battementDu { prochainBattement = ecoule + Constantes.battement }

        releves += 1
        if changement || battementDu {
            let ligne = String(format: "hidIdle=%.1f ", inactivite()) + empreinte + " " + fenetres.compteurs
            if changement {
                changements += 1
                journal.ligne("CHANGEMENT", ligne)
            } else {
                battements += 1
                journal.ligne("BATTEMENT", ligne)
            }
        }
        empreintePrecedente = empreinte
        premierReleve = false
    }

    // MARK: Fin

    private func terminer(_ raison: String) {
        journal.ligne("FIN", "raison=\(raison) relevés=\(releves) changements=\(changements) battements=\(battements) "
                      + "marques=\(marquesVues)")
        journal.ligne("FIN", "notifications reçues : liste=\(recuesListe) workspace=\(recuesWorkspace) "
                      + "(témoin d'activation d'application=\(activationsWorkspace)) "
                      + "sansNom=\(recuesToutes) (noms distincts=\(nomsDistincts.count), "
                      + "dont de la liste fixe=\(recuesToutesDeLaListe))")
        journal.ligne("JOURNAL", journal.chemin)
        exit(0)
    }
}

// MARK: - Programme

signal(SIGPIPE, SIG_IGN)
let configuration = lireArguments(CommandLine.arguments)
guard let droitsDossier = preparerDossier(configuration.dossier) else {
    quitter("impossible de créer ou d'utiliser le dossier de sortie : \(configuration.dossier)", code: 1)
}
guard let journal = ouvrirJournal(dans: configuration.dossier) else {
    quitter("impossible de créer le journal dans \(configuration.dossier)", code: 1)
}
let avertissementDossier = droitsDossier & 0o077 == 0 ? nil
    : "le dossier de sortie existait déjà avec les droits \(String(droitsDossier, radix: 8)) "
    + "(autres que 700) : il n'a pas été modifié"
let sonde = Sonde(configuration: configuration, journal: journal, avertissementDossier: avertissementDossier)
sonde.demarrer()
RunLoop.main.run()
