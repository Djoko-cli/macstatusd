import XCTest
@testable import MacStatusCore

/// Règles pures de la topologie des écrans (plan 3, tâche 4) : quels écrans comptent, quand l'affichage est
/// éteint, et comment la liste se résume. Aucun système, aucun moteur. Identifiants, fournisseurs et modèles
/// sont inventés (`0x1234`, `0x5678`, `0x4321`).
final class DisplayTopologyTests: XCTestCase {
    private func instantane(_ ecrans: DisplayInfo..., enumerationOK: Bool = true) -> DisplaySnapshot {
        DisplaySnapshot(displays: ecrans, enumerationOK: enumerationOK)
    }

    // MARK: - Écran fantôme

    /// Le fantôme du système se reconnaît à son fournisseur ET à son modèle, ensemble : un seul des deux ne
    /// suffit pas, sinon un vrai écran de ce fournisseur disparaîtrait des comptes.
    func test_fantome_reconnuParFournisseurEtModele() {
        XCTAssertEqual(DisplayTopology.placeholderVendor, 0x756E6B6E)
        XCTAssertEqual(DisplayTopology.placeholderModel, 0x76697274)

        XCTAssertTrue(DisplayInfo.fantome(9).isPlaceholder)
        XCTAssertFalse(DisplayInfo.physique(1).isPlaceholder)
        let memeFournisseur = DisplayInfo(id: 2, vendor: DisplayTopology.placeholderVendor, model: 0x5678,
                                          asleep: false, isMain: false)
        let memeModele = DisplayInfo(id: 3, vendor: 0x1234, model: DisplayTopology.placeholderModel,
                                     asleep: false, isMain: false)
        XCTAssertFalse(memeFournisseur.isPlaceholder)
        XCTAssertFalse(memeModele.isPlaceholder)
    }

    /// Aucun écran physique : rien n'est endormi (il n'y a rien à endormir), zéro écran compté, preuve `none`.
    /// Un fantôme endormi, ou un avis d'extinction, n'y change rien. La liste complète reste rendue.
    func test_fantomeSeul_aucunEcranPhysique() {
        for fantome in [DisplayInfo.fantome(9, main: true), .fantome(9, asleep: true, main: true)] {
            for avis in [false, true] {
                let etat = DisplayTopology.state(instantane(fantome), screensAsleepNotified: avis)
                XCTAssertFalse(etat.asleep, "fantôme seul, avis \(avis)")
                XCTAssertEqual(etat.onlineCount, 0)
                XCTAssertEqual(etat.evidence, "none")
                XCTAssertTrue(etat.enumerationOK)
                XCTAssertEqual(etat.displays, [fantome], "la liste complète est rendue, fantôme compris")
            }
        }

        let vide = DisplayTopology.state(instantane(), screensAsleepNotified: false)
        XCTAssertFalse(vide.asleep)
        XCTAssertEqual(vide.onlineCount, 0)
        XCTAssertEqual(vide.evidence, "none")
        XCTAssertEqual(vide.displays, [])
    }

    /// Le fantôme est l'écran principal et reste éveillé, mais les écrans physiques dorment tous : l'affichage
    /// est éteint (point de vigilance 5).
    func test_fantomePrincipal_ecransPhysiquesEteints_displayAsleep() {
        let etat = DisplayTopology.state(
            instantane(.fantome(9, main: true), .physique(1, asleep: true), .physique(2, asleep: true)),
            screensAsleepNotified: false)
        XCTAssertTrue(etat.asleep)
        XCTAssertEqual(etat.evidence, "all")
        XCTAssertEqual(etat.onlineCount, 2, "le fantôme n'est pas compté")
        XCTAssertEqual(etat.displays.count, 3)
    }

    // MARK: - Preuves d'extinction

    /// L'écran principal est physique et endormi : cela suffit, même si un autre écran physique veille.
    func test_principalPhysiqueEteint_suffit() {
        let etat = DisplayTopology.state(
            instantane(.physique(1, asleep: true, main: true), .physique(2)),
            screensAsleepNotified: false)
        XCTAssertTrue(etat.asleep)
        XCTAssertEqual(etat.evidence, "main")
        XCTAssertEqual(etat.onlineCount, 2)
    }

    /// Un écran virtuel principal resté éveillé (fournisseur `0x4321`, que rien ne distingue d'un écran
    /// physique) retiendrait l'état ON : l'avis `screensDidSleep` du système départage dès qu'un écran
    /// physique est endormi. Sans l'avis, le même instantané est éveillé.
    func test_ecranVirtuelEveille_avisDuSysteme_departage() {
        let virtuel = DisplayInfo(id: 1, vendor: 0x4321, model: 0x5678, asleep: false, isMain: true)
        let ecrans = instantane(virtuel, .physique(2, asleep: true))

        let avecAvis = DisplayTopology.state(ecrans, screensAsleepNotified: true)
        XCTAssertTrue(avecAvis.asleep)
        XCTAssertEqual(avecAvis.evidence, "screensDidSleep")

        let sansAvis = DisplayTopology.state(ecrans, screensAsleepNotified: false)
        XCTAssertFalse(sansAvis.asleep)
        XCTAssertEqual(sansAvis.evidence, "awake")
    }

    /// L'avis du système seul ne dit rien : sans écran physique endormi (ou avec un seul fantôme endormi),
    /// les écrans sont éveillés.
    func test_avisDuSystemeSansEcranEndormi_neDitRien() {
        let eveilles = DisplayTopology.state(
            instantane(.physique(1, main: true), .physique(2)), screensAsleepNotified: true)
        XCTAssertFalse(eveilles.asleep)
        XCTAssertEqual(eveilles.evidence, "awake")

        let fantomeEndormi = DisplayTopology.state(
            instantane(.physique(1, main: true), .fantome(9, asleep: true)), screensAsleepNotified: true)
        XCTAssertFalse(fantomeEndormi.asleep, "un fantôme endormi n'est pas un écran physique endormi")
        XCTAssertEqual(fantomeEndormi.evidence, "awake")
    }

    /// Sans avis, un écran physique endormi qui n'est pas le principal, tous les autres veillant : éveillé.
    func test_ecranSecondaireEndormi_sansAvis_resteEveille() {
        let etat = DisplayTopology.state(
            instantane(.physique(1, main: true), .physique(2, asleep: true)), screensAsleepNotified: false)
        XCTAssertFalse(etat.asleep)
        XCTAssertEqual(etat.evidence, "awake")
    }

    /// L'état d'une énumération qui a échoué le dit : `enumerationOK` traverse la topologie sans changement.
    func test_enumerationRatee_traverseLaTopologie() {
        let etat = DisplayTopology.state(instantane(enumerationOK: false), screensAsleepNotified: false)
        XCTAssertFalse(etat.enumerationOK)
        XCTAssertEqual(etat.onlineCount, 0)
        XCTAssertEqual(etat.evidence, "none")
    }

    // MARK: - Résumé

    /// `*` principal, `z` endormi, `v` fantôme, dans l'ordre de la liste ; `none` pour une liste vide. Les
    /// marques se suivent dans cet ordre quand un même écran les cumule.
    func test_resume_principalEndormiEtFantome() {
        XCTAssertEqual(
            DisplayTopology.summary([.physique(0x5, main: true), .physique(0x2, asleep: true), .fantome(0x9)]),
            "0x5*,0x2z,0x9v")
        XCTAssertEqual(
            DisplayTopology.summary([.physique(0x5, asleep: true, main: true), .physique(0x2), .fantome(0x9)]),
            "0x5*z,0x2,0x9v")
        XCTAssertEqual(DisplayTopology.summary([.fantome(0xA, asleep: true, main: true)]), "0xa*zv",
                       "principal, endormi et fantôme à la fois")
        XCTAssertEqual(DisplayTopology.summary([.physique(0xABCDEF)]), "0xabcdef", "hexadécimal minuscule")
        XCTAssertEqual(DisplayTopology.summary([]), "none")
    }
}
