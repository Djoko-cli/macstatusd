#!/bin/bash
# Publie une version signée Developer ID et notarisée de macstatusd (plan 4, tâche 8 ; D9) : le cliquet, les tests,
# puis outils/publication.py (assemblage, signature, vérification, notarisation, agrafe, garde de l'archive).
#
# Usage : bash outils/publier.sh [--repetition] X.Y.Z
#
# Variables (exportées à publication.py) :
#   IDENTITE_SIGNATURE   « Developer ID Application » par défaut (l'identité unique du trousseau, trouvée par ce
#                        préfixe : son nom complet porte le nom légal du titulaire, il n'est écrit nulle part ici) ;
#   NOTARISER            1 par défaut ;
#   PROFIL_NOTARISATION  djoko-notarisation par défaut (le profil de notarytool store-credentials).
# Le cliquet : hors --repetition, refus si IDENTITE_SIGNATURE n'est pas « Developer ID Application » ou si
# NOTARISER n'est pas 1. Refus aussi sur un clone superficiel (le numéro de version traçable compte les commits).
# --repetition : identité com.djoko.macstatusd.repetition, produits dans build/repetition/X.Y.Z/ ; elle seule peut
# signer autrement ou ne pas notariser. Produits d'une version publiée : build/publication/X.Y.Z/
# (macstatusd-X.Y.Z.zip et SHA256SUMS). Codes de sortie : 0 réussi, 1 refus ou échec, 2 usage.

set -u

usage() {
  echo "Usage : bash outils/publier.sh [--repetition] X.Y.Z" >&2
  exit 2
}

repetition=0
version=""
for x in "$@"; do
  case "$x" in
    --repetition) repetition=1 ;;
    -*) usage ;;
    *) if [[ -n "$version" ]]; then usage; fi; version="$x" ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

cd "$(dirname "$0")/.." || exit 1

IDENTITE_SIGNATURE=${IDENTITE_SIGNATURE-Developer ID Application}
NOTARISER=${NOTARISER-1}
PROFIL_NOTARISATION=${PROFIL_NOTARISATION-djoko-notarisation}
export IDENTITE_SIGNATURE NOTARISER PROFIL_NOTARISATION

# Le cliquet du Developer ID : une version publiée n'est jamais signée autrement (un retour à une signature ad hoc
# ferait refuser l'app par Gatekeeper). La répétition seule peut signer autrement.
if [[ $repetition -eq 0 ]] && { [[ "$IDENTITE_SIGNATURE" != "Developer ID Application" ]] || [[ "$NOTARISER" != "1" ]]; }; then
  echo "publier.sh : une version publiée est signée par le Developer ID et notarisée (IDENTITE_SIGNATURE, NOTARISER)" >&2
  exit 1
fi

# Le numéro de build compte les commits : un clone superficiel en donnerait un faux.
if [[ "$(git rev-parse --is-shallow-repository 2> /dev/null)" != "false" ]]; then
  echo "publier.sh : clone superficiel (ou hors git) ; publier depuis un clone complet" >&2
  exit 1
fi

# Les tests de l'outil, dans un environnement neutre, avant toute suite.
env -i PATH=/usr/bin:/bin HOME="$HOME" python3 -m unittest discover -s outils/tests -p 'test_publication.py'
code=$?
if [[ $code -ne 0 ]]; then
  echo "publier.sh : tests en échec (code $code) ; rien n'est signé" >&2
  exit 1
fi

if [[ $repetition -eq 1 ]]; then
  exec /usr/bin/python3 outils/publication.py --repetition "$version"
fi
exec /usr/bin/python3 outils/publication.py "$version"
