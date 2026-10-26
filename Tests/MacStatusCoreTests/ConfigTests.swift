import XCTest
@testable import MacStatusCore

final class ConfigTests: XCTestCase {
    func test_fichierAbsent_donneLesDefautsEtUnAvertissement() {
        let r = Config.parse(data: nil)
        XCTAssertFalse(r.config.enabled); XCTAssertEqual(r.config.port, 9090)
        // « introuvable », puis l'écoute limitée à la boucle locale (Ruling R39).
        XCTAssertEqual(r.warnings.count, 2, "\(r.warnings)")
    }

    func test_clesConnues_sontLues() {
        let json = #"{"enabled":true,"webhook_base_url":"http://192.0.2.10:51828","port":"9191","settle_off_ms":900}"#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertTrue(r.config.enabled); XCTAssertEqual(r.config.port, 9191); XCTAssertEqual(r.config.settleOffMS, 900)
    }

    func test_bornes_sontAppliquees() {        // poll_interval_ms 10 → 100, settle_on_ms 99999 → 10000
        let r = Config.parse(data: Data(#"{"poll_interval_ms":10,"settle_on_ms":99999}"#.utf8))
        XCTAssertEqual(r.config.pollIntervalMS, 100); XCTAssertEqual(r.config.settleOnMS, 10_000)
    }

    func test_cleInconnue_donneUnAvertissement() {
        let r = Config.parse(data: Data(#"{"prot":9090}"#.utf8))
        XCTAssertTrue(r.warnings.contains { $0.contains("prot") })
    }

    func test_accesHTTP_defautsEtLecture() {
        let defauts = Config.parse(data: Data("{}".utf8)).config
        XCTAssertFalse(defauts.allowQueryToken)
        XCTAssertEqual(defauts.allowedHosts, [])
        let json = #"{"allow_query_token":true,"allowed_hosts":["Passerelle.Example","mac-essai.example"]}"#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertTrue(r.config.allowQueryToken)
        XCTAssertEqual(r.config.allowedHosts, ["Passerelle.Example", "mac-essai.example"])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
    }

    func test_allowedHosts_dUnAutreType_defautEtAvertissement() {
        for json in [#"{"allowed_hosts":"passerelle.example"}"#, #"{"allowed_hosts":[1,2]}"#] {
            let r = Config.parse(data: Data(json.utf8))
            XCTAssertEqual(r.config.allowedHosts, [], json)
            XCTAssertTrue(r.warnings.contains { $0.contains("allowed_hosts") }, json)
        }
    }

    func test_offActionInconnue_garderLeDefaut() {
        XCTAssertEqual(Config.parse(data: Data(#"{"off_action":"nimporte"}"#.utf8)).config.offAction, .screensaver)
    }

    // --- Ajouts : `load(path:)` doit continuer à citer le chemin dans ses avertissements ---

    func test_load_fichierAbsent_citeLeChemin() {
        let chemin = "/chemin/inexistant/config-essai.json"
        let r = Config.load(path: chemin)
        XCTAssertEqual(r.warnings.count, 2, "\(r.warnings)")
        guard let avertissement = r.warnings.first else { return }
        XCTAssertTrue(avertissement.contains(chemin), "avertissement sans chemin : \(avertissement)")
        XCTAssertTrue(avertissement.contains("introuvable"))
        XCTAssertFalse(r.config.enabled)
    }

    func test_load_jsonInvalide_citeLeChemin() throws {
        let dossier = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstatusd-essai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dossier) }
        let fichier = dossier.appendingPathComponent("config.json")
        // JSON tronqué. Attention : la virgule finale `{"port": 9191,}` est acceptée par le
        // JSONSerialization de macOS, elle ne sert donc pas de JSON invalide.
        try Data(#"{"port": 9191"#.utf8).write(to: fichier)

        let r = Config.load(path: fichier.path)
        XCTAssertEqual(r.warnings.count, 1)
        guard let avertissement = r.warnings.first else { return }
        XCTAssertTrue(avertissement.contains(fichier.path), "avertissement sans chemin : \(avertissement)")
        XCTAssertTrue(avertissement.contains("illisible"))
        XCTAssertEqual(r.config.port, 9090)
    }

    func test_parse_jsonInvalide_donneLesDefautsEtUnAvertissement() {
        let r = Config.parse(data: Data(#"{"port": 9191"#.utf8))
        XCTAssertEqual(r.config.port, 9090)
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertTrue(r.warnings.first?.contains("illisible") ?? false)
    }

    // MARK: - auth_token (tâche 8, tour 1)

    func test_authToken_valide_aucunAvertissement() {
        let r = Config.parse(data: Data(#"{"auth_token":"jeton-essai-0123456789abcdef"}"#.utf8))
        XCTAssertEqual(r.config.authToken, "jeton-essai-0123456789abcdef")
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        // Absent ou vide : rien à signaler ici (main.swift traite le cas « aucun jeton »).
        XCTAssertTrue(Config.parse(data: Data(#"{"auth_token":""}"#.utf8)).warnings.isEmpty)
        XCTAssertTrue(Config.parse(data: Data("{}".utf8)).warnings.isEmpty)
    }

    func test_authToken_espacesDeBord_avertissement() {
        for json in [#"{"auth_token":" jeton-essai-0123456789abcdef"}"#, #"{"auth_token":"jeton-essai-0123456789abcdef\t"}"#] {
            let r = Config.parse(data: Data(json.utf8))
            XCTAssertTrue(r.warnings.contains { $0.contains("auth_token") && $0.contains("espace") }, "\(json) \(r.warnings)")
            XCTAssertFalse(r.warnings.contains { $0.contains("jeton-essai") }, "\(r.warnings)")
        }
    }

    func test_authToken_pasUneChaine_avertissement() {
        for json in [#"{"auth_token":1234567890123456789}"#, #"{"auth_token":true}"#, #"{"auth_token":["a"]}"#] {
            let r = Config.parse(data: Data(json.utf8))
            XCTAssertTrue(r.warnings.contains { $0.contains("auth_token") && $0.contains("chaîne") }, "\(json) \(r.warnings)")
            // Plus ignoré : mode dégradé fermé (tâche 12, tour 1).
            XCTAssertEqual(r.origin, .invalid(reason: "auth_token doit être une chaîne JSON"), json)
        }
    }

    func test_authToken_tropCourt_avertissement() {
        let r = Config.parse(data: Data(#"{"auth_token":"jeton-court"}"#.utf8))
        XCTAssertTrue(r.warnings.contains { $0.contains("auth_token") && $0.contains("16") }, "\(r.warnings)")
        XCTAssertFalse(r.warnings.contains { $0.contains("jeton-court") }, "\(r.warnings)")
        // 16 caractères exactement : accepté sans avertissement.
        XCTAssertTrue(Config.parse(data: Data(#"{"auth_token":"0123456789abcdef"}"#.utf8)).warnings.isEmpty)
    }
}

// MARK: - Tâche 12 : mode dégradé fermé, avertissements nommés

final class ConfigOriginTests: XCTestCase {
    private let jeton = "jeton-essai-0123456789abcdef"

    /// Dossier temporaire propre à un test, effacé à la fin.
    private func dossierTemporaire() throws -> URL {
        let dossier = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstatusd-essai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dossier) }
        return dossier
    }

    private func requete(_ chemin: String, local: Bool) -> HTTPRequest {
        HTTPRequest(method: "GET", target: chemin, path: chemin, version: "HTTP/1.1",
                    headers: ["host": "192.0.2.10:9090"],
                    peer: local ? "127.0.0.1" : "192.0.2.10", peerIsLoopback: local)
    }

    /// Tâche 14 : `publish_off_on_exit` vaut vrai par défaut, se règle, et un type inattendu garde le défaut.
    func test_publishOffOnExit_defautVrai_etReglable() {
        XCTAssertTrue(Config().publishOffOnExit)
        XCTAssertTrue(Config.parse(data: Data("{}".utf8)).config.publishOffOnExit)
        let faux = Config.parse(data: Data(#"{"publish_off_on_exit": false}"#.utf8))
        XCTAssertFalse(faux.config.publishOffOnExit)
        XCTAssertFalse(faux.warnings.contains { $0.contains("inconnues") }, "\(faux.warnings)")
        let casse = Config.parse(data: Data(#"{"publish_off_on_exit": []}"#.utf8))
        XCTAssertTrue(casse.config.publishOffOnExit)
        XCTAssertTrue(casse.warnings.contains { $0.hasPrefix("publish_off_on_exit") }, "\(casse.warnings)")
    }

    func test_jsonInvalide_donneModeDegrade() throws {
        // Config durcie (jeton, écoute ouverte, webhooks), puis tronquée par une faute de frappe.
        let tronque = #"{"auth_token": "jeton-essai-0123456789abcdef", "enabled": true, "bind_address": "0.0.0.0", "port":"#
        let r = Config.parse(data: Data(tronque.utf8))
        guard case .invalid(let raison) = r.origin else { return XCTFail("origine \(r.origin)") }
        XCTAssertFalse(raison.isEmpty)
        XCTAssertEqual(r.config.bindAddress, "127.0.0.1")
        XCTAssertEqual(ListenAddress(bindAddress: r.config.bindAddress), .ipv4("127.0.0.1"))
        XCTAssertTrue(bindAddressIsLoopbackOnly(r.config.bindAddress))
        XCTAssertFalse(r.config.enabled)
        XCTAssertEqual(r.config.webhookBaseURL, "")
        XCTAssertEqual(r.config.heartbeatSeconds, 0)
        XCTAssertEqual(r.config.authToken, "", "rien n'est lu d'un fichier invalide")
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertTrue(r.warnings[0].contains("illisible"), r.warnings[0])
        XCTAssertTrue(r.warnings[0].contains("127.0.0.1"), r.warnings[0])
        for texte in r.warnings + [raison] {
            XCTAssertFalse(texte.contains("0123456789abcdef"), "secret au journal : \(texte)")
        }

        // Valeur sans guillemets : l'erreur de l'analyseur ne doit pas recopier le jeton.
        let sansGuillemets = Config.parse(data: Data(#"{"auth_token": jeton-essai-0123456789abcdef}"#.utf8))
        guard case .invalid(let raison2) = sansGuillemets.origin else { return XCTFail("\(sansGuillemets.origin)") }
        XCTAssertFalse((sansGuillemets.warnings + [raison2]).contains { $0.contains("0123456789abcdef") })

        // Fichier vide, ou JSON qui n'est pas un objet : invalide aussi.
        for contenu in ["", "[]", #""texte""#, "42"] {
            let v = Config.parse(data: Data(contenu.utf8))
            guard case .invalid = v.origin else { XCTFail("\(contenu) → \(v.origin)"); continue }
            XCTAssertEqual(v.config.bindAddress, "127.0.0.1", contenu)
            XCTAssertFalse(v.config.enabled, contenu)
        }
    }

    func test_load_jsonInvalide_origineInvalideAvecLaRaison() throws {
        let fichier = try dossierTemporaire().appendingPathComponent("config.json")
        try Data(#"{"auth_token": "jeton-essai-0123456789abcdef", "port":"#.utf8).write(to: fichier)
        let r = Config.load(path: fichier.path)
        guard case .invalid(let raison) = r.origin else { return XCTFail("\(r.origin)") }
        XCTAssertFalse(raison.isEmpty)
        XCTAssertTrue(r.warnings[0].contains(fichier.path))
        XCTAssertEqual(r.config.bindAddress, "127.0.0.1")
    }

    func test_load_fichierIllisible_origineInvalideAvecErreurPOSIX() throws {
        let dossier = try dossierTemporaire()
        // Un dossier à la place du fichier.
        let r = Config.load(path: dossier.path)
        guard case .invalid(let raison) = r.origin else { return XCTFail("\(r.origin)") }
        XCTAssertTrue(raison.contains("errno \(EISDIR)"), raison)
        XCTAssertEqual(r.config.bindAddress, "127.0.0.1")
        XCTAssertFalse(r.config.enabled)

        // Fichier sans droit de lecture (le test ne tourne pas en root).
        if getuid() != 0 {
            let fichier = dossier.appendingPathComponent("config.json")
            try Data(#"{"port": 19190}"#.utf8).write(to: fichier)
            XCTAssertEqual(chmod(fichier.path, 0), 0)
            defer { chmod(fichier.path, 0o600) }
            let s = Config.load(path: fichier.path)
            guard case .invalid(let raison) = s.origin else { return XCTFail("\(s.origin)") }
            XCTAssertTrue(raison.contains("errno \(EACCES)"), raison)
            XCTAssertEqual(s.config.bindAddress, "127.0.0.1")
            XCTAssertTrue(s.warnings.first?.contains("illisible") ?? false)
        }
    }

    func test_fichierAbsent_restePermissif_maisEcouteEnBoucleLocale() throws {
        let chemin = try dossierTemporaire().appendingPathComponent("absent.json").path
        for r in [Config.parse(data: nil), Config.load(path: chemin)] {
            XCTAssertEqual(r.origin, .defaultsAbsent)
            // Ruling R39 : écoute forcée sur la boucle locale ; le reste des défauts est gardé
            // (aucun jeton, webhooks coupés, port 9090).
            XCTAssertEqual(r.config.bindAddress, "127.0.0.1")
            XCTAssertTrue(bindAddressIsLoopbackOnly(r.config.bindAddress))
            XCTAssertEqual(r.config.authToken, "")
            XCTAssertEqual(r.config.port, 9090)
            XCTAssertFalse(r.config.enabled)
            XCTAssertEqual(r.config.heartbeatSeconds, Config().heartbeatSeconds)
            XCTAssertEqual(r.warnings.count, 2, "\(r.warnings)")
            XCTAssertTrue(r.warnings.contains("config absente : écoute limitée à la boucle locale"), "\(r.warnings)")
        }
        // Sans jeton, la politique d'accès ne sert que la boucle locale (inchangée).
        let config = Config.parse(data: nil).config
        let politique = AccessPolicy(authToken: config.authToken, allowQueryToken: config.allowQueryToken,
                                     allowedHosts: config.allowedHosts, localNames: [])
        for chemin in ["/state", "/status", "/wake", "/sleep", "/resync"] {
            XCTAssertEqual(politique.decide(requete(chemin, local: true)), .allow, chemin)
            XCTAssertEqual(politique.decide(requete(chemin, local: false)),
                           .deny(status: 403, reason: "no-token-configured"), chemin)
        }
    }

    func test_fichierValide_origineFichier() {
        let r = Config.parse(data: Data(#"{"port": 9191,}"#.utf8))   // virgule finale acceptée (R14)
        XCTAssertEqual(r.origin, .file)
        XCTAssertEqual(r.config.port, 9191)
        XCTAssertEqual(Config.parse(data: Data("{}".utf8)).origin, .file)
    }

    // MARK: Avertissements nommés

    func test_valeurHorsBornes_avertit() {
        let r = Config.parse(data: Data(#"{"poll_interval_ms": 10, "settle_on_ms": 99999, "webhook_retries": -1}"#.utf8))
        XCTAssertEqual(r.origin, .file)
        XCTAssertEqual(r.config.pollIntervalMS, 100)
        XCTAssertEqual(r.config.settleOnMS, 10_000)
        XCTAssertEqual(r.config.webhookRetries, 0)
        for cle in ["poll_interval_ms", "settle_on_ms", "webhook_retries"] {
            XCTAssertTrue(r.warnings.contains { $0.contains(cle) && $0.contains("hors bornes") }, "\(cle) : \(r.warnings)")
        }
        XCTAssertEqual(r.warnings.count, 3, "\(r.warnings)")

        // Port hors bornes : défaut, pas une borne surprenante.
        let p = Config.parse(data: Data(#"{"port": 70000}"#.utf8))
        XCTAssertEqual(p.config.port, 9090)
        XCTAssertTrue(p.warnings.contains { $0.contains("port") && $0.contains("hors bornes") }, "\(p.warnings)")
        XCTAssertEqual(Config.parse(data: Data(#"{"port": 0}"#.utf8)).config.port, 9090)

        // Délai d'escalade corrigé : plus en silence.
        let e = Config.parse(data: Data(#"{"command_confirm_timeout_ms": 3000, "command_escalate_after_ms": 5000}"#.utf8))
        XCTAssertEqual(e.config.commandEscalateAfterMS, 1500)
        XCTAssertTrue(e.warnings.contains { $0.contains("command_escalate_after_ms") }, "\(e.warnings)")
    }

    func test_typeInattendu_avertitEtGardeLeDefaut() {
        let json = #"{"settle_on_ms": true, "settle_off_ms": "lent", "heartbeat_seconds": 1.5, "accessory_id": 12, "#
            + #""log_file": ["a"], "enabled": [1], "off_command": 3}"#
        let r = Config.parse(data: Data(json.utf8))
        let defauts = Config()
        XCTAssertEqual(r.config.settleOnMS, defauts.settleOnMS)
        XCTAssertEqual(r.config.settleOffMS, defauts.settleOffMS)
        XCTAssertEqual(r.config.heartbeatSeconds, defauts.heartbeatSeconds)
        XCTAssertEqual(r.config.accessoryID, defauts.accessoryID)
        XCTAssertEqual(r.config.logFile, defauts.logFile)
        XCTAssertEqual(r.config.enabled, defauts.enabled)
        XCTAssertEqual(r.config.offCommand, defauts.offCommand)
        for cle in ["settle_on_ms", "settle_off_ms", "heartbeat_seconds", "accessory_id", "log_file", "enabled", "off_command"] {
            XCTAssertTrue(r.warnings.contains { $0.hasPrefix(cle) }, "\(cle) : \(r.warnings)")
        }
        XCTAssertEqual(r.warnings.count, 7, "\(r.warnings)")

        // Un entier en chaîne reste accepté sans avertissement (compatibilité).
        let c = Config.parse(data: Data(#"{"port": "9191", "settle_off_ms": 900}"#.utf8))
        XCTAssertEqual(c.config.port, 9191)
        XCTAssertTrue(c.warnings.isEmpty, "\(c.warnings)")
    }

    func test_booleenChaine_offAccepte() {
        for faux in [#""off""#, #""OFF""#, #""no""#, #""false""#, #""0""#, "0", "false"] {
            let r = Config.parse(data: Data(#"{"stop_screensaver_on_wake": \#(faux)}"#.utf8))
            XCTAssertFalse(r.config.stopScreensaverOnWake, faux)
            XCTAssertTrue(r.warnings.isEmpty, "\(faux) : \(r.warnings)")
        }
        for vrai in [#""on""#, #""yes""#, #""true""#, #""1""#, "1", "true"] {
            let r = Config.parse(data: Data(#"{"require_auth_ui_when_locked": \#(vrai)}"#.utf8))
            XCTAssertTrue(r.config.requireAuthUIWhenLocked, vrai)
            XCTAssertTrue(r.warnings.isEmpty, "\(vrai) : \(r.warnings)")
        }
        // Chaîne non reconnue : avertissement nommé, défaut gardé (et non plus `false` en silence).
        for inconnu in [#""oui""#, #""désactivé""#, "2"] {
            let r = Config.parse(data: Data(#"{"stop_screensaver_on_wake": \#(inconnu)}"#.utf8))
            XCTAssertEqual(r.config.stopScreensaverOnWake, Config().stopScreensaverOnWake, inconnu)
            XCTAssertTrue(r.warnings.contains { $0.hasPrefix("stop_screensaver_on_wake") }, "\(inconnu) : \(r.warnings)")
        }
    }

    func test_commandeRelative_avertit() {
        let r = Config.parse(data: Data(#"{"off_command": ["pmset", "displaysleepnow"], "wake_command": ["caffeinate", "-u"]}"#.utf8))
        XCTAssertEqual(r.config.offCommand, ["pmset", "displaysleepnow"])
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("off_command") && $0.contains("absolu") }, "\(r.warnings)")
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("wake_command") && $0.contains("absolu") }, "\(r.warnings)")

        let ok = Config.parse(data: Data(#"{"off_command": ["/usr/bin/true"], "wake_command": "echo essai"}"#.utf8))
        XCTAssertEqual(ok.config.wakeCommand, ["/bin/sh", "-c", "echo essai"])
        XCTAssertTrue(ok.warnings.isEmpty, "\(ok.warnings)")
    }

    func test_bindAddressInvalide_repliFermeSurBoucleLocale() {   // Ruling R32
        for json in [#"{"bind_address": "Mac-Essai.local", "port": 19190}"#, #"{"bind_address": 127, "port": 19190}"#] {
            let r = Config.parse(data: Data(json.utf8))
            XCTAssertEqual(r.origin, .file, json)
            XCTAssertEqual(r.config.bindAddress, "127.0.0.1", json)
            XCTAssertTrue(r.warnings.contains { $0.contains("bind_address") && $0.contains("127.0.0.1:19190") },
                          "\(json) : \(r.warnings)")
        }
    }

    func test_avertissements_neMontrentNiJetonNiURL() {
        // Jeton qui n'est pas une chaîne : mode dégradé, la raison et l'avertissement ne citent
        // jamais la valeur.
        let jetonNombre = Config.parse(data: Data(#"{"auth_token": 12345678901234567, "enabled": true}"#.utf8))
        XCTAssertEqual(jetonNombre.origin, .invalid(reason: "auth_token doit être une chaîne JSON"))
        XCTAssertEqual(jetonNombre.config.authToken, "")
        XCTAssertTrue(jetonNombre.warnings.contains { $0.contains("auth_token") }, "\(jetonNombre.warnings)")
        XCTAssertFalse(jetonNombre.warnings.contains { $0.contains("12345678901234567") }, "\(jetonNombre.warnings)")

        let json = #"{"webhook_base_url": "ftp://192.0.2.10/api/webhook/ident-secret-essai?k=v", "enabled": true}"#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertEqual(r.origin, .file)
        XCTAssertTrue(r.warnings.contains { $0.contains("webhook_base_url") && $0.contains("<masqué>") }, "\(r.warnings)")
        XCTAssertFalse(r.warnings.contains { $0.contains("ident-secret-essai") || $0.contains("k=v") }, "\(r.warnings)")
        // Une URL http valide ne donne rien.
        let ok = Config.parse(data: Data(#"{"webhook_base_url": "http://192.0.2.10:51828", "enabled": true}"#.utf8))
        XCTAssertTrue(ok.warnings.isEmpty, "\(ok.warnings)")
    }

    /// Tâche 12, tour 1 : un `auth_token` présent mais pas une chaîne n'est plus ignoré (écoute
    /// ouverte sans jeton, commandes locales sans jeton) : il met la config en mode dégradé fermé.
    func test_jetonPasUneChaine_modeDegradeFerme() {
        let r = Config.parse(data: Data(#"{"auth_token": 12345678901234567, "bind_address": "0.0.0.0"}"#.utf8))
        XCTAssertEqual(r.origin, .invalid(reason: "auth_token doit être une chaîne JSON"))
        XCTAssertEqual(r.config.bindAddress, "127.0.0.1")
        XCTAssertEqual(r.config.authToken, "")
        XCTAssertFalse(r.config.enabled)
        XCTAssertEqual(r.warnings.count, 1, "\(r.warnings)")
        XCTAssertTrue(r.warnings[0].contains("auth_token") && r.warnings[0].contains("127.0.0.1"), r.warnings[0])

        let valeurs = ["null", "true", "false", "0", "1.5", #"["jeton-essai-0123456789abcdef"]"#,
                       #"{"v": "jeton-essai-0123456789abcdef"}"#]
        for valeur in valeurs {
            let json = #"{"auth_token": \#(valeur), "bind_address": "0.0.0.0", "enabled": true, "#
                + #""webhook_base_url": "http://192.0.2.10:51828"}"#
            let v = Config.parse(data: Data(json.utf8))
            XCTAssertEqual(v.origin, .invalid(reason: "auth_token doit être une chaîne JSON"), valeur)
            XCTAssertEqual(v.config.bindAddress, "127.0.0.1", valeur)
            XCTAssertFalse(v.config.enabled, valeur)
            XCTAssertEqual(v.config.webhookBaseURL, "", valeur)
            XCTAssertFalse(v.warnings.contains { $0.contains("0123456789abcdef") }, "\(valeur) : \(v.warnings)")
        }
        // Une chaîne vide reste « aucun jeton » (boucle locale seulement), sans mode dégradé.
        XCTAssertEqual(Config.parse(data: Data(#"{"auth_token": ""}"#.utf8)).origin, .file)
    }

    /// Ruling R43 : si le JSON a été lu (ici, un `auth_token` mal typé), le mode dégradé garde le
    /// `port` du fichier ; seuls un fichier illisible ou un JSON invalide prennent 9090.
    func test_modeDegrade_jsonLu_gardeLePortDuFichier() {
        let r = Config.parse(data: Data(#"{"auth_token": 12345678901234567, "port": 19190, "bind_address": "0.0.0.0"}"#.utf8))
        XCTAssertEqual(r.origin, .invalid(reason: "auth_token doit être une chaîne JSON"))
        XCTAssertEqual(r.config.port, 19190)
        XCTAssertEqual(r.config.bindAddress, "127.0.0.1")
        XCTAssertFalse(r.config.enabled)
        XCTAssertEqual(r.config.authToken, "")

        // Port sous forme de chaîne (accepté ailleurs) ; hors bornes ou mal typé : le défaut.
        XCTAssertEqual(Config.parse(data: Data(#"{"auth_token": null, "port": "19191"}"#.utf8)).config.port, 19191)
        for port in ["70000", "0", "-5", "true", #""abc""#, "1.5", "null", "[19190]"] {
            let v = Config.parse(data: Data(#"{"auth_token": 1, "port": \#(port)}"#.utf8))
            XCTAssertEqual(v.origin, .invalid(reason: "auth_token doit être une chaîne JSON"), port)
            XCTAssertEqual(v.config.port, 9090, port)
        }
        // Aucun port dans le fichier : le défaut.
        XCTAssertEqual(Config.parse(data: Data(#"{"auth_token": 1}"#.utf8)).config.port, 9090)
        // L'avertissement du mode dégradé ne change pas.
        XCTAssertEqual(r.warnings.count, 1, "\(r.warnings)")

        // JSON invalide ou pas un objet : le port du fichier n'est pas fiable, défaut 9090.
        for json in [#"{"port": 19190, "enabled":"#, #"[{"port": 19190}]"#, "port=19190"] {
            let v = Config.parse(data: Data(json.utf8))
            guard case .invalid = v.origin else { return XCTFail("mode dégradé attendu : \(json)") }
            XCTAssertEqual(v.config.port, 9090, json)
        }
    }

    func test_cliPort_bornes() {
        XCTAssertEqual(Config.portArgument("1"), 1)
        XCTAssertEqual(Config.portArgument("19190"), 19190)
        XCTAssertEqual(Config.portArgument("65535"), 65535)
        for invalide in ["", "0", "65536", "70000", "-1", "+80", " 80", "80a", "abc", "99999999999999999999"] {
            XCTAssertNil(Config.portArgument(invalide), invalide)
        }
    }

    // MARK: - Tâche 15 : cibles du webhook

    func test_webhookBaseURL_devientUneCible() {
        let r = Config.parse(data: Data(#"{"enabled": true, "webhook_base_url": "http://192.0.2.10:51828/"}"#.utf8))
        XCTAssertEqual(r.config.webhookTargets, [WebhookTarget(url: "http://192.0.2.10:51828/", method: "GET", headers: [:])])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        XCTAssertEqual(Config.parse(data: Data("{}".utf8)).config.webhookTargets, [])
        // Une config construite à la main (tests, mode --no-webhook) suit la même règle.
        var config = Config()
        config.webhookBaseURL = "http://192.0.2.10:51828/"
        XCTAssertEqual(config.webhookTargets.map(\.url), ["http://192.0.2.10:51828/"])
        XCTAssertEqual(Config.degraded().webhookTargets, [], "mode dégradé : aucune cible")
    }

    func test_webhookTargets_lus() {
        let json = #"""
        {"enabled": true, "webhook_targets": [
          {"url": "http://192.0.2.10:51828/"},
          {"url": "http://192.0.2.20:8123/api/webhook/webhook-essai-abc123", "method": "post",
           "headers": {"X-Essai": "jeton-essai-0123456789abcdef"}},
          {"url": "https://ha.exemple.test/hook", "method": "GET", "headers": {}}
        ]}
        """#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertEqual(r.origin, .file)
        XCTAssertEqual(r.config.webhookTargets, [
            WebhookTarget(url: "http://192.0.2.10:51828/", method: "GET", headers: [:]),
            WebhookTarget(url: "http://192.0.2.20:8123/api/webhook/webhook-essai-abc123", method: "POST",
                          headers: ["X-Essai": "jeton-essai-0123456789abcdef"]),
            WebhookTarget(url: "https://ha.exemple.test/hook", method: "GET", headers: [:]),
        ])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
    }

    func test_webhookTargets_gagnentSurBaseURL_avecAvertissement() {
        let json = #"{"enabled": true, "webhook_base_url": "http://192.0.2.10:51828/", "#
            + #""webhook_targets": [{"url": "http://192.0.2.20:8123/api/webhook/webhook-essai-abc123", "method": "POST"}]}"#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertEqual(r.config.webhookTargets.map(\.url), ["http://192.0.2.20:8123/api/webhook/webhook-essai-abc123"])
        XCTAssertEqual(r.warnings.count, 1, "\(r.warnings)")
        XCTAssertTrue(r.warnings[0].hasPrefix("webhook_targets"), r.warnings[0])
        XCTAssertTrue(r.warnings[0].contains("webhook_base_url"), r.warnings[0])
    }

    func test_webhookTargets_cibleInvalide_ecarteeAvecAvertissementNomme() {
        let json = #"""
        {"enabled": true, "webhook_targets": [
          {"url": "http://192.0.2.10:51828/"},
          {"url": "http://u:secret@192.0.2.20 :8123/api/webhook/webhook-essai-abc123"},
          {"url": "http://192.0.2.21/api/webhook/webhook-essai-def456", "method": "PUT"},
          {"url": "ftp://192.0.2.22/hook"},
          {"method": "POST"},
          "http://192.0.2.23/hook",
          {"url": "http://192.0.2.24/hook", "headers": {"X-Cle": 12}},
          {"url": "http://192.0.2.25/hook", "headers": {"X-Cle": "jeton\r\nX-Autre: 1"}},
          {"url": "http://192.0.2.26/hook", "headers": {"Mauvais nom": "jeton-essai-0123456789abcdef"}},
          {"url": "http://192.0.2.27/hook", "headers": ["X-Cle"]},
          {"url": "http://192.0.2.28/hook", "methode": "POST"}
        ]}
        """#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertEqual(r.origin, .file, "une cible invalide ne met pas la config en mode dégradé")
        XCTAssertEqual(r.config.webhookTargets.map(\.url), ["http://192.0.2.10:51828/", "http://192.0.2.28/hook"])
        for numero in 2...10 {
            XCTAssertTrue(r.warnings.contains { $0.hasPrefix("webhook_targets : cible \(numero) ") && $0.contains("écartée") },
                          "cible \(numero) : \(r.warnings)")
        }
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("webhook_targets : cible 11 ") && $0.contains("methode") },
                      "clé inconnue nommée : \(r.warnings)")
        XCTAssertTrue(r.warnings.contains { $0.contains("PUT") })
        for texte in r.warnings {
            XCTAssertFalse(texte.contains("secret") || texte.contains("abc123") || texte.contains("def456")
                           || texte.contains("0123456789abcdef") || texte.contains("jeton"), "secret au journal : \(texte)")
        }
    }

    /// Lot 2, point 9 : une valeur d'en-tête est en ASCII visible, plus l'espace et la tabulation,
    /// 4096 octets au plus (et non 4096 caractères).
    func test_webhookTargets_valeurDEnTete_asciiVisibleEt4096Octets() throws {
        func resultat(_ valeur: String) throws -> Config.Loaded {
            let json = try JSONSerialization.data(withJSONObject: [
                "enabled": true,
                "webhook_targets": [["url": "http://192.0.2.10/hook", "headers": ["X-Cle": valeur]]],
            ] as [String: Any])
            return Config.parse(data: json)
        }
        for valide in ["jeton-essai-0123456789abcdef", "Bearer jeton avec espaces", "a\tb", "~!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}", String(repeating: "a", count: 4096)] {
            let r = try resultat(valide)
            XCTAssertEqual(r.config.webhookTargets.count, 1, "valeur acceptée attendue : \(valide.prefix(20)) \(r.warnings)")
            XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        }
        let invalides = [
            "jetón-essai",                                  // accent
            "jeton-\u{1F600}",                              // émoji
            "jeton\u{7F}",                                  // DEL
            "jeton\nautre",                                 // retour à la ligne
            "jeton\u{0}",                                   // NUL
            "jeton\u{80}",                                  // C1
            String(repeating: "a", count: 4097),            // trop long
            String(repeating: "é", count: 2049),            // 4098 octets, 2049 caractères
        ]
        for invalide in invalides {
            let r = try resultat(invalide)
            XCTAssertEqual(r.config.webhookTargets, [], "valeur refusée attendue : \(invalide.prefix(20))")
            XCTAssertTrue(r.warnings.contains { $0.hasPrefix("webhook_targets : cible 1 ") && $0.contains("écartée") }, "\(r.warnings)")
            XCTAssertFalse(r.warnings.contains { $0.contains("jeton") }, "valeur citée : \(r.warnings)")
        }
    }

    /// Lot 2, point 9 : deux en-têtes qui ne diffèrent que par la casse feraient un doublon à
    /// l'envoi : la cible est écartée, avec un avertissement qui ne cite aucune valeur.
    func test_webhookTargets_doublonDEnTeteALaCasseHPres_cibleEcartee() {
        let json = #"""
        {"enabled": true, "webhook_targets": [
          {"url": "http://192.0.2.10/hook"},
          {"url": "http://192.0.2.11/hook", "headers": {"X-Cle": "jeton-essai-0123456789abcdef", "x-cle": "jeton-essai-fedcba9876543210"}},
          {"url": "http://192.0.2.12/hook", "headers": {"X-Cle": "valeur-a", "X-Autre": "valeur-b"}}
        ]}
        """#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertEqual(r.origin, .file)
        XCTAssertEqual(r.config.webhookTargets.map(\.url), ["http://192.0.2.10/hook", "http://192.0.2.12/hook"])
        let avertissement = r.warnings.first { $0.hasPrefix("webhook_targets : cible 2 ") }
        XCTAssertNotNil(avertissement, "\(r.warnings)")
        XCTAssertTrue(avertissement?.contains("écartée") ?? false)
        XCTAssertTrue(avertissement?.contains("doublon") ?? false, avertissement ?? "")
        for texte in r.warnings {
            XCTAssertFalse(texte.contains("0123456789abcdef") || texte.contains("fedcba9876543210"), "secret au journal : \(texte)")
        }
    }

    func test_webhookTargets_typeInattendu_ouListeVide() {
        let r = Config.parse(data: Data(#"{"enabled": true, "webhook_targets": "http://192.0.2.10/hook", "webhook_base_url": "http://192.0.2.10:51828/"}"#.utf8))
        XCTAssertEqual(r.config.webhookTargets, [], "webhook_targets présent : il décide, même illisible")
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("webhook_targets : type inattendu") }, "\(r.warnings)")
        XCTAssertTrue(r.warnings.contains { $0.contains("aucune cible") }, "\(r.warnings)")
        let vide = Config.parse(data: Data(#"{"enabled": true, "webhook_targets": []}"#.utf8))
        XCTAssertEqual(vide.config.webhookTargets, [])
        XCTAssertTrue(vide.warnings.contains { $0.contains("aucune cible") }, "\(vide.warnings)")
        let trop = (1...10).map { #"{"url": "http://192.0.2.\#($0)/hook"}"# }.joined(separator: ",")
        let plafond = Config.parse(data: Data(#"{"webhook_targets": [\#(trop)]}"#.utf8))
        XCTAssertEqual(plafond.config.webhookTargets.count, Config.maxWebhookTargets)
        XCTAssertTrue(plafond.warnings.contains { $0.hasPrefix("webhook_targets") && $0.contains("\(Config.maxWebhookTargets)") })
    }
}
