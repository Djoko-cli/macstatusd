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
# Hors --repetition, refus aussi si CODESIGN, SECURITY, OPENSSL, DITTO, XCRUN, SPCTL, STRIP, DEVELOPER_DIR ou
# GARDE_LISTE est posée.
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

# Les outils s'appellent par chemin absolu, et seule la répétition peut les remplacer ou donner une autre liste de
# garde : une variable de remplacement oubliée dans un shell ne fabrique pas une « publication » avec de faux outils.
if [[ $repetition -eq 0 ]]; then
  for v in CODESIGN SECURITY OPENSSL DITTO XCRUN SPCTL STRIP DEVELOPER_DIR GARDE_LISTE; do
    if [[ -n "${!v+x}" ]]; then
      echo "publier.sh : hors --repetition, aucun outil ni liste de la garde ne se remplace ($v est posée)" >&2
      exit 1
    fi
  done
fi

# Le numéro de build compte les commits : un clone superficiel en donnerait un faux.
if [[ "$(git rev-parse --is-shallow-repository 2> /dev/null)" != "false" ]]; then
  echo "publier.sh : clone superficiel (ou hors git) ; publier depuis un clone complet" >&2
  exit 1
fi

# Les tests de l'outil, dans un environnement neutre, avant toute suite.
# Le journal est gardé dans une variable (jamais derrière un tube : le code de sortie est celui des tests).
journal=$(env -i PATH=/usr/bin:/bin HOME="$HOME" python3 -m unittest discover -s outils/tests -p 'test_publication.py' 2>&1)
code=$?
printf '%s\n' "$journal"
if [[ $code -ne 0 ]]; then
  echo "publier.sh : tests en échec (code $code) ; rien n'est signé" >&2
  exit 1
fi
# Une porte vide ne passe pas : unittest rend 0 quand il ne trouve aucun test (un fichier renommé, par exemple).
nombre=0
if [[ "$journal" =~ Ran\ ([0-9]+)\ test ]]; then
  nombre=${BASH_REMATCH[1]}
fi
if [[ $nombre -le 0 ]]; then
  echo "publier.sh : aucun test lancé (« Ran N tests » absent ou N = 0) ; rien n'est signé" >&2
  exit 1
fi

if [[ $repetition -eq 1 ]]; then
  exec /usr/bin/python3 outils/publication.py --repetition "$version"
fi
exec /usr/bin/python3 outils/publication.py "$version"
