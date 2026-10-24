#!/bin/bash
# Installe la garde pre-push dans ce dépôt : règle core.hooksPath sur outils/ et
# vérifie que la liste locale des valeurs réelles existe.
#
# Usage : bash outils/installer-garde.sh
#
# La liste locale est garde.local.txt à la racine du dépôt (ignoré par git, une
# valeur par ligne), ou le fichier désigné par GARDE_LISTE (utilisé par les tests).
# Sans liste, ou sans aucune ligne utilisable (vide, ou seulement des commentaires et des
# blancs), l'installation échoue et ne règle rien : la garde refuserait de toute façon toute
# poussée.

set -eu

racine=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel) || {
  echo "installer-garde : ce script doit se trouver dans outils/, à l'intérieur d'un dépôt git" >&2
  exit 1
}

if [ -n "${GARDE_LISTE:-}" ]; then
  liste=$GARDE_LISTE
  origine="GARDE_LISTE ne désigne pas un fichier lisible"
else
  liste=$racine/garde.local.txt
  origine="garde.local.txt est absent de la racine du dépôt : crée-le (une valeur réelle par ligne : prénom, nom, e-mail personnel, adresses et noms d'hôte réels), puis relance ce script"
fi

if [ ! -f "$liste" ] || [ ! -r "$liste" ]; then
  echo "installer-garde : liste locale introuvable : $origine" >&2
  exit 1
fi

# Même nettoyage que la garde : sans retours chariot ni blancs aux extrémités, sans lignes
# vides ni commentaires. Il doit rester au moins une ligne.
if ! tr -d '\r' < "$liste" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -q -v -e '^$' -e '^#'; then
  echo "installer-garde : liste locale sans ligne utilisable : elle est vide ou ne contient que des commentaires et des blancs (une valeur réelle par ligne)" >&2
  exit 1
fi

if [ ! -f "$racine/outils/pre-push" ]; then
  echo "installer-garde : outils/pre-push est introuvable" >&2
  exit 1
fi
chmod +x "$racine/outils/pre-push"

git -C "$racine" config core.hooksPath outils
printf 'core.hooksPath = %s\n' "$(git -C "$racine" config core.hooksPath)"
