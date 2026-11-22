# Phase 6 : correctif 0.6.1, réveil gardé jusqu'au déverrouillage

**Objectif :** qu'un réveil commandé par HA, suivi d'un déverrouillage rapide, ne reverrouille plus la session.

**Conception :** `docs/superpowers/specs/2026-10-25-correctifs-audit-design.md`, §12 (C15 révisée, C27).

**Voie courte :** conception validée en conversation, prototype dans une copie de travail, relecture, banc avec Djoko,
report sur `main` en quelques commits, relecture finale. Cette liste ne sert qu'au suivi des étapes.

### Tâche 1 : conception

- [x] §12 validé par Djoko (16/11/2026, en conversation)

### Tâche 2 : prototype

- [x] Tests d'abord, dans `.superpowers/wt-061` (branche `reveil-garde-0.6.1`)
- [x] Code de C15 révisée et de C27, suite complète verte
- [x] Prototype relu (relecture, puis corrections de ses constats ; 607 tests verts)

### Tâche 3 : banc avec Djoko

- [x] Témoin sous la 0.6.0, ajouté au banc : reverrouillage reproduit, écran éteint par sa minuterie (§12, 22/11/2026)
- [x] Essai 1 : économiseur, déverrouillage aussitôt, aucun reverrouillage
- [x] Essai 2 : simple extinction de l'écran, déverrouillage aussitôt, aucun reverrouillage
- [x] Essai 3 : économiseur, sans déverrouillage, relâchement au plafond et écran éteint

### Tâche 4 : report sur `main`

- [x] Commits clairs sur `main` : un commit regroupé, `53c66db` ; suite complète verte, 607 tests et 30 suites
  (22/11/2026)
- [x] Relecture finale de la branche : aucun constat critique ni important ; deux mineurs reportés, dont la liste des
  preuves du README, à compléter en tâche 5

### Tâche 5 : version 0.6.1

- [x] Ancien numéro cherché dans tout le dépôt, chaque occurrence classée, numéro monté (`e38e98a` ; montés :
  `Version.swift`, exemple de `--version`, test des notes ; le reste est historique ou valeur d'essai)
- [x] Notes de version en anglais puis en français ; README anglais et français (`e38e98a` : réveil tenu,
  `wake_hold_seconds`, `écarté-par-réveil`)
- [x] Deux mineurs d'outillage : garde copiée dans le dossier git commun (`62dc258`, réinstallée dans le dépôt,
  essayée depuis le commit racine) ; cas `sortie-par-defaut` du banc de l'assembleur (`d185f90`)
- [x] Tests du clone de publication (clone `e38e98a`, 23/11/2026) : 608 tests et 30 suites, quatre bancs (garde
  37 cas), 78 tests Python, selftest écran éteint forcé 88 OK
- [ ] Selftest écran allumé dans le clone : au passage du 23/11, l'écran était éteint, et ses 4 sections ont sauté

### Tâche 6 : publication

- [ ] Signature et notarisation, session ouverte
- [ ] Page de version, vérifiée en ligne

### Tâche 7 : déploiement

- [ ] `install.sh` lancé par Djoko
- [ ] Au journal : un réveil par HA suivi d'un déverrouillage, sans reverrouillage
