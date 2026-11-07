#!/bin/bash
# Assemble l'app d'arrière-plan macstatusd.app (paquet, Info.plist, agent SMAppService,
# icône, informations de version) puis la signe.
#
# Usage : bash outils/assembler-app.sh [--binaire <chemin>] [--identifiant <id>]
#           [--nom-support <nom>] [--sortie <dossier>] [--icone <icns>]
#           [--signer <identité>|-]
#
# Défauts : compilation « swift build -c release » (dossier .build), identifiant
# com.djoko.macstatusd, nom de support macstatusd, sortie build/app, icône
# outils/icone/AppIcon.icns, signature ad hoc (-).
# L'app s'appelle macstatusd.app, ou macstatusd-<suffixe>.app pour l'identifiant
# com.djoko.macstatusd.<suffixe>. Le chemin de l'app est imprimé sur la dernière ligne.
# Codes de sortie : 0 réussi, 1 échec de l'assemblage, 2 usage ou entrée absente.

set -u

ici=$(cd "$(dirname "$0")" && pwd)
depot=$(cd "$ici/.." && pwd)

binaire=""
identifiant="com.djoko.macstatusd"
nom_support="macstatusd"
sortie="$depot/build/app"
icone="$ici/icone/AppIcon.icns"
signer="-"

usage() {
  echo "Usage : bash outils/assembler-app.sh [--binaire <chemin>] [--identifiant <id>] [--nom-support <nom>] [--sortie <dossier>] [--icone <icns>] [--signer <identité>|-]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binaire|--identifiant|--nom-support|--sortie|--icone|--signer)
      if [[ $# -lt 2 ]]; then echo "option sans valeur : $1" >&2; usage; exit 2; fi
      case "$1" in
        --binaire) binaire="$2" ;;
        --identifiant) identifiant="$2" ;;
        --nom-support) nom_support="$2" ;;
        --sortie) sortie="$2" ;;
        --icone) icone="$2" ;;
        --signer) signer="$2" ;;
      esac
      shift 2 ;;
    *) echo "option inconnue : $1" >&2; usage; exit 2 ;;
  esac
done

# --- Entrées -----------------------------------------------------------------
if [[ ! -f "$icone" ]]; then
  echo "icône absente : $icone (pas d'app sans icône)" >&2
  exit 2
fi

base_id="com.djoko.macstatusd"
if [[ "$identifiant" == "$base_id" ]]; then
  nom_app="macstatusd.app"
elif [[ "$identifiant" == "$base_id".* && -n "${identifiant#"$base_id".}" ]]; then
  nom_app="macstatusd-${identifiant#"$base_id".}.app"
else
  echo "identifiant inattendu : $identifiant (attendu $base_id ou $base_id.<suffixe>)" >&2
  exit 2
fi
if [[ -z "$nom_support" || "$nom_support" == */* ]]; then
  echo "nom de support invalide : « $nom_support »" >&2
  exit 2
fi

if [[ -z "$binaire" ]]; then
  echo "==> compilation (swift build -c release)"
  (cd "$depot" && swift build -c release) || { echo "la compilation a échoué" >&2; exit 1; }
  binaire="$(cd "$depot" && swift build -c release --show-bin-path)/macstatusd" || exit 1
fi
if [[ ! -x "$binaire" ]]; then
  echo "binaire absent ou non exécutable : $binaire" >&2
  exit 2
fi

# --- Version ---------------------------------------------------------------------
version=$(sed -n 's/.*macstatusdVersion *= *"\([^"]*\)".*/\1/p' "$depot/Sources/MacStatusCore/Version.swift")
version_num=$(sed -n 's/^\([0-9][0-9.]*\).*/\1/p' <<< "$version")
if [[ -z "$version" || -z "$version_num" ]]; then
  echo "version illisible dans Sources/MacStatusCore/Version.swift" >&2
  exit 1
fi
numero_build=$(git -C "$depot" rev-list --count HEAD) || { echo "git rev-list a échoué" >&2; exit 1; }
git_court=$(git -C "$depot" describe --always --dirty) || { echo "git describe a échoué" >&2; exit 1; }
date_build=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Paquet -----------------------------------------------------------------------
app="$sortie/$nom_app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/fr.lproj" \
  "$app/Contents/Library/LaunchAgents" || exit 1

cp "$binaire" "$app/Contents/MacOS/macstatusd" || exit 1
chmod 755 "$app/Contents/MacOS/macstatusd"
cp "$icone" "$app/Contents/Resources/AppIcon.icns" || exit 1
cp "$ici/app/en.lproj/InfoPlist.strings" "$app/Contents/Resources/en.lproj/InfoPlist.strings" || exit 1
cp "$ici/app/fr.lproj/InfoPlist.strings" "$app/Contents/Resources/fr.lproj/InfoPlist.strings" || exit 1

# Gabarits : les marqueurs @…@ ne contiennent ni « | » ni « & » dans leurs valeurs.
remplir() { # gabarit destination
  sed -e "s|@IDENTIFIANT@|$identifiant|g" \
      -e "s|@NOM_SUPPORT@|$nom_support|g" \
      -e "s|@VERSION_COURTE@|$version_num|g" \
      -e "s|@NUMERO_BUILD@|$numero_build|g" "$1" > "$2"
}
remplir "$ici/app/Info.plist" "$app/Contents/Info.plist" || exit 1
remplir "$ici/app/agent.plist" "$app/Contents/Library/LaunchAgents/$identifiant.plist" || exit 1
plutil -lint "$app/Contents/Info.plist" "$app/Contents/Library/LaunchAgents/$identifiant.plist" > /dev/null || { echo "plist invalide" >&2; exit 1; }

printf '{\n  "version": "%s",\n  "git": "%s",\n  "built_at": "%s"\n}\n' "$version" "$git_court" "$date_build" \
  > "$app/Contents/Resources/build-info.json"

# --- Signature --------------------------------------------------------------------
# Toute sortie de codesign passe par le masque (nom légal, équipe).
masque="$HOME/.claude/outils/masquer"
if [[ "$signer" == "-" ]]; then
  options=(--force --sign -)
else
  options=(--force --options runtime --timestamp --sign "$signer")
fi
journal_cs=$(mktemp) || exit 1
if ! codesign "${options[@]}" "$app" > "$journal_cs" 2>&1; then
  if [[ -x "$masque" ]]; then "$masque" < "$journal_cs" >&2; else echo "(sortie de codesign non affichée : masque absent)" >&2; fi
  rm -f "$journal_cs"
  echo "la signature a échoué" >&2
  exit 1
fi
rm -f "$journal_cs"

echo "$app"
