#!/bin/bash
# Banc d'essai de l'assembleur de l'app (outils/assembler-app.sh).
#
# Usage : bash outils/tests/test-assembler-app.sh
#
# Compile une fois le binaire (dossier imposé sous /private/tmp/macstatusd-plan4),
# puis assemble l'app dans /private/tmp/macstatusd-plan4/app-essai et relit son
# contenu. Rien n'est installé, rien n'est enregistré. Variable facultative :
# BINAIRE_ESSAI=<chemin> évite la compilation. Code de sortie : 0 si tous les cas
# passent, 1 sinon.

set -u

ici=$(cd "$(dirname "$0")" && pwd)
depot=$(cd "$ici/../.." && pwd)
assembleur="$depot/outils/assembler-app.sh"
racine="/private/tmp/macstatusd-plan4"
sortie_essai="$racine/app-essai"
pb=/usr/libexec/PlistBuddy

echec=0
ok() { echo "OK    $1"; }
ko() { echo "ÉCHEC $1 : $2"; echec=1; }

# --- Préparation : binaire et dossier de sortie --------------------------------
rm -rf "$sortie_essai"
mkdir -p "$sortie_essai"

binaire="${BINAIRE_ESSAI:-}"
if [[ -z "$binaire" ]]; then
  echo "==> compilation (une fois) vers $racine/build"
  (cd "$depot" && swift build -c release --scratch-path "$racine/build") > "$sortie_essai/compilation.log" 2>&1
  code=$?
  if [[ $code -ne 0 ]]; then
    tail -n 20 "$sortie_essai/compilation.log"
    echo "ÉCHEC préparation : la compilation a rendu $code" >&2
    exit 1
  fi
  bin_dir=$(cd "$depot" && swift build -c release --scratch-path "$racine/build" --show-bin-path)
  binaire="$bin_dir/macstatusd"
fi
[[ -x "$binaire" ]] || { echo "ÉCHEC préparation : binaire introuvable : $binaire" >&2; exit 1; }

# Valeur d'une clé de plist (vide si absente).
cle() { "$pb" -c "Print :$2" "$1" 2>/dev/null; }

# Vérifie qu'une clé vaut la valeur attendue.
verifier_cle() { # cas fichier clé attendu
  local valeur
  valeur=$(cle "$2" "$3")
  if [[ "$valeur" == "$4" ]]; then ok "$1 : $3 = $4"; else ko "$1" "$3 vaut « $valeur » au lieu de « $4 »"; fi
}

# Textes validés de l'autorisation du réseau local.
texte_en="macstatusd talks to Home Assistant on your local network so that HomeKit knows whether the Mac is in use."
texte_fr="macstatusd échange avec Home Assistant sur votre réseau local, pour que HomeKit sache si le Mac est utilisé."

# --- Cas 1 : défauts -----------------------------------------------------------
cas=defauts
dossier="$sortie_essai/defauts"
journal="$sortie_essai/defauts.log"
bash "$assembleur" --binaire "$binaire" --sortie "$dossier" > "$journal" 2>&1
code=$?
if [[ $code -ne 0 ]]; then
  ko "$cas" "l'assembleur a rendu $code ; dernière ligne : $(tail -n 1 "$journal")"
else
  app=$(tail -n 1 "$journal")
  version=$(sed -n 's/.*macstatusdVersion = "\([0-9.]*\).*/\1/p' "$depot/Sources/MacStatusCore/Version.swift")
  if [[ "$app" != "$dossier/macstatusd.app" ]]; then ko "$cas" "chemin imprimé inattendu : $app"; fi
  info="$app/Contents/Info.plist"
  verifier_cle $cas "$info" CFBundleIdentifier com.djoko.macstatusd
  verifier_cle $cas "$info" CFBundleName macstatusd
  verifier_cle $cas "$info" CFBundleExecutable macstatusd
  verifier_cle $cas "$info" CFBundlePackageType APPL
  verifier_cle $cas "$info" CFBundleShortVersionString "$version"
  verifier_cle $cas "$info" CFBundleVersion "$(git -C "$depot" rev-list --count HEAD)"
  verifier_cle $cas "$info" LSMinimumSystemVersion 13.0
  verifier_cle $cas "$info" LSUIElement true
  verifier_cle $cas "$info" CFBundleIconFile AppIcon
  verifier_cle $cas "$info" CFBundleDevelopmentRegion en
  verifier_cle $cas "$info" CFBundleLocalizations:0 en
  verifier_cle $cas "$info" CFBundleLocalizations:1 fr
  verifier_cle $cas "$info" MacstatusdSupportName macstatusd
  verifier_cle $cas "$info" NSLocalNetworkUsageDescription "$texte_en"
  for langue in en fr; do
    strings="$app/Contents/Resources/$langue.lproj/InfoPlist.strings"
    if [[ -s "$strings" ]]; then
      ok "$cas : $langue.lproj/InfoPlist.strings"
      attendu="$texte_en"; [[ "$langue" == fr ]] && attendu="$texte_fr"
      lu=$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$strings" 2>/dev/null)
      if [[ "$lu" == "$attendu" ]]; then ok "$cas : $langue.lproj texte du réseau local"; else ko "$cas" "$langue.lproj : texte du réseau local « $lu » au lieu de « $attendu »"; fi
    else
      ko "$cas" "$langue.lproj/InfoPlist.strings absent"
    fi
  done
  [[ -s "$app/Contents/Resources/AppIcon.icns" ]] && ok "$cas : AppIcon.icns" || ko "$cas" "AppIcon.icns absent"
  [[ -x "$app/Contents/MacOS/macstatusd" ]] && ok "$cas : exécutable" || ko "$cas" "Contents/MacOS/macstatusd absent"

  agent="$app/Contents/Library/LaunchAgents/com.djoko.macstatusd.plist"
  if [[ -f "$agent" ]]; then
    verifier_cle $cas "$agent" Label com.djoko.macstatusd
    verifier_cle $cas "$agent" BundleProgram Contents/MacOS/macstatusd
    verifier_cle $cas "$agent" ProgramArguments:0 macstatusd
    verifier_cle $cas "$agent" ProgramArguments:1 --agent
    verifier_cle $cas "$agent" RunAtLoad true
    verifier_cle $cas "$agent" KeepAlive true
    verifier_cle $cas "$agent" ThrottleInterval 5
    verifier_cle $cas "$agent" ExitTimeOut 5
    verifier_cle $cas "$agent" ProcessType Interactive
    verifier_cle $cas "$agent" LimitLoadToSessionType Aqua
    if [[ -z "$(cle "$agent" StandardOutPath)" ]]; then ok "$cas : pas de StandardOutPath"; else ko "$cas" "StandardOutPath présent"; fi
  else
    ko "$cas" "plist de l'agent absent : $agent"
  fi

  bi="$app/Contents/Resources/build-info.json"
  if python3 -m json.tool "$bi" > /dev/null 2>&1; then
    ok "$cas : build-info.json lisible"
    for k in version git built_at; do
      v=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$bi" "$k")
      [[ -n "$v" ]] && ok "$cas : build-info $k" || ko "$cas" "build-info : clé $k vide"
    done
  else
    ko "$cas" "build-info.json illisible ou absent"
  fi

  sortie_cs=$(codesign --verify --strict "$app" 2>&1 | ~/.claude/outils/masquer)
  if codesign --verify --strict "$app" > /dev/null 2>&1; then ok "$cas : codesign --verify --strict"; else ko "$cas" "codesign : $sortie_cs"; fi
fi

# --- Cas 2 : identité d'essai ----------------------------------------------------
cas=identite-essai
dossier="$sortie_essai/essai"
journal="$sortie_essai/essai.log"
icone_essai="$sortie_essai/icone-essai.icns"
if [[ -s "$depot/outils/icone/AppIcon.icns" ]]; then cp "$depot/outils/icone/AppIcon.icns" "$icone_essai"; else printf 'icns' > "$icone_essai"; fi
bash "$assembleur" --binaire "$binaire" --icone "$icone_essai" --sortie "$dossier" \
  --identifiant com.djoko.macstatusd.essai --nom-support macstatusd-essai > "$journal" 2>&1
code=$?
if [[ $code -ne 0 ]]; then
  ko "$cas" "l'assembleur a rendu $code ; dernière ligne : $(tail -n 1 "$journal")"
else
  app=$(tail -n 1 "$journal")
  if [[ "$app" == "$dossier/macstatusd-essai.app" && -d "$app" ]]; then ok "$cas : macstatusd-essai.app"; else ko "$cas" "app attendue $dossier/macstatusd-essai.app, obtenu : $app"; fi
  agent="$app/Contents/Library/LaunchAgents/com.djoko.macstatusd.essai.plist"
  if [[ -f "$agent" ]]; then
    ok "$cas : plist com.djoko.macstatusd.essai.plist"
    verifier_cle $cas "$agent" Label com.djoko.macstatusd.essai
  else
    ko "$cas" "plist de l'agent absent : $agent"
  fi
  verifier_cle $cas "$app/Contents/Info.plist" MacstatusdSupportName macstatusd-essai
  verifier_cle $cas "$app/Contents/Info.plist" CFBundleIdentifier com.djoko.macstatusd.essai
fi

# --- Cas 3 : icône absente (piège) ---------------------------------------------------
cas=icone-absente
dossier="$sortie_essai/sans-icone"
journal="$sortie_essai/sans-icone.log"
absente="$sortie_essai/n-existe-pas.icns"
bash "$assembleur" --binaire "$binaire" --icone "$absente" --sortie "$dossier" > "$journal" 2>&1
code=$?
raison="icône absente : $absente (pas d'app sans icône)"
if [[ $code -eq 2 ]]; then ok "$cas : code 2"; else ko "$cas" "code $code au lieu de 2"; fi
if /usr/bin/grep -q -F -- "$raison" "$journal"; then ok "$cas : raison affichée"; else ko "$cas" "raison attendue « $raison », obtenu : $(tail -n 1 "$journal")"; fi
if [[ -d "$dossier/macstatusd.app" ]]; then ko "$cas" "une app a été produite malgré l'icône absente"; else ok "$cas : aucune app produite"; fi

# --- Cas 4 : sortie par défaut hors de ~/Documents (HOME d'essai pour l'assembleur seul) ---
cas=sortie-par-defaut
journal="$sortie_essai/defaut-sortie.log"
home_essai="$sortie_essai/home-essai"
attendu_app="$home_essai/Library/Caches/macstatusd-build/app/macstatusd.app"
HOME="$home_essai" bash "$assembleur" --binaire "$binaire" > "$journal" 2>&1
code=$?
if [[ $code -eq 0 ]]; then ok "$cas : code 0"; else ko "$cas" "code $code ; dernière ligne : $(tail -n 1 "$journal")"; fi
app=$(tail -n 1 "$journal")
if [[ "$app" == "$attendu_app" ]]; then ok "$cas : chemin imprimé sous Library/Caches"; else ko "$cas" "chemin imprimé « $app » au lieu de « $attendu_app »"; fi
if [[ -d "$attendu_app" ]]; then
  ok "$cas : app présente"
  sortie_cs=$(codesign --verify --strict "$attendu_app" 2>&1 | ~/.claude/outils/masquer)
  if codesign --verify --strict "$attendu_app" > /dev/null 2>&1; then ok "$cas : codesign --verify --strict"; else ko "$cas" "codesign : $sortie_cs"; fi
else
  ko "$cas" "app absente : $attendu_app"
fi
if [[ -e "$depot/build" ]]; then ko "$cas" "$depot/build existe (la sortie par défaut ne doit plus y aller)"; else ok "$cas : pas de build/ dans le dépôt"; fi

echo
if [[ $echec -eq 0 ]]; then echo "Banc de l'assembleur : tout passe."; else echo "Banc de l'assembleur : des cas échouent."; fi
exit $echec
