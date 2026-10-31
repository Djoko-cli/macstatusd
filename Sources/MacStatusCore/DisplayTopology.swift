import Foundation

/// Un écran en ligne, tel que le système le rapporte. Aucun framework système ici : l'exécutable lit
/// CoreGraphics (`LiveSystemSignals.displaySnapshot()`), le cœur ne fait que raisonner sur le résultat.
public struct DisplayInfo: Equatable {
    /// Identifiant de l'écran (`CGDirectDisplayID`).
    public var id: UInt32
    public var vendor: UInt32
    public var model: UInt32
    /// L'écran dort (`CGDisplayIsAsleep`).
    public var asleep: Bool
    /// L'écran est le principal (`CGMainDisplayID`).
    public var isMain: Bool

    public init(id: UInt32, vendor: UInt32, model: UInt32, asleep: Bool, isMain: Bool) {
        self.id = id
        self.vendor = vendor
        self.model = model
        self.asleep = asleep
        self.isMain = isMain
    }

    /// L'écran fantôme du système : au réveil capot fermé ou dock débranché, macOS peut ne montrer que lui,
    /// avant que les écrans physiques reviennent. Il se reconnaît à son fournisseur ET à son modèle.
    public var isPlaceholder: Bool {
        vendor == DisplayTopology.placeholderVendor && model == DisplayTopology.placeholderModel
    }

    /// Identifiant en hexadécimal minuscule, tel que /status et le journal l'écrivent (`0x5`).
    var idText: String { "0x" + String(id, radix: 16) }
}

/// Les écrans en ligne à un instant donné, et si l'énumération a réussi.
public struct DisplaySnapshot {
    public var displays: [DisplayInfo]
    /// Faux : l'énumération a échoué, la liste ne prouve rien (pas même l'absence d'écran).
    public var enumerationOK: Bool

    public init(displays: [DisplayInfo], enumerationOK: Bool) {
        self.displays = displays
        self.enumerationOK = enumerationOK
    }
}

/// Règles pures sur les écrans : lesquels comptent, quand l'affichage est éteint, comment la liste se résume.
public enum DisplayTopology {
    /// Fournisseur de l'écran fantôme du système : `unkn` (quatre caractères).
    public static let placeholderVendor: UInt32 = 0x756E6B6E
    /// Modèle de l'écran fantôme du système : `virt`.
    public static let placeholderModel: UInt32 = 0x76697274

    /// État des écrans tiré d'un instantané. Les écrans physiques sont ceux qui ne sont pas le fantôme ;
    /// la première règle vraie décide :
    ///
    /// 1. aucun écran physique : éveillé, preuve `none` ;
    /// 2. l'écran principal est physique et endormi : éteint, preuve `main` ;
    /// 3. tous les écrans physiques dorment : éteint, preuve `all` ;
    /// 4. avis `screensDidSleep` du système et au moins un écran physique endormi : éteint, preuve
    ///    `screensDidSleep`. Un écran virtuel resté éveillé ne retient plus l'état ON ;
    /// 5. sinon : éveillé, preuve `awake`.
    ///
    /// `onlineCount` ne compte que les écrans physiques ; `displays` rend la liste complète, fantôme compris.
    public static func state(_ snapshot: DisplaySnapshot, screensAsleepNotified: Bool) -> DisplayState {
        let physical = snapshot.displays.filter { !$0.isPlaceholder }
        let asleep: Bool
        let evidence: String
        if physical.isEmpty {
            (asleep, evidence) = (false, "none")
        } else if physical.contains(where: { $0.isMain && $0.asleep }) {
            (asleep, evidence) = (true, "main")
        } else if physical.allSatisfy({ $0.asleep }) {
            (asleep, evidence) = (true, "all")
        } else if screensAsleepNotified, physical.contains(where: { $0.asleep }) {
            (asleep, evidence) = (true, "screensDidSleep")
        } else {
            (asleep, evidence) = (false, "awake")
        }
        return DisplayState(asleep: asleep, onlineCount: physical.count, enumerationOK: snapshot.enumerationOK,
                            evidence: evidence, displays: snapshot.displays)
    }

    /// Résumé d'une ligne, dans l'ordre de la liste : l'identifiant en hexadécimal, puis `*` (principal),
    /// `z` (endormi) et `v` (fantôme), dans cet ordre quand elles se cumulent : `0x5*,0x2z,0x9v`.
    /// `none` pour une liste vide.
    public static func summary(_ displays: [DisplayInfo]) -> String {
        guard !displays.isEmpty else { return "none" }
        return displays
            .map { $0.idText + ($0.isMain ? "*" : "") + ($0.asleep ? "z" : "") + ($0.isPlaceholder ? "v" : "") }
            .joined(separator: ",")
    }
}
