#!/bin/bash
# Désinstalle macstatusd, SANS sudo : retire l'agent (--unregister), puis met l'app à la Corbeille.
#
# Usage : bash scripts/uninstall.sh [--app <chemin.app>] [--tout]
#
#   --app    App à désinstaller (défaut ~/Applications/macstatusd.app). Elle doit être sous ~/Applications.
#   --tout   Met aussi à la Corbeille la config (jeton compris) et les journaux. Sans cette option,
#            ils sont gardés.
#
# Rien n'est supprimé pour de bon : « Corbeille » veut dire déplacé dans ~/.Trash. Le garde-fou refuse
# tout chemin calculé qui sort de ~/Applications ou de ~/Library.
# Codes de sortie : 0 réussi, 1 échec ou refus, 2 usage.
#
# Variable de test seulement : MACSTATUSD_EUID (remplace $EUID).
set -euo pipefail

if [[ "${MACSTATUSD_EUID:-$EUID}" -eq 0 ]]; then
  echo "!! Ne pas lancer ce script en root ni avec sudo : l'app vit dans ~/Applications, sans sudo." >&2
  exit 1
fi

# Garde-fou de HOME : absolu et différent de « / ». Sinon « $HOME/Applications » pointerait un dossier
# du système (ou un chemin relatif) où l'on ne doit rien écrire.
home_normalise="$(printf '%s' "${HOME:-}" | tr -s '/')"
home_normalise="${home_normalise%/}"
if [[ -z "${HOME:-}" || "$HOME" != /* || -z "$home_normalise" ]]; then
  echo "!! HOME invalide (vide, relatif ou « / ») : rien n'est fait." >&2
  exit 1
fi

pb=/usr/libexec/PlistBuddy
app="$HOME/Applications/macstatusd.app"
tout=0

usage() { echo "Usage : bash scripts/uninstall.sh [--app <chemin.app>] [--tout]" >&2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      if [[ $# -lt 2 ]]; then echo "option sans valeur : $1" >&2; usage; exit 2; fi
      app="$2"; shift 2 ;;
    --tout) tout=1; shift ;;
    *) echo "option inconnue : $1" >&2; usage; exit 2 ;;
  esac
done
app="${app%/}"

corbeille() { # chemin
  local nom dest n=0
  mkdir -p "$HOME/.Trash"
  nom="$(basename "$1")"
  dest="$HOME/.Trash/$nom"
  while [[ -e "$dest" ]]; do
    n=$((n + 1))
    dest="$HOME/.Trash/$nom ($n)"
  done
  mv "$1" "$dest"
}

# Garde-fou (F35) : un chemin calculé reste sous ~/Applications ou ~/Library, sans « .. ».
exiger_chemin_permis() { # chemin
  case "$1" in
    *"/../"*|*"/..") ;;
    "$HOME/Applications/"?*|"$HOME/Library/"?*) return 0 ;;
  esac
  echo "!! Chemin refusé (hors de ~/Applications et de ~/Library) : $1" >&2
  exit 1
}

exiger_chemin_permis "$app"
# Un lien symbolique ne doit pas faire sortir l'app du dossier permis.
if [[ -e "$app" ]]; then
  reel="$(cd -P "$app" && pwd)"
  vrai_home="$(cd -P "$HOME" && pwd)"
  case "$reel" in
    "$vrai_home/Applications/"?*) ;;
    *) echo "!! Chemin refusé (l'app est réellement hors de ~/Applications) : $app" >&2; exit 1 ;;
  esac
fi

nom_app="$(basename "$app")"
if [[ "$nom_app" != *.app ]]; then
  echo "!! Nom d'app invalide : $nom_app" >&2
  exit 1
fi

# --- Identité : de l'app ; app déjà absente, seul le nom par défaut est connu --------------------
if [[ -f "$app/Contents/Info.plist" ]]; then
  nom_support="$("$pb" -c "Print :MacstatusdSupportName" "$app/Contents/Info.plist" 2>/dev/null)" || nom_support=""
  app_presente=1
elif [[ "$nom_app" == "macstatusd.app" ]]; then
  nom_support="macstatusd"
  app_presente=0
  echo "==> App absente (déjà désinstallée ?) : seuls la config et les journaux restent à traiter"
else
  echo "!! App introuvable : $app" >&2
  exit 1
fi
if [[ -z "$nom_support" || "$nom_support" == */* || "$nom_support" == "." || "$nom_support" == ".." ]]; then
  echo "!! MacstatusdSupportName absent ou invalide dans l'app" >&2
  exit 1
fi
support="$HOME/Library/Application Support/$nom_support"
logs="$HOME/Library/Logs/$nom_support"
exiger_chemin_permis "$support"
exiger_chemin_permis "$logs"

# --- Retrait de l'agent, puis de l'app ------------------------------------------------------------
if [[ $app_presente -eq 1 ]]; then
  echo "==> Retrait de l'agent"
  code_app=0
  sortie_app="$("$app/Contents/MacOS/macstatusd" --unregister 2>&1)" || code_app=$?
  # Après --unregister, « non enregistré » (4) ou « introuvable » (5) disent que l'agent est parti.
  if [[ $code_app -ne 4 && $code_app -ne 5 ]]; then
    echo "    $sortie_app"
    echo "!! L'agent n'est pas retiré (code $code_app) : l'app reste en place. Relance, ou retire-la" >&2
    echo "   à la main dans Réglages Système > Général > Ouverture et extensions." >&2
    exit 1
  fi
  # Le message d'état de l'app (« non enregistré : lancer macstatusd --register ») conseillerait de la réenregistrer.
  echo "    agent retiré"
  corbeille "$app"
  echo "==> App mise à la Corbeille : $nom_app"
fi

# --- Config et journaux ---------------------------------------------------------------------------
if [[ $tout -eq 1 ]]; then
  for dossier in "$support" "$logs"; do
    if [[ -e "$dossier" ]]; then
      corbeille "$dossier"
      echo "==> À la Corbeille : $dossier"
    fi
  done
else
  echo "    gardés : $support (config et jeton), $logs (journaux). --tout les met à la Corbeille."
fi
