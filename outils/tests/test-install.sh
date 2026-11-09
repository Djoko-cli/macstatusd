#!/bin/bash
# Banc d'essai de scripts/install.sh et scripts/uninstall.sh.
#
# Usage : bash outils/tests/test-install.sh
#
# Hermétique : le banc fixe HOME sur un dossier d'essai sous /private/tmp/macstatusd-plan4/test-install
# avant toute autre commande, met de faux outils (outils/tests/faux : launchctl, sudo, curl, open,
# osascript, swift) en tête du PATH et refuse de démarrer si HOME vaut le vrai dossier de l'utilisateur.
# « À la Corbeille » veut dire « déplacé dans $HOME/.Trash », donc dans le HOME d'essai.
# Aucun appel à SMAppService, au vrai launchd, à /opt, à sudo ni au réseau.
# Code de sortie : 0 si tous les cas passent, 1 sinon.

set -u

# --- Sûreté : HOME d'essai fixé avant tout ----------------------------------------
racine="/private/tmp/macstatusd-plan4/test-install"
export HOME="$racine/home"
case "$HOME" in
  /private/tmp/macstatusd-plan4/test-install/*) ;;
  *) echo "ÉCHEC sûreté : HOME d'essai inattendu" >&2; exit 1 ;;
esac
vrai_home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
if [[ -z "$vrai_home" || "$HOME" == "$vrai_home" ]]; then
  echo "ÉCHEC sûreté : le vrai dossier personnel n'a pas pu être distingué du HOME d'essai" >&2
  exit 1
fi
mkdir -p "$HOME" || exit 1

ici=$(cd "$(dirname "$0")" && pwd)
depot=$(cd "$ici/../.." && pwd)
faux="$ici/faux"
pb=/usr/libexec/PlistBuddy
chemin_initial="$PATH"

echec=0
ok() { echo "OK    $1"; }
ko() { echo "ÉCHEC $1 : $2"; echec=1; }
verifier() { # cas description attendu réel
  if [[ "$3" == "$4" ]]; then ok "$1 : $2"; else ko "$1" "$2 (attendu « $3 », obtenu « $4 »)"; fi
}

# État du vrai dossier personnel, relevé avant et après (les scripts ne doivent rien y toucher).
# Nombres seulement (jamais de noms : le libellé réel de l'ancien agent contient un prénom).
etat_reel() {
  local d
  for d in "$vrai_home/Applications" "$vrai_home/Library/LaunchAgents"; do
    echo "$(ls -A "$d" 2>/dev/null | wc -l | tr -d ' ') fichiers, empreinte $(ls -la "$d" 2>&1 | cksum | cut -d' ' -f1)"
  done
}
avant=$(etat_reel)

# --- Préparation d'un cas -------------------------------------------------------------
nouveau_cas() { # nom
  cas="$1"
  base="$racine/cas-$cas"
  case "$base" in
    /private/tmp/macstatusd-plan4/test-install/cas-?*) ;;
    *) echo "ÉCHEC sûreté : dossier de cas inattendu" >&2; exit 1 ;;
  esac
  rm -rf "$base"
  mkdir -p "$base/journal" "$base/home/Library/LaunchAgents" "$base/src"
  export HOME="$base/home"
  export FAUX_JOURNAL="$base/journal"
  export PATH="$faux:$chemin_initial"
  export MACSTATUSD_VERIF_PAUSE=0
  unset FAUX_LAUNCHCTL_PRINT FAUX_LAUNCHCTL_KICKSTART_CODE FAUX_LAUNCHCTL_BOOTSTRAP_CODE FAUX_CURL_CODE FAUX_APP_CODE FAUX_APP_UNREGISTER_CODE MACSTATUSD_EUID
  support="$HOME/Library/Application Support/macstatusd-essai"
  config="$support/config.json"
  installee="$HOME/Applications/macstatusd-essai.app"
  libelle="com.exemple.ancien-agent"
}

# App d'essai : Info.plist avec l'identité, faux binaire, un marqueur pour reconnaître la copie.
creer_app() { # marqueur [identifiant] [nom de support]
  local marqueur="$1" id="${2:-com.djoko.macstatusd.essai}" sup="${3:-macstatusd-essai}"
  app="$base/src/macstatusd-essai.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$faux/macstatusd-app" "$app/Contents/MacOS/macstatusd"
  printf '%s\n' "$marqueur" > "$app/Contents/Resources/marqueur"
  "$pb" -c "Add :CFBundleIdentifier string $id" -c "Add :MacstatusdSupportName string $sup" \
    "$app/Contents/Info.plist" > /dev/null
}

ecrire_plist() { # fichier libellé programme
  rm -f "$1"
  "$pb" -c "Add :Label string $2" -c "Add :ProgramArguments array" -c "Add :ProgramArguments:0 string $3" \
    -c "Add :ProgramArguments:1 string --config" "$1" > /dev/null
}

# Ancien préfixe (config sans jeton, avec webhook_base_url), son agent, un leurre, d'anciens journaux.
creer_ancien() {
  prefixe="$base/opt/macstatusd"
  mkdir -p "$prefixe" "$HOME/Library/Logs/macstatusd"
  printf 'binaire\n' > "$prefixe/macstatusd"
  cat > "$prefixe/config.json" <<'JSON'
{
  "enabled": true,
  "webhook_base_url": "http://192.0.2.10:51828",
  "accessory_id": "mac",
  "port": 9191,
  "bind_address": "",
  "log_file": "/private/tmp/macstatusd-plan4/ancien/macstatusd.log",
  "auth_token": ""
}
JSON
  ecrire_plist "$HOME/Library/LaunchAgents/$libelle.plist" "$libelle" "$prefixe/macstatusd"
  ecrire_plist "$HOME/Library/LaunchAgents/$libelle-voisin.plist" "$libelle-voisin" "/home/exemple/autre/macstatusd"
  printf 'ligne ancienne\n' > "$HOME/Library/Logs/macstatusd/macstatusd.log"
}

# Déclare un job chargé pour le faux launchctl : libellé et, au choix, le programme qu'il lance.
charger() { # libellé [programme]
  echo "$1 ${2:-}" >> "$FAUX_JOURNAL/charges"
}
# Rang de la première / dernière ligne de ordre.log qui correspond à une expression (0 si absente).
rang_premier() { /usr/bin/grep -n -E "$1" "$FAUX_JOURNAL/ordre.log" 2>/dev/null | head -n 1 | cut -d: -f1 | /usr/bin/grep -E '^[0-9]+$' || echo 0; }
rang_dernier() { /usr/bin/grep -n -E "$1" "$FAUX_JOURNAL/ordre.log" 2>/dev/null | tail -n 1 | cut -d: -f1 | /usr/bin/grep -E '^[0-9]+$' || echo 0; }

lancer_install() { # arguments d'install.sh
  bash "$depot/scripts/install.sh" "$@" > "$base/sortie.txt" 2>&1
  code=$?
}
lancer_desinstall() { # arguments d'uninstall.sh
  bash "$depot/scripts/uninstall.sh" "$@" > "$base/sortie-desinstall.txt" 2>&1
  code=$?
}

# Valeur d'une expression Python sur la config JSON (lecture seule).
valeur() { # fichier expression
  python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))' "$1" "$2" 2>&1
}
nb_lignes() { # fichier -> nombre de lignes (0 si absent)
  if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}
nb_motif() { # motif fichier -> nombre de lignes qui le contiennent (0 si absent)
  if [[ -f "$2" ]]; then /usr/bin/grep -c -F -- "$1" "$2" || true; else echo 0; fi
}

# jeton-cache : le jeton ne doit apparaître dans aucune sortie ni aucun journal de faux outil.
# Le nombre d'occurrences est compté (grep -c -F), la valeur n'est jamais imprimée.
verifier_jeton_cache() { # configuration à lire
  local cfg="${1:-$config}" f total=0 n
  [[ -f "$cfg" ]] || return 0
  python3 -c 'import json,sys;sys.stdout.write(json.load(open(sys.argv[1])).get("auth_token") or "")' "$cfg" \
    > "$base/jeton.txt" 2>/dev/null
  [[ -s "$base/jeton.txt" ]] || return 0
  for f in "$base"/sortie*.txt "$base/journal"/*.log; do
    [[ -f "$f" ]] || continue
    n=$(/usr/bin/grep -c -F -f "$base/jeton.txt" "$f" || true)
    total=$((total + n))
  done
  verifier "$cas" "jeton-cache : occurrences du jeton dans les sorties et journaux" 0 "$total"
}

en_poubelle() { # nom -> présent dans la Corbeille d'essai (nom exact ou suffixé)
  local n
  n=$(ls -A "$HOME/.Trash" 2>/dev/null | /usr/bin/grep -c -F -- "$1" || true)
  echo "$n"
}

# =========================== Cas ===========================================================

# --- installation-neuve -----------------------------------------------------------------
nouveau_cas installation-neuve
creer_app v1
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "droits de la config" 600 "$(stat -f %Lp "$config" 2>/dev/null)"
jeton=$(valeur "$config" 'c["auth_token"]')
if [[ "$jeton" =~ ^[0-9a-f]{64}$ ]]; then ok "$cas : jeton de 64 caractères hexadécimaux"; else ko "$cas" "jeton absent ou mal formé"; fi
verifier "$cas" "enabled de l'exemple" False "$(valeur "$config" 'c["enabled"]')"
verifier "$cas" "webhook_targets de l'exemple" "[]" "$(valeur "$config" 'c["webhook_targets"]')"
verifier "$cas" "webhook_base_url absent" False "$(valeur "$config" '"webhook_base_url" in c')"
verifier "$cas" "un seul --register" 1 "$(nb_motif "--register" "$FAUX_JOURNAL/app.log")"
verifier "$cas" "aucun appel à sudo" 0 "$(nb_lignes "$FAUX_JOURNAL/sudo.log")"
[[ -x "$installee/Contents/MacOS/macstatusd" ]] && ok "$cas : app installée dans ~/Applications" || ko "$cas" "app absente de ~/Applications"
verifier "$cas" "pas de marqueur de redémarrage (agent non chargé)" absent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"
verifier "$cas" "aucun kickstart (agent non chargé)" 0 "$(nb_motif kickstart "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "vérification de /health sur 127.0.0.1:9090" 1 "$(nb_motif "http://127.0.0.1:9090/health" "$FAUX_JOURNAL/curl.log")"
verifier "$cas" "aucune trace Python" 0 "$(nb_motif Traceback "$base/sortie.txt")"
verifier "$cas" "I2 : rappel d'éditer la config et de relancer l'agent" 1 "$(nb_motif "launchctl kickstart -k gui/$(id -u)/com.djoko.macstatusd.essai" "$base/sortie.txt")"
verifier_jeton_cache

# --- migration --------------------------------------------------------------------------
nouveau_cas migration
creer_app v1
creer_ancien
cp "$prefixe/config.json" "$base/config-ancienne.copie"
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "webhook_targets repris" "[{'url': 'http://192.0.2.10:51828', 'method': 'GET'}]" "$(valeur "$config" 'c["webhook_targets"]')"
verifier "$cas" "webhook_base_url retiré" False "$(valeur "$config" '"webhook_base_url" in c')"
verifier "$cas" "port copié" 9191 "$(valeur "$config" 'c["port"]')"
verifier "$cas" "enabled copié" True "$(valeur "$config" 'c["enabled"]')"
jeton=$(valeur "$config" 'c["auth_token"]')
if [[ "$jeton" =~ ^[0-9a-f]{64}$ ]]; then ok "$cas : jeton généré"; else ko "$cas" "jeton absent ou mal formé"; fi
verifier "$cas" "droits de la config" 600 "$(stat -f %Lp "$config" 2>/dev/null)"
verifier "$cas" "bootout avec le bon libellé" 1 "$(nb_motif "bootout gui/$(id -u)/$libelle" "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "plist de l'ancien agent retiré de LaunchAgents" absent "$([[ -e "$HOME/Library/LaunchAgents/$libelle.plist" ]] && echo présent || echo absent)"
verifier "$cas" "plist à la Corbeille" 1 "$(en_poubelle "$libelle.plist")"
verifier "$cas" "leurre laissé en place" présent "$([[ -e "$HOME/Library/LaunchAgents/$libelle-voisin.plist" ]] && echo présent || echo absent)"
verifier "$cas" "ancien journal retiré" absent "$([[ -e "$HOME/Library/Logs/macstatusd/macstatusd.log" ]] && echo présent || echo absent)"
verifier "$cas" "ancien journal à la Corbeille" 1 "$(en_poubelle "macstatusd.log")"
verifier "$cas" "commande sudo rm -rf affichée" 1 "$(nb_motif "sudo rm -rf \"$prefixe\"" "$base/sortie.txt")"
verifier "$cas" "sudo jamais lancé" 0 "$(nb_lignes "$FAUX_JOURNAL/sudo.log")"
verifier "$cas" "ancien préfixe intact (config)" 0 "$(cmp -s "$prefixe/config.json" "$base/config-ancienne.copie"; echo $?)"
verifier "$cas" "libellé de $(( ${#libelle} )) caractères annoncé" 1 "$(nb_motif "ancien agent retiré (libellé de ${#libelle} caractères)" "$base/sortie.txt")"
verifier "$cas" "libellé jamais affiché" 0 "$(nb_motif "$libelle" "$base/sortie.txt")"
verifier "$cas" "vérification sur le port migré" 1 "$(nb_motif "http://127.0.0.1:9191/health" "$FAUX_JOURNAL/curl.log")"
verifier "$cas" "E1 : log_file de l'ancienne config non repris" False "$(valeur "$config" '"log_file" in c')"
verifier "$cas" "E1 : message final avec le journal par défaut" 1 "$(nb_motif "Journal : $HOME/Library/Logs/macstatusd-essai/macstatusd.log" "$base/sortie.txt")"
verifier "$cas" "M2 : marqueur restart-pending posé après le retrait" présent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"
verifier "$cas" "M2 : un kickstart de l'agent 0.6" 1 "$(nb_motif "kickstart -k gui/$(id -u)/com.djoko.macstatusd.essai" "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "M2 : le kickstart suit le dernier bootout" oui "$([[ $(rang_dernier '^launchctl kickstart') -gt $(rang_dernier '^launchctl bootout') && $(rang_dernier '^launchctl bootout') -gt 0 ]] && echo oui || echo non)"
verifier "$cas" "pas de rappel de config (config migrée)" 0 "$(nb_motif "La configuration vient d'être créée" "$base/sortie.txt")"
verifier_jeton_cache

# --- leurre -----------------------------------------------------------------------------
nouveau_cas leurre
creer_app v1
creer_ancien
rm -f "$HOME/Library/LaunchAgents/$libelle.plist"   # seul le plist au programme différent reste
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "leurre laissé en place" présent "$([[ -e "$HOME/Library/LaunchAgents/$libelle-voisin.plist" ]] && echo présent || echo absent)"
verifier "$cas" "aucun bootout" 0 "$(nb_motif bootout "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "anciens journaux laissés" présent "$([[ -e "$HOME/Library/Logs/macstatusd/macstatusd.log" ]] && echo présent || echo absent)"
verifier_jeton_cache

# --- relance ----------------------------------------------------------------------------
nouveau_cas relance
creer_app v1
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "première installation, code" 0 "$code"
empreinte1=$(python3 -c 'import hashlib,json,sys;print(hashlib.sha256(json.load(open(sys.argv[1]))["auth_token"].encode()).hexdigest())' "$config")
creer_app v2
export FAUX_LAUNCHCTL_PRINT=0
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "seconde installation, code" 0 "$code"
empreinte2=$(python3 -c 'import hashlib,json,sys;print(hashlib.sha256(json.load(open(sys.argv[1]))["auth_token"].encode()).hexdigest())' "$config")
verifier "$cas" "empreinte du jeton inchangée" "$empreinte1" "$empreinte2"
verifier "$cas" "marqueur restart-pending posé" présent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"
verifier "$cas" "agent de l'identité interrogé à chaque passage" 2 "$(nb_motif "print gui/$(id -u)/com.djoko.macstatusd.essai" "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "app remplacée" v2 "$(cat "$installee/Contents/Resources/marqueur" 2>/dev/null)"
verifier "$cas" "ancienne app à la Corbeille" 1 "$(en_poubelle "macstatusd-essai.app")"
verifier "$cas" "un --register par passage" 2 "$(nb_motif "--register" "$FAUX_JOURNAL/app.log")"
verifier "$cas" "un seul kickstart -k de l'agent (mise à jour)" 1 "$(nb_motif "kickstart -k gui/$(id -u)/com.djoko.macstatusd.essai" "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "le kickstart suit le dernier --register" kickstart "$(/usr/bin/grep -n -E '^app --register|^launchctl kickstart' "$FAUX_JOURNAL/ordre.log" | tail -n 1 | sed -E 's/^[0-9]+:(app|launchctl) (--register|kickstart).*/\2/')"
verifier "$cas" "droits de la config" 600 "$(stat -f %Lp "$config" 2>/dev/null)"
verifier_jeton_cache

# --- anciens-journaux-ailleurs ----------------------------------------------------------
# --anciens-journaux désigne le dossier vidé ; le dossier de la vraie instance reste intact.
nouveau_cas anciens-journaux-ailleurs
creer_app v1
creer_ancien
mkdir -p "$HOME/Library/Logs/macstatusd-repetition-ancien"
printf 'ligne de la repetition\n' > "$HOME/Library/Logs/macstatusd-repetition-ancien/macstatusd.log"
printf 'temoin\n' > "$HOME/Library/Logs/macstatusd/temoin.log"
rm -f "$HOME/Library/Logs/macstatusd/macstatusd.log"
lancer_install --app "$app" --ancien-prefixe "$prefixe" --anciens-journaux "$HOME/Library/Logs/macstatusd-repetition-ancien"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "journal témoin de la vraie instance laissé" présent "$([[ -e "$HOME/Library/Logs/macstatusd/temoin.log" ]] && echo présent || echo absent)"
verifier "$cas" "journal du dossier désigné retiré" absent "$([[ -e "$HOME/Library/Logs/macstatusd-repetition-ancien/macstatusd.log" ]] && echo présent || echo absent)"
verifier "$cas" "journal du dossier désigné à la Corbeille" 1 "$(en_poubelle "macstatusd.log")"
verifier_jeton_cache

# --- anciens-journaux-hors-logs ---------------------------------------------------------
nouveau_cas anciens-journaux-hors-logs
creer_app v1
creer_ancien
mkdir -p "$HOME/Documents"
printf 'important\n' > "$HOME/Documents/important.txt"
lancer_install --app "$app" --ancien-prefixe "$prefixe" --anciens-journaux "$HOME/Documents"
verifier "$cas" "dossier hors Logs refusé, code" 1 "$code"
verifier "$cas" "message clair" 1 "$(nb_motif "--anciens-journaux" "$base/sortie.txt")"
verifier "$cas" "fichier du dossier refusé laissé" présent "$([[ -e "$HOME/Documents/important.txt" ]] && echo présent || echo absent)"
verifier "$cas" "ancien journal laissé" présent "$([[ -e "$HOME/Library/Logs/macstatusd/macstatusd.log" ]] && echo présent || echo absent)"
verifier "$cas" "rien à la Corbeille" 0 "$(ls -A "$HOME/.Trash" 2>/dev/null | wc -l | tr -d ' ')"
verifier "$cas" "app non installée" absent "$([[ -e "$installee" ]] && echo présent || echo absent)"
nouveau_cas anciens-journaux-sous-sous-dossier
creer_app v1
mkdir -p "$HOME/Library/Logs/a/b"
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant" --anciens-journaux "$HOME/Library/Logs/a/b"
verifier "$cas" "sous-dossier non direct refusé, code" 1 "$code"

# Relance en échec : pas de « agent relancé ».
nouveau_cas relance-echec
creer_app v1
export FAUX_LAUNCHCTL_PRINT=0 FAUX_LAUNCHCTL_KICKSTART_CODE=1
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "kickstart tenté" 1 "$(nb_motif "kickstart -k" "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "pas de « agent relancé »" 0 "$(nb_motif "agent relancé" "$base/sortie.txt")"
verifier "$cas" "M1 : marqueur retiré (aucun kickstart réussi ne l'a consommé)" absent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"
verifier "$cas" "M3 : commande de relance donnée" 1 "$(nb_motif "launchctl kickstart -k gui/$(id -u)/com.djoko.macstatusd.essai)" "$base/sortie.txt")"
# M1 : la copie échoue après la pose du marqueur.
nouveau_cas marqueur-copie-echec
creer_app v1
export FAUX_LAUNCHCTL_PRINT=0
mkdir -p "$HOME/Applications"
chmod 000 "$app/Contents/MacOS" 2>/dev/null
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
chmod 755 "$app/Contents/MacOS"
verifier "$cas" "copie en échec : code 1" 1 "$code"
verifier "$cas" "M1 : marqueur absent après l'échec" absent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"
# Libellé d'un autre agent chargé : l'agent 0.6 n'est pas pris pour chargé (le faux répond par libellé).
nouveau_cas faux-par-libelle
creer_app v1
creer_ancien
charger "$libelle" "$prefixe/macstatusd"
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "agent 0.6 non pris pour chargé : aucun « Agent déjà chargé »" 0 "$(nb_motif "Agent déjà chargé" "$base/sortie.txt")"
verifier "$cas" "aucun kickstart avant le retrait de l'ancien" oui "$([[ $(rang_premier '^launchctl kickstart') -gt $(rang_premier '^launchctl bootout') ]] && echo oui || echo non)"
# Journal d'une config existante : le log_file de la config est donné.
nouveau_cas journal-config
creer_app v1
mkdir -p "$support"
printf '{"log_file": "/private/tmp/macstatusd-plan4/journal-essai.log", "auth_token": "ab"}\n' > "$config"
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "E1 : message avec le log_file de la config" 1 "$(nb_motif "Journal : /private/tmp/macstatusd-plan4/journal-essai.log" "$base/sortie.txt")"
verifier "$cas" "pas de rappel de config (config gardée)" 0 "$(nb_motif "La configuration vient d'être créée" "$base/sortie.txt")"

# --- Même libellé que l'agent 0.6 (gabarit publié de la 0.5) ------------------------------
nouveau_cas migration-meme-libelle
libelle="com.djoko.macstatusd"
creer_app v1 com.djoko.macstatusd macstatusd-essai
creer_ancien
charger "$libelle" "$prefixe/macstatusd"
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "aucun marqueur restart-pending" absent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"
verifier "$cas" "aucun kickstart" 0 "$(nb_motif kickstart "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "pas de « Agent déjà chargé »" 0 "$(nb_motif "Agent déjà chargé" "$base/sortie.txt")"
verifier "$cas" "bootout de l'identifiant avant --register" 1 "$(nb_motif "bootout gui/$(id -u)/$libelle" "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "le bootout précède --register" oui "$([[ $(rang_premier '^launchctl bootout') -gt 0 && $(rang_premier '^launchctl bootout') -lt $(rang_premier '^app --register') ]] && echo oui || echo non)"
verifier "$cas" "aucun bootout après --register" 0 "$(sed -n "$(rang_premier '^app --register'),\$p" "$FAUX_JOURNAL/ordre.log" | /usr/bin/grep -c bootout || true)"
verifier "$cas" "message d'arrêt avant l'enregistrement" 1 "$(nb_motif "Ancienne version arrêtée avant l'enregistrement (même libellé)" "$base/sortie.txt")"
verifier "$cas" "plist à la Corbeille" 1 "$(en_poubelle "$libelle.plist")"
verifier "$cas" "plist retiré de LaunchAgents" absent "$([[ -e "$HOME/Library/LaunchAgents/$libelle.plist" ]] && echo présent || echo absent)"
verifier "$cas" "aucun bootstrap" 0 "$(nb_motif bootstrap "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "anciens journaux à la Corbeille" 1 "$(en_poubelle "macstatusd.log")"
verifier_jeton_cache

nouveau_cas migration-meme-libelle-echec
libelle="com.djoko.macstatusd"
creer_app v1 com.djoko.macstatusd macstatusd-essai
creer_ancien
charger "$libelle" "$prefixe/macstatusd"
export FAUX_APP_CODE=1
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 1 "$code"
verifier "$cas" "bootstrap du plist après --register" oui "$([[ $(rang_dernier "^launchctl bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/$libelle.plist") -gt $(rang_premier '^app --register') && $(rang_premier '^app --register') -gt 0 ]] && echo oui || echo non)"
verifier "$cas" "plist laissé en place" présent "$([[ -e "$HOME/Library/LaunchAgents/$libelle.plist" ]] && echo présent || echo absent)"
verifier "$cas" "plist pas à la Corbeille" 0 "$(en_poubelle "$libelle.plist")"
verifier "$cas" "message : l'ancienne version a été relancée" 1 "$(nb_motif "L'ancienne version a été relancée" "$base/sortie.txt")"
verifier "$cas" "aucun marqueur restart-pending" absent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"

nouveau_cas migration-meme-libelle-echec-bootstrap
libelle="com.djoko.macstatusd"
creer_app v1 com.djoko.macstatusd macstatusd-essai
creer_ancien
charger "$libelle" "$prefixe/macstatusd"
export FAUX_APP_CODE=1 FAUX_LAUNCHCTL_BOOTSTRAP_CODE=5
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 1 "$code"
verifier "$cas" "message : pas de faux « relancée »" 0 "$(nb_motif "L'ancienne version a été relancée" "$base/sortie.txt")"
verifier "$cas" "message : n'a pas pu être relancée" 1 "$(nb_motif "n'a pas pu être relancée" "$base/sortie.txt")"
verifier "$cas" "commande de relance donnée" 1 "$(nb_motif "launchctl bootstrap gui/$(id -u) \"$HOME/Library/LaunchAgents/$libelle.plist\"" "$base/sortie.txt")"

nouveau_cas migration-meme-libelle-a-approuver
libelle="com.djoko.macstatusd"
creer_app v1 com.djoko.macstatusd macstatusd-essai
creer_ancien
charger "$libelle" "$prefixe/macstatusd"
export FAUX_APP_CODE=3
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "pas de bootstrap (le libellé doit rester libre)" 0 "$(nb_motif bootstrap "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "bootout fait avant --register" 1 "$(nb_motif "bootout gui/$(id -u)/$libelle" "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "plist encore en place" présent "$([[ -e "$HOME/Library/LaunchAgents/$libelle.plist" ]] && echo présent || echo absent)"
verifier "$cas" "message : relancer le script après l'autorisation" 1 "$(nb_motif "relance ce script tout de suite" "$base/sortie.txt")"
verifier "$cas" "aucune vérification" 0 "$(nb_lignes "$FAUX_JOURNAL/curl.log")"
verifier "$cas" "aucun marqueur restart-pending" absent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"

# Relance après l'autorisation : le libellé est tenu par la 0.6, qui ne doit pas être arrêtée.
nouveau_cas migration-meme-libelle-relance-apres-autorisation
libelle="com.djoko.macstatusd"
creer_app v1 com.djoko.macstatusd macstatusd-essai
creer_ancien
charger "$libelle" "$installee/Contents/MacOS/macstatusd"
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "la 0.6 n'est pas arrêtée (aucun bootout)" 0 "$(nb_motif bootout "$FAUX_JOURNAL/launchctl.log")"
verifier "$cas" "aucun bootout du libellé avant --register" 0 "$(sed -n "1,$(rang_premier '^app --register')p" "$FAUX_JOURNAL/ordre.log" | /usr/bin/grep -c bootout || true)"
verifier "$cas" "kickstart après --register" oui "$([[ $(rang_dernier '^launchctl kickstart') -gt $(rang_premier '^app --register') && $(rang_premier '^app --register') -gt 0 ]] && echo oui || echo non)"
verifier "$cas" "message : agent déjà chargé" 1 "$(nb_motif "Agent déjà chargé" "$base/sortie.txt")"
verifier "$cas" "marqueur restart-pending posé (le daemon le consomme)" présent "$([[ -e "$support/restart-pending" ]] && echo présent || echo absent)"
verifier "$cas" "plist à la Corbeille" 1 "$(en_poubelle "$libelle.plist")"

# --- migration-identite-production ------------------------------------------------------
# En production, le nom de support vaut « macstatusd » : la 0.6 écrit dans le dossier de journaux de la 0.5.
nouveau_cas migration-identite-production
creer_app v1 com.djoko.macstatusd.essai macstatusd
creer_ancien
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "ancien journal à la Corbeille" 1 "$(en_poubelle "macstatusd.log")"
verifier "$cas" "l'app ne voit plus l'ancien journal à l'enregistrement" 0 "$(nb_motif "macstatusd.log" "$FAUX_JOURNAL/logs-vus.txt")"
verifier "$cas" "dossier des journaux vu à l'enregistrement" 1 "$(nb_motif "--register" "$FAUX_JOURNAL/logs-vus.txt")"
verifier "$cas" "message final : chemin de journal hors de la Corbeille" 1 "$(nb_motif "Journal : $HOME/Library/Logs/macstatusd/macstatusd.log" "$base/sortie.txt")"
verifier "$cas" "message final : rien ne désigne la Corbeille" 0 "$(/usr/bin/grep 'Journal :' "$base/sortie.txt" | /usr/bin/grep -c -F '.Trash' || true)"
verifier "$cas" "plist de l'ancien agent retiré après l'enregistrement" 1 "$(en_poubelle "$libelle.plist")"
verifier_jeton_cache

# --- prefixe-sans-binaire ---------------------------------------------------------------
nouveau_cas prefixe-sans-binaire
creer_app v1
mkdir -p "$base/opt/autre"
lancer_install --app "$app" --ancien-prefixe "$base/opt/autre"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "aucune commande sudo rm -rf proposée" 0 "$(nb_motif "sudo rm" "$base/sortie.txt")"

# --- home-invalide ----------------------------------------------------------------------
nouveau_cas home-invalide
creer_app v1
mkdir -p "$base/relatif"
( cd "$base" && HOME="relatif" bash "$depot/scripts/install.sh" --app "$app" --ancien-prefixe "$base/opt/inexistant" > "$base/sortie.txt" 2>&1 ); code=$?
verifier "$cas" "HOME relatif : install.sh refuse, code" 1 "$code"
verifier "$cas" "HOME relatif : rien créé" 0 "$(ls -A "$base/relatif" | wc -l | tr -d ' ')"
rm -rf "$base/relatif"
for home_mauvais in "/" "//" ""; do
  ( cd "$base" && HOME="$home_mauvais" bash "$depot/scripts/install.sh" --app "$app" --ancien-prefixe "$base/opt/inexistant" > "$base/sortie.txt" 2>&1 ); code=$?
  verifier "$cas" "HOME « $home_mauvais » : install.sh refuse, code" 1 "$code"
  verifier "$cas" "HOME « $home_mauvais » : message clair" 1 "$(nb_motif "HOME invalide" "$base/sortie.txt")"
  ( cd "$base" && HOME="$home_mauvais" bash "$depot/scripts/uninstall.sh" --app "$app" > "$base/sortie-desinstall.txt" 2>&1 ); code=$?
  verifier "$cas" "HOME « $home_mauvais » : uninstall.sh refuse, code" 1 "$code"
  verifier "$cas" "HOME « $home_mauvais » : uninstall.sh message clair" 1 "$(nb_motif "HOME invalide" "$base/sortie-desinstall.txt")"
done

# --- preparer-jeton ---------------------------------------------------------------------
nouveau_cas preparer-jeton
creer_app v1
lancer_install --app "$app" --preparer-jeton --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "message jeton prêt" 1 "$(nb_motif "jeton prêt dans $config (64 caractères)" "$base/sortie.txt")"
verifier "$cas" "droits de la config" 600 "$(stat -f %Lp "$config" 2>/dev/null)"
verifier "$cas" "aucune app installée" absent "$([[ -e "$installee" ]] && echo présent || echo absent)"
verifier "$cas" "aucun --register" 0 "$(nb_motif "--register" "$FAUX_JOURNAL/app.log")"
verifier "$cas" "aucune vérification" 0 "$(nb_lignes "$FAUX_JOURNAL/curl.log")"
lancer_install --app "$app" --preparer-jeton --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "second passage : message jeton déjà présent" 1 "$(nb_motif "jeton déjà présent dans $config" "$base/sortie.txt")"
verifier_jeton_cache
# Sans --app : identité par défaut, aucune compilation.
nouveau_cas preparer-jeton-sans-app
lancer_install --preparer-jeton --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "config de l'identité par défaut" présent "$([[ -f "$HOME/Library/Application Support/macstatusd/config.json" ]] && echo présent || echo absent)"
verifier "$cas" "aucune compilation" 0 "$(nb_lignes "$FAUX_JOURNAL/swift.log")"
verifier_jeton_cache "$HOME/Library/Application Support/macstatusd/config.json"

# --- a-approuver ------------------------------------------------------------------------
nouveau_cas a-approuver
creer_app v1
creer_ancien
export FAUX_APP_CODE=3
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "message des Réglages affiché" oui "$([[ $(nb_motif "Réglages Système > Général > Ouverture et extensions" "$base/sortie.txt") -ge 1 ]] && echo oui || echo non)"
verifier "$cas" "un seul --register" 1 "$(nb_motif "--register" "$FAUX_JOURNAL/app.log")"
verifier "$cas" "ancien agent laissé en place tant que l'app n'est pas autorisée" présent "$([[ -e "$HOME/Library/LaunchAgents/$libelle.plist" ]] && echo présent || echo absent)"
verifier "$cas" "aucune vérification" 0 "$(nb_lignes "$FAUX_JOURNAL/curl.log")"
verifier_jeton_cache
# Code 3 avec agent déjà chargé : pas de kickstart.
nouveau_cas a-approuver-agent-charge
creer_app v1
export FAUX_APP_CODE=3 FAUX_LAUNCHCTL_PRINT=0
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "aucun kickstart sur le code 3" 0 "$(nb_motif kickstart "$FAUX_JOURNAL/launchctl.log")"
# Autres codes de l'app : échec, code 1.
nouveau_cas enregistrement-refuse
creer_app v1
export FAUX_APP_CODE=5
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code 5 de l'app : échec" 1 "$code"
verifier_jeton_cache

# --- refus-root -------------------------------------------------------------------------
nouveau_cas refus-root
creer_app v1
MACSTATUSD_EUID=0 lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "install.sh : code de sortie" 1 "$code"
verifier "$cas" "install.sh : rien créé" absent "$([[ -e "$support" || -e "$installee" ]] && echo présent || echo absent)"
MACSTATUSD_EUID=0 lancer_desinstall --app "$installee"
verifier "$cas" "uninstall.sh : code de sortie" 1 "$code"

# --- hote-verifie -----------------------------------------------------------------------
nouveau_cas hote-verifie
creer_app v1
mkdir -p "$support"
printf '{"bind_address": "192.0.2.5", "port": 19123, "auth_token": "ab"}\n' > "$config"
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "curl vers l'adresse de bind_address" 1 "$(nb_motif "http://192.0.2.5:19123/health" "$FAUX_JOURNAL/curl.log")"
verifier "$cas" "jeton existant gardé" ab "$(valeur "$config" 'c["auth_token"]')"
nouveau_cas hote-joker
creer_app v1
mkdir -p "$support"
printf '{"bind_address": "::", "port": 19124}\n' > "$config"
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "« :: » donne 127.0.0.1" 1 "$(nb_motif "http://127.0.0.1:19124/health" "$FAUX_JOURNAL/curl.log")"
verifier "$cas" "jeton ajouté à la config existante" 64 "$(valeur "$config" 'len(c["auth_token"])')"
verifier "$cas" "droits de la config existante" 600 "$(stat -f %Lp "$config" 2>/dev/null)"
verifier_jeton_cache
nouveau_cas sans-verification
creer_app v1
lancer_install --app "$app" --sans-verification --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "aucun curl" 0 "$(nb_lignes "$FAUX_JOURNAL/curl.log")"
nouveau_cas verification-echec
creer_app v1
export FAUX_CURL_CODE=7
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "pas de réponse : code 1" 1 "$code"
verifier "$cas" "vingt essais" 20 "$(nb_lignes "$FAUX_JOURNAL/curl.log")"
verifier_jeton_cache

# --- json-invalide ----------------------------------------------------------------------
nouveau_cas json-invalide
creer_app v1
creer_ancien
printf '{ ceci n est pas du json\n' > "$prefixe/config.json"
lancer_install --app "$app" --ancien-prefixe "$prefixe"
verifier "$cas" "ancienne config illisible : code 1" 1 "$code"
verifier "$cas" "message clair" 1 "$(nb_motif "illisible" "$base/sortie.txt")"
verifier "$cas" "aucune trace Python" 0 "$(nb_motif Traceback "$base/sortie.txt")"
verifier "$cas" "aucune config à moitié écrite" absent "$([[ -e "$config" ]] && echo présent || echo absent)"
verifier "$cas" "aucune app installée" absent "$([[ -e "$installee" ]] && echo présent || echo absent)"
verifier "$cas" "aucun --register" 0 "$(nb_motif "--register" "$FAUX_JOURNAL/app.log")"
verifier "$cas" "ancien agent laissé" présent "$([[ -e "$HOME/Library/LaunchAgents/$libelle.plist" ]] && echo présent || echo absent)"
nouveau_cas json-invalide-existante
creer_app v1
mkdir -p "$support"
printf '[1, 2]\n' > "$config"
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "config existante qui n'est pas un objet : code 1" 1 "$code"
verifier "$cas" "aucune trace Python" 0 "$(nb_motif Traceback "$base/sortie.txt")"
verifier "$cas" "config existante intacte" "[1, 2]" "$(cat "$config")"

# --- identité hors des dossiers permis --------------------------------------------------
nouveau_cas nom-de-support-dangereux
creer_app v1 com.djoko.macstatusd.essai "../../evasion"
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "install.sh refuse : code 1" 1 "$code"
verifier "$cas" "rien installé" absent "$([[ -e "$installee" ]] && echo présent || echo absent)"
lancer_desinstall --app "$app"
verifier "$cas" "uninstall.sh refuse : code 1" 1 "$code"

# --- compilation (sans --app, faux swift, vrai assembleur) ----------------------------
nouveau_cas compilation
mkdir -p "$base/bin"
cp "$faux/macstatusd-app" "$base/bin/macstatusd"
export FAUX_BIN_DIR="$base/bin"
lancer_install --ancien-prefixe "$base/opt/inexistant"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "swift build -c release lancé (compilation et chemin du binaire)" 2 "$(nb_motif "build -c release" "$FAUX_JOURNAL/swift.log")"
[[ -x "$HOME/Applications/macstatusd.app/Contents/MacOS/macstatusd" ]] && ok "$cas : app assemblée puis installée" || ko "$cas" "app absente de ~/Applications"
verifier "$cas" "un seul --register" 1 "$(nb_motif "--register" "$FAUX_JOURNAL/app.log")"
verifier_jeton_cache "$HOME/Library/Application Support/macstatusd/config.json"
unset FAUX_BIN_DIR

# --- desinstallation --------------------------------------------------------------------
nouveau_cas desinstallation
creer_app v1
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
mkdir -p "$HOME/Library/Logs/macstatusd-essai"
printf 'journal\n' > "$HOME/Library/Logs/macstatusd-essai/macstatusd.log"
lancer_desinstall --app "$installee"
verifier "$cas" "code de sortie" 0 "$code"
verifier "$cas" "--unregister appelé" 1 "$(nb_motif "--unregister" "$FAUX_JOURNAL/app.log")"
verifier "$cas" "app retirée de ~/Applications" absent "$([[ -e "$installee" ]] && echo présent || echo absent)"
verifier "$cas" "app à la Corbeille" 1 "$(en_poubelle "macstatusd-essai.app")"
verifier "$cas" "config gardée" présent "$([[ -f "$config" ]] && echo présent || echo absent)"
verifier "$cas" "journaux gardés" présent "$([[ -f "$HOME/Library/Logs/macstatusd-essai/macstatusd.log" ]] && echo présent || echo absent)"
verifier "$cas" "aucun appel à sudo" 0 "$(nb_lignes "$FAUX_JOURNAL/sudo.log")"
verifier_jeton_cache
# --tout : config et journaux à la Corbeille.
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
lancer_desinstall --app "$installee" --tout
verifier "$cas" "--tout : code de sortie" 0 "$code"
verifier "$cas" "--tout : dossier de support retiré" absent "$([[ -e "$support" ]] && echo présent || echo absent)"
verifier "$cas" "--tout : dossier de journaux retiré" absent "$([[ -e "$HOME/Library/Logs/macstatusd-essai" ]] && echo présent || echo absent)"
verifier "$cas" "--tout : support et journaux à la Corbeille" 2 "$(find "$HOME/.Trash" -maxdepth 1 -name 'macstatusd-essai*' ! -name '*.app*' | wc -l | tr -d ' ')"
verifier "$cas" "--tout : config conservée dans la Corbeille" 1 "$(find "$HOME/.Trash" -name config.json 2>/dev/null | wc -l | tr -d ' ')"
# Garde-fou F35 : une app hors de ~/Applications est refusée, sans --unregister.
nouveau_cas desinstallation-hors-dossier
creer_app v1
lancer_desinstall --app "$app"
verifier "$cas" "app hors de ~/Applications : code 1" 1 "$code"
verifier "$cas" "aucun --unregister" 0 "$(nb_motif "--unregister" "$FAUX_JOURNAL/app.log")"
verifier "$cas" "app intacte" présent "$([[ -d "$app" ]] && echo présent || echo absent)"
# Désinstallation : --unregister qui échoue (code 3) : l'app reste en place.
nouveau_cas desinstallation-echec
creer_app v1
lancer_install --app "$app" --ancien-prefixe "$base/opt/inexistant"
export FAUX_APP_UNREGISTER_CODE=3
lancer_desinstall --app "$installee"
verifier "$cas" "--unregister en échec : code 1" 1 "$code"
verifier "$cas" "app laissée en place" présent "$([[ -d "$installee" ]] && echo présent || echo absent)"

# --- sans-sudo --------------------------------------------------------------------------
cas=sans-sudo
for script in install.sh uninstall.sh; do
  n=$(/usr/bin/grep -n "sudo" "$depot/scripts/$script" | /usr/bin/grep -v -E '^[0-9]+:[[:space:]]*(#|echo|printf)' | wc -l | tr -d ' ')
  verifier "$cas" "$script : aucune ligne ne lance sudo" 0 "$n"
done

# --- Rien hors du dossier d'essai ---------------------------------------------------------
apres=$(etat_reel)
verifier "hors-dossier" "~/Applications et ~/LaunchAgents réels inchangés" "$avant" "$apres"

echo
if [[ $echec -eq 0 ]]; then echo "Tous les cas passent."; else echo "Des cas échouent."; fi
exit $echec
