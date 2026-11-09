# Rapport de la correction 1 de la tâche 9

Statut : fait. Le commit porte les README, DocumentationTests et ce rapport.

1. Installation depuis l'archive : le code (Config.swift) donne, sans config, des défauts et une écoute limitée à 127.0.0.1 ;
   sans auth_token, aucune autre machine n'est servie. Aucune option ni création à la volée n'existe : les deux README
   donnent donc un bloc de commandes (dossier, fichier vide, chmod 600, config minimale avec jeton de `openssl rand -hex 32`,
   sans jamais l'afficher ; ne fait rien si le fichier existe) et disent de lire le jeton dans un éditeur.
   Preuve (HOME d'essai /private/tmp/macstatusd-plan4/fix1-home-20248) : droits 600, auth_token de 64 caractères hexadécimaux, JSON valide.
2. `--preparer-jeton` : lecture de /opt/macstatusd/config.json par défaut, dite dans les deux README.
3. DocumentationTests : liste explicite des champs optionnels (shutting_down, last_transition, pending_command, target, source,
   age_seconds, escalated), vérifiés dans les deux README (déjà décrits, lignes 540-542 et 556-558).

Tests : 568 tests, 0 échec. install.sh non lancé (bloc vérifié seul, HOME d'essai).
Réserve : le bloc n'a pas été essayé avec le démon lui-même, seulement vérifié (droits, JSON, longueur).
