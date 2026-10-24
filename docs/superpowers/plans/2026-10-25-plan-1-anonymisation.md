# Plan 1 — Anonymisation du dépôt (lot 0)

> **Pour les agents qui exécutent :** sous-compétence requise, `superpowers:subagent-driven-development`
> (recommandée) ou `superpowers:executing-plans`, tâche par tâche. Les étapes se cochent (`- [ ]`).

**But :** le dépôt public `Djoko-cli/macstatusd` ne contient plus aucun identifiant réel, historique compris,
et une garde `pre-push` empêche d'en publier un nouveau.

**Architecture :** une garde `pre-push` versionnée, testée par des violations plantées là où seule elle peut
les voir ; un script local (jamais commité) qui rejoue les deux commits publiés sur une nouvelle racine en
appliquant une liste fermée de remplacements ; puis la recréation du dépôt GitHub sous le même nom.

**Outils :** bash (les scripts portent `#!/bin/bash` et s'appellent par `bash`), git, `gh`.

**Spec :** `docs/superpowers/specs/2026-10-25-correctifs-audit-design.md` (lot 0, décisions D4, D7, D8, C21).

## Contraintes globales

- Identité git du dépôt : `Djoko-cli <12185352+Djoko-cli@users.noreply.github.com>`, auteur ET committer.
- Aucun identifiant réel dans un fichier commité, un message de commit ou une sortie recopiée dans un
  fichier : prénom et nom réels, e-mail personnel, IP réelles, noms d'hôte, chemins `/Users/<nom>`. Dans
  le dépôt, la personne s'appelle Djoko.
- IP d'exemple : plages de documentation seulement (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`).
- Les valeurs réelles connues vivent dans `garde.local.txt` (racine du dépôt, ignoré par git) et dans
  `.superpowers/` (ignoré). Les tests utilisent des valeurs inventées (`Prenom-Essai`, et une adresse,
  une IP et un chemin assemblés à l'exécution).
- Toute commande du plan tourne telle quelle sous zsh, le shell de Djoko : pas de variable non citée
  dont le sens dépendrait du découpage des mots ; les scripts se lancent par `bash <script>`.
- `--no-verify` interdit. La suppression du dépôt GitHub ne se fait que sur le « go » explicite de Djoko.

## Points de vigilance

1. **Une fuite ajoutée puis retirée dans la même poussée** : la garde doit refuser, puisque le commit
   intermédiaire est publié. Test : plant dans le commit 1, retrait dans le commit 2, poussée des deux.
2. **Une fuite présente seulement dans l'arbre de travail, non commitée** : la garde doit accepter,
   puisqu'elle inspecte ce qui est poussé, pas le disque. Test témoin.
3. **Une fuite dans un message de commit, ou dans un fichier binaire** : refusée. Tests dédiés.
4. **Un ancien libellé ou une ancienne version qui survit à la réécriture** dans un fichier oublié par
   la liste de remplacements : la vérification de la tâche 2 compare chaque arbre réécrit à l'arbre
   d'origine transformé, et cherche les motifs dans tout l'historique.
5. **Une suppression de dépôt faite trop tôt** (avant que la nouvelle racine soit vérifiée) : la tâche 3
   commence par une vérification complète, et attend le « go » de Djoko.

---

### Tâche 1 : garde `pre-push`

**Fichiers :**
- Créer : `outils/pre-push`, `outils/installer-garde.sh`, `outils/tests/test-garde.sh`
- Modifier : `.gitignore` (ajouter `garde.local.txt`)
- Créer, hors git : `garde.local.txt` (valeurs réelles, une par ligne)

**Interfaces :**
- Produit : `outils/pre-push`, appelé par git avec `<distant> <url>` et, sur l'entrée standard, des lignes
  `<ref locale> <sha local> <ref distante> <sha distant>`. Code 0 si tout est propre, 1 sinon, avec un
  message par problème sur la sortie d'erreur. Le message nomme le commit et le **genre** du motif
  (`liste locale`, `IPv4 privée`, `chemin personnel`, `e-mail`), jamais sa valeur.
- Produit : `outils/installer-garde.sh` règle `core.hooksPath` sur `outils/` et vérifie que
  `garde.local.txt` existe ; il échoue avec un message clair sinon.
- Variable d'environnement pour les tests : `GARDE_LISTE=<chemin>` remplace `garde.local.txt`.

Pour chaque commit à publier (plage `distant..local`, ou `local --not --remotes` pour une branche
nouvelle), la garde contrôle :
- l'auteur et le committer : adresse noreply attendue ;
- le diff du commit (`git show --format= --unified=0 --text`, lignes ajoutées seulement) et le message
  du commit, contre :
  - chaque ligne de la liste locale (chaîne fixe, sans casse, ignorée si vide ou commentée par `#`) ;
  - les IPv4 privées hors des trois plages de documentation : `10.`, `172.16–31.`, `192.168.` ;
  - le motif `/Users/[A-Za-z]` ;
  - toute adresse e-mail qui n'est pas en `users.noreply.github.com` ou `noreply@anthropic.com`.

- [x] **Étape 1 : écrire `outils/tests/test-garde.sh`**

  Le script crée un dépôt nu « distant » et un clone dans un dossier temporaire (`mktemp -d`), installe
  la garde dans le clone avec une liste d'essai contenant `Prenom-Essai`, puis enchaîne les cas
  ci-dessous. Chaque cas affiche `OK`/`ÉCHEC` et le script se termine en code 1 si un cas échoue.

  | Cas | Mise en place | Attendu |
  |---|---|---|
  | `propre` | un commit propre | poussée acceptée |
  | `liste-ajout-retrait` | commit 1 ajoute `Prenom-Essai` dans `a.txt`, commit 2 le retire, poussée des deux | refusée |
  | `liste-message` | le message du commit contient `Prenom-Essai`, le contenu est propre | refusée |
  | `liste-binaire` | `b.bin` contient `Prenom-Essai` au milieu d'octets nuls | refusée |
  | `arbre-seul` (témoin) | `Prenom-Essai` dans un fichier non commité, commit propre | acceptée |
  | `ip-privee` | une IPv4 de la plage privée « 192.168 », construite à l'exécution, ajoutée | refusée |
  | `ip-doc` (témoin) | `192.0.2.10` ajouté | acceptée |
  | `chemin` | un chemin « /Users/ » suivi d'un nom, construit à l'exécution, ajouté | refusée |
  | `email` | une adresse `@example.com`, construite à l'exécution, ajoutée | refusée |
  | `auteur` | commit dont l'e-mail d'auteur est cette adresse d'essai | refusée |
  | `committer` | commit dont l'e-mail de committer est cette adresse d'essai | refusée |
  | `autre-branche` | violation sur la branche `essai`, poussée de `essai` seule | refusée |
  | `message-sans-valeur` | dans un cas refusé, la sortie d'erreur ne contient pas `Prenom-Essai` | vrai |

  **Les valeurs plantées ne figurent jamais en clair dans le script de test** : il les assemble à
  l'exécution à partir de morceaux (par exemple `"192.""168.$((3+4)).9"`), sans quoi la garde refuserait
  de publier le script lui-même. Le cas `propre-script` le vérifie : la garde, appliquée au commit qui
  ajoute `outils/`, accepte.

- [x] **Étape 2 : lancer `bash outils/tests/test-garde.sh`** — attendu : échec (la garde n'existe pas).
- [x] **Étape 3 : écrire `outils/pre-push` et `outils/installer-garde.sh`** selon l'interface ci-dessus.
- [x] **Étape 4 : relancer `bash outils/tests/test-garde.sh`** — attendu : 14 cas `OK`, code 0.
- [x] **Étape 5 : écrire `garde.local.txt`** à la racine (valeurs réelles : prénom, nom, e-mail personnel,
  IP réelles connues du LAN, noms d'hôte réels), droits 600, sans afficher son contenu. Ajouter
  `garde.local.txt` au `.gitignore`. Lancer `bash outils/installer-garde.sh` — attendu :
  `core.hooksPath = outils`.
- [x] **Étape 6 : vérifier que la garde refuse l'historique actuel**, qui contient de vraies fuites :
  `printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" 0000000000000000000000000000000000000000 | bash outils/pre-push origin x`
  — attendu : code 1, des messages sur les deux commits publiés, aucune valeur affichée.
- [x] **Étape 7 : commit** — les fichiers `outils/` et `.gitignore` sont prêts, mais **on ne commite rien
  ici** : la tâche 2 réécrit l'historique, et ce travail sera commité par-dessus la nouvelle racine
  (tâche 2, étape 6).

### Tâche 2 : réécriture de l'historique

**Fichiers :**
- Créer, hors git : `.superpowers/ops/reecrire-historique.sh` (contient l'ancien libellé et l'IP réelle,
  donc jamais commité), `.superpowers/historique-origine.bundle`

**Interfaces :**
- Consomme : `outils/pre-push` (tâche 1).
- Produit : la branche `main` locale, réécrite. Ses deux premiers commits correspondent aux deux commits
  publiés (même ordre, mêmes dates d'auteur et de committer, identité noreply), puis viennent les commits
  du chantier.

Remplacements, liste fermée, appliqués aux arbres et aux messages :

| Avant | Après | Où |
|---|---|---|
| `com.<ancien>.macstatusd` (libellé réel) | `com.djoko.macstatusd` | tous les fichiers, et le nom du plist `launchd/` |
| l'IP réelle du Homebridge | `192.0.2.10` | `config.example.json`, `README*.md` |
| `5.0.0` | `0.5.0` | `Sources/macstatusd/Version.swift`, messages de commit |
| `macstatusd 5.0` (titre) | `macstatusd 0.5` | `README*.md` |
| « La version 5 » / « Version 5 » | « La 0.5 » / « Version 0.5 » | `README*.md` |
| « La version 4 déduisait » / « Version 4 inferred » | « Les prototypes 4.x déduisaient » / « The 4.x prototypes inferred » | `README*.md` |

- [x] **Étape 1 : sauvegarder** l'état actuel : `git bundle create .superpowers/historique-origine.bundle --all`,
  puis copier hors du dépôt les fichiers non commités (spec, plans, `outils/`, `.gitignore`) dans
  `.superpowers/en-cours/`.
- [x] **Étape 2 : écrire `.superpowers/ops/reecrire-historique.sh`.** Pour chaque commit d'origine, dans
  l'ordre :
  - extraire son arbre dans un dossier temporaire ;
  - appliquer les remplacements (`sed` sur les fichiers texte, `git mv` du plist) ;
  - committer sur la branche orpheline `reecrit`, avec `GIT_AUTHOR_DATE` et `GIT_COMMITTER_DATE`
    d'origine, l'identité noreply et le message transformé.
- [x] **Étape 3 : lancer le script** (`bash .superpowers/ops/reecrire-historique.sh`), puis vérifier :
  - `git log --format='%an <%ae> | %cn <%ce>' reecrit` → deux lignes, toutes en noreply ;
  - pour chaque paire, l'arbre réécrit est identique à l'arbre d'origine transformé (le script le refait
    dans un dossier témoin et compare par `diff -r`) — attendu : aucune différence ;
  - `git grep -I -n -i -f garde.local.txt reecrit` → aucune ligne ; `git log --format=%B reecrit | grep -i -f garde.local.txt` → aucune ligne ;
  - `git grep -n 5.0.0 reecrit` → aucune ligne.
- [x] **Étape 4 : basculer `main`** sur la nouvelle racine : `git branch -f main reecrit`, `git checkout main`,
  puis supprimer `reecrit`.
- [x] **Étape 5 : remettre le travail en cours** (fait autrement : les commits du chantier sont rejoués par cherry-pick) depuis `.superpowers/en-cours/`, et vérifier que
  `git status` liste exactement la spec, les plans, `outils/` et `.gitignore`.
- [x] **Étape 6 : commiter** (fait par le même cherry-pick) en deux commits : `outils/` et `.gitignore` (« Garde pre-push : identité
  noreply et valeurs réelles »), puis la spec et les plans (« Conception et plans des correctifs de
  l'audit »). Chaque message se termine par la ligne d'attribution du projet.
- [x] **Étape 7 : vérifier la garde sur tout le nouvel historique :**
  `printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" 0000000000000000000000000000000000000000 | bash outils/pre-push origin x`
  — attendu : code 0.

### Tâche 3 : recréation du dépôt GitHub (avec Djoko)

**Fichiers :** aucun.

**Interfaces :**
- Consomme : `main` réécrite et vérifiée (tâche 2).

- [ ] **Étape 1 : revérifier** (tâche 2, étape 7) et rapporter à Djoko : nombre de commits, identité,
  résultat de la garde.
- [ ] **Étape 2 (Djoko) : supprimer l'ancien dépôt**, sur github.com (Settings > Danger Zone), ou par
  `gh auth refresh -h github.com -s delete_repo` puis `gh repo delete Djoko-cli/macstatusd`.
  Uniquement sur son « go ».
- [ ] **Étape 3 : recréer** `Djoko-cli/macstatusd`, public, avec la description anglaise retenue, puis
  `git push -u origin main`. La garde tourne à la poussée — attendu : acceptée.
- [ ] **Étape 4 : vérifier en ligne :** `gh repo view Djoko-cli/macstatusd --json visibility,licenseInfo,description`
  → `PUBLIC`, `MIT License`, la description ; `gh api repos/Djoko-cli/macstatusd/commits --jq '.[].commit.author.email' | sort -u`
  → la seule adresse noreply.
