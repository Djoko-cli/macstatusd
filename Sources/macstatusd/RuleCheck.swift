import Foundation

/// Vérification de la règle de décision de l'économiseur d'écran, sans
/// économiseur réel et sans dépendre d'une frappe humaine : les sources sont
/// injectées, et `hidIdle` / `now` sont fournis explicitement.
///
/// Le scénario reproduit la séquence mesurée sur macOS 26.5 (voir
/// diagnostics/saver-probe.swift) : l'économiseur démarre, tourne seul, puis une
/// frappe fait apparaître le panneau d'authentification par‑dessus un
/// économiseur qui, lui, continue de tourner.
enum RuleCheck {
    static func run() -> Int32 {
        var failures = 0

        func expect(_ label: String, _ condition: Bool) {
            if condition {
                print("  OK   \(label)")
            } else {
                print("  FAIL \(label)")
                failures += 1
            }
        }

        // --- Scénario nominal : démarrage, occupation, frappe, déverrouillage ---
        var saverPID: Int32 = 0
        let oracle = ScreenSaverOracle(minimumInterval: 1,
                                       dismissOnInput: true,
                                       dismissGrace: 1.5,
                                       redisplayIdle: 90,
                                       processProbe: { saverPID },
                                       windowProbe: { .notVisible })
        let t0 = Date()

        var verdict = oracle.verdict(now: t0, hidIdle: 3.0)
        expect("aucun économiseur → inactif", !verdict.active && !verdict.running)

        // L'économiseur démarre ; la dernière activité est antérieure.
        saverPID = 4242
        verdict = oracle.verdict(now: t0 + 1, hidIdle: 4.0)
        expect("économiseur démarré, aucune activité depuis → OFF",
               verdict.active && verdict.running && !verdict.dismissed)

        verdict = oracle.verdict(now: t0 + 10, hidIdle: 13.0)
        expect("économiseur qui tourne seul depuis 10 s → toujours OFF", verdict.active)

        // Frappe clavier : le panneau d'authentification recouvre l'économiseur,
        // qui reste en cours d'exécution.
        verdict = oracle.verdict(now: t0 + 15, hidIdle: 0.2)
        expect("activité après le démarrage → écarté, donc ON",
               !verdict.active && verdict.running && verdict.dismissed)
        expect("preuve explicite de l'écartement", verdict.evidence.contains("écarté-par-activité"))

        verdict = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        expect("saisie du mot de passe en cours → toujours ON", !verdict.active)

        // Personne ne répond au panneau : macOS revient à l'économiseur.
        verdict = oracle.verdict(now: t0 + 120, hidIdle: 95)
        expect("inactivité prolongée → économiseur réaffiché, retour à OFF", verdict.active)
        expect("preuve de réaffichage", verdict.evidence.contains("réaffiché"))

        // Déverrouillage : le process disparaît.
        saverPID = 0
        verdict = oracle.verdict(now: t0 + 130, hidIdle: 0.1)
        expect("économiseur terminé → inactif", !verdict.active && !verdict.running)

        // --- Nouveau démarrage après écartement (PID différent) ---
        saverPID = 5000
        verdict = oracle.verdict(now: t0 + 140, hidIdle: 0.1)
        expect("redémarrage avec un nouveau PID → OFF malgré l'activité récente", verdict.active)
        verdict = oracle.verdict(now: t0 + 145, hidIdle: 0.1)
        expect("activité après ce redémarrage → ON", !verdict.active)

        // --- Règle désactivée ---
        var pid2: Int32 = 7000
        let strict = ScreenSaverOracle(minimumInterval: 1,
                                       dismissOnInput: false,
                                       processProbe: { pid2 },
                                       windowProbe: { .notVisible })
        var strictVerdict = strict.verdict(now: t0, hidIdle: 0.0)
        expect("saver_dismiss_on_input=false → l'activité est ignorée", strictVerdict.active)
        pid2 = 0
        strictVerdict = strict.verdict(now: t0 + 1, hidIdle: 0.0)
        expect("saver_dismiss_on_input=false → suit quand même le process", !strictVerdict.active)

        // --- Inactivité indisponible ---
        var pid3: Int32 = 8000
        let noIdle = ScreenSaverOracle(minimumInterval: 1,
                                       processProbe: { pid3 },
                                       windowProbe: { .notVisible })
        var noIdleVerdict = noIdle.verdict(now: t0, hidIdle: -1)
        expect("hidIdle indisponible → on ne conclut pas à l'écartement", noIdleVerdict.active)
        pid3 = 0
        noIdleVerdict = noIdle.verdict(now: t0 + 1, hidIdle: -1)
        expect("hidIdle indisponible → suit le process", !noIdleVerdict.active)

        // --- Oracle fenêtres seul (économiseur hébergé par legacyScreenSaver) ---
        var windowState = ScreenSaverOracle.WindowVerdict.visible
        let windowOnly = ScreenSaverOracle(minimumInterval: 0,
                                           processProbe: { 0 },
                                           windowProbe: { windowState })
        var windowVerdict = windowOnly.verdict(now: t0, hidIdle: 5)
        expect("fenêtre d'économiseur à l'écran sans process → OFF",
               windowVerdict.active && windowVerdict.evidence.contains("window"))
        windowState = .notVisible
        windowVerdict = windowOnly.verdict(now: t0 + 1, hidIdle: 5)
        expect("fenêtre disparue → inactif", !windowVerdict.active)

        print("")
        print(failures == 0 ? "règles: toutes vérifiées" : "règles: \(failures) échec(s)")
        return failures == 0 ? 0 : 1
    }
}
