#!/bin/bash
# Installe macstatusd comme app d'arrière-plan dans ~/Applications, SANS sudo.
#
# Usage : bash scripts/install.sh [--app <chemin.app>] [--ancien-prefixe <dossier>]
#                                 [--anciens-journaux <dossier>] [--preparer-jeton] [--sans-verification]
#
#   --app                Installe cette app. Sans cette option : compilation (swift build -c release),
#                        puis outils/assembler-app.sh. L'identité (CFBundleIdentifier, MacstatusdSupportName)
#                        vient de l'app.
#   --ancien-prefixe     Dossier de l'ancienne installation (défaut /opt/macstatusd) : sa config est migrée
#                        (lecture seule) et son agent launchd est retiré.
#   --anciens-journaux   Dossier des journaux de l'ancien agent (défaut ~/Library/Logs/macstatusd), mis à la
#                        Corbeille (son contenu) quand un ancien agent est repéré. Doit être un sous-dossier
#                        direct de ~/Library/Logs/, sinon refus (code 1) : une répétition le désigne pour ne
#                        pas vider les journaux de la vraie instance.
#   --preparer-jeton     S'arrête après la config et le jeton : ni copie de l'app, ni enregistrement.
#   --sans-verification  Ne contrôle pas /health à la fin.
#
# Étapes : config (gardée, migrée ou prise de config.example.json), jeton, marqueur de redémarrage,
# copie de l'app, enregistrement (--register), retrait de l'ancien agent, vérification.
# Codes de sortie : 0 réussi (y compris « à autoriser dans les Réglages »), 1 échec, 2 usage.
#
# Variables de test seulement : MACSTATUSD_EUID (remplace $EUID), MACSTATUSD_VERIF_PAUSE (pause entre
# deux essais de la vérification, 0,5 s par défaut).
set -euo pipefail

if [[ "${MACSTATUSD_EUID:-$EUID}" -eq 0 ]]; then
  echo "!! Ne pas lancer ce script en root ni avec sudo : l'app s'installe dans ~/Applications, sans sudo." >&2
  exit 1
fi

# Garde-fou de HOME : absolu et différent de « / ». Sinon « $HOME/Applications » pointerait un dossier
# du système (ou un chemin relatif) où l'on ne doit rien écrire.
home_normalise="$(printf '%s' "${HOME:-}" | tr -s '/')"
home_normalise="${home_normalise%/}"
if [[ -z "${HOME:-}" || "$HOME" != /* || -z "$home_normalise" ]]; then
  echo "!! HOME invalide (vide, relatif ou « / ») : rien n'est installé." >&2
  exit 1
fi

depot="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pb=/usr/libexec/PlistBuddy

app_source=""
ancien_prefixe="/opt/macstatusd"
anciens_journaux="$HOME/Library/Logs/macstatusd"
preparer_jeton=0
sans_verification=0

usage() {
  echo "Usage : bash scripts/install.sh [--app <chemin.app>] [--ancien-prefixe <dossier>] [--anciens-journaux <dossier>] [--preparer-jeton] [--sans-verification]" >&2
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--ancien-prefixe|--anciens-journaux)
      if [[ $# -lt 2 ]]; then echo "option sans valeur : $1" >&2; usage; exit 2; fi
      case "$1" in
        --app) app_source="$2" ;;
        --ancien-prefixe) ancien_prefixe="$2" ;;
        *) anciens_journaux="$2" ;;
      esac
      shift 2 ;;
    --preparer-jeton) preparer_jeton=1; shift ;;
    --sans-verification) sans_verification=1; shift ;;
    *) echo "option inconnue : $1" >&2; usage; exit 2 ;;
  esac
done
ancien_prefixe="${ancien_prefixe%/}"
anciens_journaux="${anciens_journaux%/}"
# Le dossier des anciens journaux est vidé : il doit être un sous-dossier direct de ~/Library/Logs/.
nom_journaux="${anciens_journaux#"$HOME/Library/Logs/"}"
if [[ "$anciens_journaux" != "$HOME/Library/Logs/"* || -z "$nom_journaux" || "$nom_journaux" == */* \
      || "$nom_journaux" == "." || "$nom_journaux" == ".." ]]; then
  echo "!! --anciens-journaux doit être un sous-dossier direct de $HOME/Library/Logs/ : refusé, rien n'est installé." >&2
  exit 1
fi

# --- Outils -----------------------------------------------------------------------------
# « À la Corbeille » : déplacement dans ~/.Trash, sous un nom unique en cas de collision.
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

# Garde-fou : un chemin calculé reste sous ~/Applications ou ~/Library, sans « .. ».
chemin_permis() { # chemin
  case "$1" in
    *"/../"*|*"/..") return 1 ;;
    "$HOME/Applications/"?*|"$HOME/Library/"?*) return 0 ;;
    *) return 1 ;;
  esac
}
exiger_chemin_permis() { # chemin
  if ! chemin_permis "$1"; then
    echo "!! Chemin refusé (hors de ~/Applications et de ~/Library) : $1" >&2
    exit 1
  fi
}

# Valeur d'une clé de l'Info.plist de l'app (vide si absente).
cle_app() { # app clé
  "$pb" -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

# --- Identité : de l'app, ou par défaut (--preparer-jeton sans --app) ---------------------------
if [[ -z "$app_source" && $preparer_jeton -eq 0 ]]; then
  echo "==> Compilation (swift build -c release)"
  (cd "$depot" && swift build -c release)
  dossier_binaire="$(cd "$depot" && swift build -c release --show-bin-path)"
  journal_assemblage="$(mktemp)"
  assemblage=0
  bash "$depot/outils/assembler-app.sh" --binaire "$dossier_binaire/macstatusd" > "$journal_assemblage" 2>&1 || assemblage=$?
  if [[ $assemblage -ne 0 ]]; then
    cat "$journal_assemblage" >&2
    rm -f "$journal_assemblage"
    echo "!! L'assemblage de l'app a échoué (code $assemblage)" >&2
    exit 1
  fi
  app_source="$(tail -n 1 "$journal_assemblage")"
  rm -f "$journal_assemblage"
fi

if [[ -n "$app_source" ]]; then
  app_source="${app_source%/}"
  if [[ ! -f "$app_source/Contents/Info.plist" ]]; then
    echo "!! App introuvable ou sans Info.plist : $app_source" >&2
    exit 1
  fi
  identifiant="$(cle_app "$app_source" CFBundleIdentifier)"
  nom_support="$(cle_app "$app_source" MacstatusdSupportName)"
  nom_app="$(basename "$app_source")"
else
  identifiant="com.djoko.macstatusd"
  nom_support="macstatusd"
  nom_app="macstatusd.app"
fi
if [[ ! "$identifiant" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "!! CFBundleIdentifier absent ou invalide dans l'app" >&2
  exit 1
fi
if [[ -z "$nom_support" || "$nom_support" == */* || "$nom_support" == "." || "$nom_support" == ".." ]]; then
  echo "!! MacstatusdSupportName absent ou invalide dans l'app" >&2
  exit 1
fi
if [[ "$nom_app" != *.app || "$nom_app" == */* ]]; then
  echo "!! Nom d'app invalide : $nom_app" >&2
  exit 1
fi

support="$HOME/Library/Application Support/$nom_support"
config="$support/config.json"
logs="$HOME/Library/Logs/$nom_support"
destination="$HOME/Applications/$nom_app"
exiger_chemin_permis "$support"
exiger_chemin_permis "$destination"

# --- 1. Config ----------------------------------------------------------------------------
# Le script Python lit la config source, migre webhook_base_url vers webhook_targets (pour une config
# neuve), génère un jeton s'il manque, et écrit le JSON sur la sortie standard.
# Codes : 0 jeton généré, 10 jeton déjà présent, 1 config illisible (message sur la sortie d'erreur).
read -r -d '' python_config <<'PY' || true
import json, secrets, sys
mode, source = sys.argv[1], sys.argv[2]
try:
    with open(source, encoding="utf-8") as f:
        cfg = json.load(f)
except OSError as e:
    sys.stderr.write("!! Config illisible : %s (%s)\n" % (source, e.strerror))
    sys.exit(1)
except ValueError as e:
    detail = "ligne %d" % e.lineno if hasattr(e, "lineno") else "encodage illisible"
    sys.stderr.write("!! Config illisible : %s (JSON invalide, %s)\n" % (source, detail))
    sys.exit(1)
if not isinstance(cfg, dict):
    sys.stderr.write("!! Config illisible : %s (un objet JSON est attendu)\n" % source)
    sys.exit(1)
if mode == "migrer" and "webhook_base_url" in cfg and "webhook_targets" not in cfg:
    base = cfg["webhook_base_url"]
    if isinstance(base, str):
        if base.strip():
            cfg["webhook_targets"] = [{"url": base, "method": "GET"}]
        del cfg["webhook_base_url"]
if mode == "migrer":
    # Le journal de la 0.6 va dans son dossier par défaut : l'ancien chemin n'est pas repris.
    cfg.pop("log_file", None)
jeton = cfg.get("auth_token")
genere = not (isinstance(jeton, str) and jeton.strip())
if genere:
    cfg["auth_token"] = secrets.token_hex(32)
sys.stdout.write(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
sys.exit(0 if genere else 10)
PY

config_neuve=0
echo "==> Config $config"
mkdir -p "$support"
chmod 700 "$support"
if [[ -e "$config" ]]; then
  mode="jeton"; source_config="$config"
  echo "    config existante gardée"
elif [[ -f "$ancien_prefixe/config.json" ]]; then
  mode="migrer"; source_config="$ancien_prefixe/config.json"
  echo "    migration de la config de l'ancienne installation (lecture seule)"
else
  mode="migrer"; source_config="$depot/config.example.json"
  config_neuve=1
  echo "    config prise de config.example.json"
fi
code_python=0
contenu="$(PYTHONIOENCODING=utf-8 python3 -c "$python_config" "$mode" "$source_config")" || code_python=$?
if [[ $code_python -eq 1 ]]; then exit 1; fi
if [[ $code_python -ne 0 && $code_python -ne 10 ]]; then
  echo "!! Préparation de la config : échec inattendu (code $code_python)" >&2
  exit 1
fi

# --- 2. Jeton (C4) -------------------------------------------------------------------------
# Le fichier est créé vide, passé en 600, puis écrit (dans un fichier voisin, renommé ensuite).
if [[ "$mode" == "migrer" || $code_python -eq 0 ]]; then
  temporaire="$support/.config.json.nouveau.$$"
  : > "$temporaire"
  chmod 600 "$temporaire"
  printf '%s\n' "$contenu" > "$temporaire"
  mv "$temporaire" "$config"
fi
unset contenu
droits="$(stat -f %Lp "$config")"
if [[ "$droits" != "600" ]]; then
  if [[ $code_python -eq 10 && "$mode" == "jeton" ]]; then
    chmod 600 "$config"
    echo "    droits de la config ramenés à 600 (ils étaient $droits)"
  else
    echo "!! Droits de la config : $droits au lieu de 600" >&2
    exit 1
  fi
fi
if [[ $code_python -eq 0 ]]; then
  longueur="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["auth_token"]))' "$config")"
  if [[ "$longueur" != "64" ]]; then
    echo "!! Jeton de $longueur caractères au lieu de 64 : config à corriger à la main" >&2
    exit 1
  fi
fi
if [[ $code_python -eq 0 ]]; then
  echo "    jeton prêt dans $config (64 caractères)"
else
  echo "    jeton déjà présent dans $config"
fi

# Chemin du journal : le log_file de la config s'il y est, sinon le chemin par défaut.
journal="$(python3 -c 'import json,sys
v = json.load(open(sys.argv[1], encoding="utf-8")).get("log_file")
print(v if isinstance(v, str) and v.strip() else "")' "$config" 2>/dev/null)" || journal=""
if [[ -z "$journal" ]]; then journal="$logs/macstatusd.log"; fi

# La config n'est lue qu'au lancement du daemon : une config neuve (enabled: false, sans cible) se
# complète à la main, puis l'agent se relance.
rappel_config() {
  if [[ $config_neuve -eq 1 ]]; then
    echo "    La configuration vient d'être créée : édite $config, puis relance l'agent :"
    echo "      launchctl kickstart -k gui/$(id -u)/$identifiant"
  fi
}
if [[ $preparer_jeton -eq 1 ]]; then
  exit 0
fi

# --- 2b. Anciens agents repérés (F80), retrouvés par leur contenu, jamais par leur libellé ----------
# Repérés AVANT le marqueur : un ancien agent peut porter le même libellé que la 0.6 (gabarit publié de
# la 0.5, com.djoko.macstatusd). Le job chargé sous ce libellé est alors la 0.5, pas l'agent de la 0.6.
anciens_plists=()
plists_collision=()
for plist in "$HOME/Library/LaunchAgents"/*.plist; do
  [[ -f "$plist" ]] || continue
  programme="$("$pb" -c "Print :ProgramArguments:0" "$plist" 2>/dev/null)" || continue
  [[ "$programme" == "$ancien_prefixe/macstatusd" ]] || continue
  anciens_plists+=("$plist")
  libelle_ancien="$("$pb" -c "Print :Label" "$plist" 2>/dev/null)" || libelle_ancien=""
  if [[ "$libelle_ancien" == "$identifiant" ]]; then plists_collision+=("$plist"); fi
done

# --- 3. Marqueur de redémarrage (C16) -------------------------------------------------------
agent_charge=0
marqueur_pose=0
ancien_a_arreter=0
# Un échec après la pose du marqueur ne le laisse pas en place : seul un kickstart réussi le consomme.
trap 'if [[ $marqueur_pose -eq 1 ]]; then rm -f "$support/restart-pending"; fi' EXIT
if [[ ${#plists_collision[@]} -gt 0 ]]; then
  # Le libellé est tenu par la 0.5 (ou, après une autorisation, déjà par la 0.6) : pas de marqueur ici.
  # Seul un job chargé qui lance l'ancien binaire est arrêté avant l'enregistrement.
  if sortie_print="$(launchctl print "gui/$(id -u)/$identifiant" 2>/dev/null)" \
     && [[ "$sortie_print" == *"$ancien_prefixe/macstatusd"* ]]; then
    ancien_a_arreter=1
  fi
  unset sortie_print
elif launchctl print "gui/$(id -u)/$identifiant" > /dev/null 2>&1; then
  agent_charge=1
  : > "$support/restart-pending"
  marqueur_pose=1
  echo "==> Agent déjà chargé : marqueur restart-pending posé (le redémarrage ne publiera pas OFF)"
fi

# --- 4. Copie ---------------------------------------------------------------------------------
echo "==> Copie de l'app dans $destination"
if [[ "$app_source" == "$destination" ]]; then
  echo "    l'app est déjà à sa place"
else
  mkdir -p "$HOME/Applications"
  temporaire_app="$HOME/Applications/.$nom_app.nouveau.$$"
  rm -rf "$temporaire_app"
  if ! ditto --norsrc --noextattr "$app_source" "$temporaire_app"; then
    rm -rf "$temporaire_app"
    echo "!! La copie a échoué : l'ancienne app, s'il y en avait une, est restée en place" >&2
    exit 1
  fi
  if [[ -e "$destination" ]]; then corbeille "$destination"; fi
  mv "$temporaire_app" "$destination"
fi

# --- 4b. Anciens journaux ----------------------------------------------------------------------------
# Les journaux de la 0.5.0 (URL du webhook en clair, spec section 4) partent à la Corbeille AVANT
# l'enregistrement : en production la 0.6 écrit dans le même dossier, et recrée son journal ensuite.
if [[ ${#anciens_plists[@]} -gt 0 && -d "$anciens_journaux" ]]; then
  for f in "$anciens_journaux"/*; do
    [[ -f "$f" ]] && corbeille "$f"
  done
  echo "==> Anciens journaux de ~/Library/Logs/$nom_journaux mis à la Corbeille"
fi

# --- 5. Enregistrement ------------------------------------------------------------------------
if [[ $ancien_a_arreter -eq 1 ]]; then
  for plist in "${plists_collision[@]}"; do
    launchctl bootout "gui/$(id -u)/$identifiant" > /dev/null 2>&1 || true
  done
  echo "==> Ancienne version arrêtée avant l'enregistrement (même libellé)"
fi
echo "==> Enregistrement de l'agent"
code_app=0
sortie_app="$("$destination/Contents/MacOS/macstatusd" --register 2>&1)" || code_app=$?
echo "    $sortie_app"
case "$code_app" in
  0)
    # register() ne relance pas un agent déjà actif : la mise à jour exige un kickstart.
    if [[ $agent_charge -eq 1 ]]; then
      if launchctl kickstart -k "gui/$(id -u)/$identifiant" > /dev/null 2>&1; then
        marqueur_pose=0
        echo "    agent relancé"
      else
        echo "    (kickstart de l'agent sans effet : l'ancien process continue jusqu'à la fin de la session."
        echo "     Pour appliquer la mise à jour tout de suite : launchctl kickstart -k gui/$(id -u)/$identifiant)"
      fi
    fi ;;
  3)
    echo "==> À autoriser : Réglages Système > Général > Ouverture et extensions."
    if [[ $ancien_a_arreter -eq 1 ]]; then
      echo "    Autorise macstatusd (la 0.6 démarre à l'autorisation, l'ancienne version est déjà arrêtée),"
      echo "    puis relance ce script tout de suite : la migration et la vérification se feront alors."
    else
      echo "    Autorise macstatusd, puis relance ce script tout de suite : la migration et la vérification se feront alors."
    fi
    rappel_config
    exit 0 ;;
  *)
    echo "!! L'enregistrement a échoué (code $code_app)" >&2
    if [[ $ancien_a_arreter -eq 1 ]]; then
      for plist in "${plists_collision[@]}"; do
        launchctl bootstrap "gui/$(id -u)" "$plist" > /dev/null 2>&1 || true
      done
      echo "!! L'ancienne version a été relancée." >&2
    fi
    exit 1 ;;
esac

# --- 6. Retrait de l'ancien agent ---------------------------------------------------------------
echo "==> Ancien agent de $ancien_prefixe"
if [[ ${#anciens_plists[@]} -eq 0 ]]; then
  echo "    aucun ancien agent trouvé"
else
  retires_hors_collision=0
  for plist in "${anciens_plists[@]}"; do
    libelle="$("$pb" -c "Print :Label" "$plist" 2>/dev/null)" || libelle=""
    en_collision=0
    if [[ ${#plists_collision[@]} -gt 0 ]]; then
      for p in "${plists_collision[@]}"; do
        if [[ "$p" == "$plist" ]]; then en_collision=1; fi
      done
    fi
    if [[ $en_collision -eq 1 ]]; then
      : # le libellé désigne maintenant le nouvel agent : seulement la Corbeille du plist
    elif [[ -n "$libelle" ]]; then
      launchctl bootout "gui/$(id -u)/$libelle" > /dev/null 2>&1 || true
    else
      launchctl bootout "gui/$(id -u)" "$plist" > /dev/null 2>&1 || true
    fi
    if [[ $en_collision -eq 0 ]]; then retires_hors_collision=$((retires_hors_collision + 1)); fi
    corbeille "$plist"
    echo "    ancien agent retiré (libellé de ${#libelle} caractères)"
  done
  # L'état de la 0.6 part en dernier : son écoute prend aussitôt le port libéré par l'ancien agent.
  if [[ $retires_hors_collision -gt 0 ]] && launchctl print "gui/$(id -u)/$identifiant" > /dev/null 2>&1; then
    : > "$support/restart-pending"
    marqueur_pose=1
    if launchctl kickstart -k "gui/$(id -u)/$identifiant" > /dev/null 2>&1; then
      marqueur_pose=0
      echo "    agent relancé après le retrait de l'ancien (son état part en dernier)"
    else
      echo "    (kickstart de l'agent sans effet : launchctl kickstart -k gui/$(id -u)/$identifiant)"
    fi
  fi
fi
if [[ -f "$ancien_prefixe/macstatusd" ]]; then
  echo "    Le dossier de l'ancienne installation reste en place. Pour le supprimer, lance toi-même :"
  echo "      sudo rm -rf \"$ancien_prefixe\""
fi

# --- 7. Vérification (F63) --------------------------------------------------------------------
if [[ $sans_verification -eq 1 ]]; then
  echo "==> Installé (vérification ignorée). Journal : $journal"
  rappel_config
  exit 0
fi
read -r -d '' python_hote <<'PY' || true
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
bind = cfg.get("bind_address", "")
if not isinstance(bind, str) or bind in ("", "::", "0.0.0.0"):
    hote = "127.0.0.1"
else:
    hote = "[" + bind + "]" if ":" in bind else bind
port = cfg.get("port", 9090)
if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
    port = 9090
print(hote, port)
PY
hote_port="$(python3 -c "$python_hote" "$config")"
hote="${hote_port% *}"
port="${hote_port##* }"
url="http://$hote:$port/health"
echo "==> Vérification ($url)"
for ((essai = 1; essai <= 20; essai++)); do
  if curl -fsS --max-time 1 "$url" > /dev/null 2>&1; then
    echo "    OK : macstatusd répond"
    echo "==> Installé. Journal : $journal"
    rappel_config
    exit 0
  fi
  sleep "${MACSTATUSD_VERIF_PAUSE:-0.5}"
done
echo "!! macstatusd ne répond pas sur $url" >&2
echo "   État de l'agent : \"$destination/Contents/MacOS/macstatusd\" --status-service" >&2
echo "   Journal : $journal" >&2
exit 1
