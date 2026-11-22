#!/bin/bash
# Installe la garde pre-push dans ce dépôt : copie outils/pre-push dans le dossier des
# crochets du dossier git commun (<dossier git commun>/hooks/pre-push), après avoir vérifié
# que la liste locale des valeurs réelles existe.
#
# Usage : bash outils/installer-garde.sh
#
# Toutes les copies de travail du dépôt partagent le dossier git commun, et aucune extraction
# ne le modifie : une branche ou une copie de travail antérieure à la garde (sans
# outils/pre-push) la déclenche quand même. Les versions précédentes de ce script réglaient
# core.hooksPath=outils, un chemin relatif que git résout dans l'arbre de travail : là où
# outils/pre-push manquait, git sautait la garde sans rien dire. Ce réglage est retiré ; tout
# autre core.hooksPath arrête l'installation, comme un autre crochet pre-push déjà en place.
#
# La garde installée est une copie : après un changement de outils/pre-push, relancer ce
# script.
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

# Un core.hooksPath, quelle que soit sa portée, détournerait git du dossier git commun. Seul
# l'ancien réglage de ce script (local, outils) est retiré, après la copie.
reglages=$(git -C "$racine" config --show-scope --get-all core.hooksPath || true)
if [ -n "$reglages" ] && [ "$reglages" != "$(printf 'local\toutils')" ]; then
  echo "installer-garde : core.hooksPath est réglé ($(printf '%s' "$reglages" | tr '\t\n' '=,')) : git y chercherait la garde au lieu du dossier git commun ; retire ce réglage (git config --unset core.hooksPath, avec --global ou --system selon sa portée), puis relance ce script" >&2
  exit 1
fi

crochets=$(git -C "$racine" rev-parse --path-format=absolute --git-common-dir)/hooks
garde=$crochets/pre-push
# Une copie précédente de la garde se reconnaît à ses messages ; tout autre crochet est laissé.
if [ -L "$garde" ] || { [ -e "$garde" ] && ! grep -q -F 'garde pre-push :' "$garde"; }; then
  echo "installer-garde : un autre crochet pre-push existe déjà : $garde ; déplace-le (vers $garde.autre, par exemple), puis relance ce script" >&2
  exit 1
fi

mkdir -p "$crochets"
cp "$racine/outils/pre-push" "$garde"
chmod +x "$garde"
if [ -n "$reglages" ]; then
  git -C "$racine" config --local --unset core.hooksPath
fi

effectif=$(git -C "$racine" rev-parse --path-format=absolute --git-path hooks/pre-push)
if [ ! "$effectif" -ef "$garde" ]; then
  echo "installer-garde : git cherche la garde dans $effectif, et non dans $garde" >&2
  exit 1
fi
printf 'garde installée : %s\n' "$garde"
