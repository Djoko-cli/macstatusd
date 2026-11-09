#!/bin/bash
# Banc du cliquet de publication (outils/publier.sh).
#
# Usage : bash outils/tests/test-publier.sh
#
# Le script copie outils/publier.sh dans un petit dépôt d'essai, sous /private/tmp/macstatusd-plan4/, où les tests
# et publication.py sont remplacés par des bouchons qui notent seulement qu'ils ont été lancés. Aucun vrai outil de
# signature n'est appelé, rien n'est signé, rien n'est envoyé : le banc tourne avec un HOME d'essai, et de faux
# codesign, security, xcrun, spctl, ditto et openssl en tête du PATH, qui notent « vrai outil appelé » (le banc échoue
# s'il en trouve une trace). Cas : refus pour IDENTITE_SIGNATURE=-, pour NOTARISER=0 sans --repetition, pour une
# variable de remplacement d'outil ou de liste hors --repetition, pour un clone superficiel, pour des tests en échec,
# pour une porte des tests vide ; acceptation de --repetition jusqu'aux tests ; exportations par défaut.
# Code de sortie : 0 si tous les cas passent, 1 sinon.

set -u

ici=$(cd "$(dirname "$0")" && pwd)
depot=$(cd "$ici/../.." && pwd)
racine="/private/tmp/macstatusd-plan4/banc-publier"

rm -rf "$racine"
mkdir -p "$racine" || { echo "ÉCHEC préparation : $racine" >&2; exit 1; }

# --- Le HOME d'essai, et les faux outils de signature en tête du PATH ----------------------------------------------
home_essai="$racine/home"
faux_outils="$racine/faux-outils"
marqueur_outils="$racine/vrai-outil-appele.txt"
mkdir -p "$home_essai" "$faux_outils" || { echo "ÉCHEC préparation : HOME d'essai" >&2; exit 1; }
for outil in codesign security xcrun spctl ditto openssl; do
  cat > "$faux_outils/$outil" <<FIN_FAUX
#!/bin/bash
echo "vrai outil appelé : $outil \$*" >> "$marqueur_outils"
exit 1
FIN_FAUX
  chmod +x "$faux_outils/$outil"
done

echec=0
ok() { echo "OK    $1"; }
ko() { echo "ÉCHEC $1 : $2"; echec=1; }

# --- Le dépôt d'essai : publier.sh réel, tests et publication.py en bouchons --------------------------------------
source_essai="$racine/source"
mkdir -p "$source_essai/outils/tests"
cp "$depot/outils/publier.sh" "$source_essai/outils/publier.sh" || { echo "ÉCHEC préparation : publier.sh absent" >&2; exit 1; }

cat > "$source_essai/outils/publication.py" <<'EOF'
import os, sys
with open('.marqueur-publication', 'w') as f:
    f.write('args=%s\n' % ' '.join(sys.argv[1:]))
    for k in ('IDENTITE_SIGNATURE', 'NOTARISER', 'PROFIL_NOTARISATION'):
        f.write('%s=%s\n' % (k, os.environ.get(k, '<absent>')))
EOF

# Les tests réussissent ; la variante ci-dessous échoue (le fichier est remplacé dans la copie du cas).
cat > "$source_essai/outils/tests/test_publication.py" <<'EOF'
import unittest
class Bouchon(unittest.TestCase):
    def test_bouchon(self):
        with open('.marqueur-tests', 'w') as f:
            f.write('lancés\n')
EOF

git -C "$source_essai" init -q -b main || { echo "ÉCHEC préparation : git init" >&2; exit 1; }
git -C "$source_essai" add -A
git -C "$source_essai" -c user.name=Essai -c user.email=1+essai@users.noreply.github.com -c commit.gpgsign=false \
  commit -q -m "premier" || { echo "ÉCHEC préparation : commit" >&2; exit 1; }
git -C "$source_essai" -c user.name=Essai -c user.email=1+essai@users.noreply.github.com -c commit.gpgsign=false \
  commit -q --allow-empty -m "second" || { echo "ÉCHEC préparation : second commit" >&2; exit 1; }

complet="$racine/complet"
superficiel="$racine/superficiel"
git clone -q "file://$source_essai" "$complet" || { echo "ÉCHEC préparation : clone complet" >&2; exit 1; }
git clone -q --depth 1 "file://$source_essai" "$superficiel" || { echo "ÉCHEC préparation : clone superficiel" >&2; exit 1; }
[[ "$(git -C "$superficiel" rev-parse --is-shallow-repository)" == "true" ]] \
  || { echo "ÉCHEC préparation : le clone n'est pas superficiel" >&2; exit 1; }

sortie="$racine/sortie.txt"

# Lance publier.sh dans le clone $1 avec les variables $2 (liste « NOM=valeur » séparée par des espaces, ou « - »),
# puis les arguments suivants. Efface les marqueurs avant. Le code de sortie est mis dans $code.
lancer() {
  local clone=$1 vars=$2
  shift 2
  rm -f "$clone/.marqueur-tests" "$clone/.marqueur-publication"
  local -a env_cas=()
  if [[ "$vars" != "-" ]]; then
    read -r -a env_cas <<< "$vars"
  fi
  env -u IDENTITE_SIGNATURE -u NOTARISER -u PROFIL_NOTARISATION -u CODESIGN -u SECURITY -u OPENSSL -u DITTO -u XCRUN \
    -u SPCTL -u STRIP -u DEVELOPER_DIR -u GARDE_LISTE HOME="$home_essai" PATH="$faux_outils:$PATH" "${env_cas[@]+"${env_cas[@]}"}" bash "$clone/outils/publier.sh" "$@" > "$sortie" 2>&1
  code=$?
}

# Le cas est un refus : code $code_attendu (1 ; 2 pour un usage erroné), message contenant $motif, ni tests ni
# publication lancés.
code_attendu=1
refus() { # nom clone vars motif args...
  local nom=$1 clone=$2 vars=$3 motif=$4
  shift 4
  lancer "$clone" "$vars" "$@"
  if [[ $code -ne $code_attendu ]]; then ko "$nom" "code $code au lieu de $code_attendu"; return; fi
  if ! /usr/bin/grep -q -F -- "$motif" "$sortie"; then ko "$nom" "message sans « $motif »"; return; fi
  if [[ -e "$clone/.marqueur-tests" || -e "$clone/.marqueur-publication" ]]; then ko "$nom" "tests ou publication lancés malgré le refus"; return; fi
  ok "$nom"
}

# Le piège lui-même : un faux outil lancé laisse son marqueur (sinon l'alarme finale ne prouverait rien).
PATH="$faux_outils:$PATH" codesign --version > /dev/null 2>&1
if [[ -s "$marqueur_outils" ]]; then
  ok "le faux outil laisse bien son marqueur (l'alarme fonctionne)"
  rm -f "$marqueur_outils"
else
  ko "alarme des faux outils" "un faux codesign en tête du PATH n'a laissé aucun marqueur"
fi

# --- Les refus du cliquet ---------------------------------------------------------------------------------------
refus "cliquet : IDENTITE_SIGNATURE=- refusée" "$complet" "IDENTITE_SIGNATURE=-" "Developer ID" 0.6.0
refus "cliquet : IDENTITE_SIGNATURE autre refusée" "$complet" "IDENTITE_SIGNATURE=Autre" "Developer ID" 0.6.0
refus "cliquet : NOTARISER=0 sans --repetition refusé" "$complet" "NOTARISER=0" "notarisée" 0.6.0
refus "cliquet : NOTARISER vide sans --repetition refusé" "$complet" "NOTARISER=" "notarisée" 0.6.0
refus "clone superficiel refusé" "$superficiel" "-" "superficiel" 0.6.0
for nom in CODESIGN SECURITY OPENSSL DITTO XCRUN SPCTL STRIP DEVELOPER_DIR GARDE_LISTE; do
  refus "remplacement : $nom posée sans --repetition refusée" "$complet" "$nom=/usr/bin/true" "$nom" 0.6.0
done
code_attendu=2
refus "version absente refusée" "$complet" "-" "Usage"
refus "version mal formée refusée" "$complet" "-" "Usage" 0.6
refus "option inconnue refusée" "$complet" "-" "Usage" --force 0.6.0
code_attendu=1

# --- Les tests en échec arrêtent tout ---------------------------------------------------------------------------
cp "$complet/outils/tests/test_publication.py" "$racine/test_publication.ok"
cat > "$complet/outils/tests/test_publication.py" <<'EOF'
import unittest
class Echec(unittest.TestCase):
    def test_echec(self):
        with open('.marqueur-tests', 'w') as f:
            f.write('lancés\n')
        self.fail('échec voulu')
EOF
lancer "$complet" "-" 0.6.0
if [[ $code -eq 1 ]] && [[ -e "$complet/.marqueur-tests" ]] && [[ ! -e "$complet/.marqueur-publication" ]] \
  && /usr/bin/grep -q -F "tests en échec" "$sortie"; then
  ok "tests en échec : publication.py non lancé"
else
  ko "tests en échec" "code $code, marqueur tests $([[ -e "$complet/.marqueur-tests" ]] && echo oui || echo non), publication $([[ -e "$complet/.marqueur-publication" ]] && echo lancée || echo non lancée)"
fi
cp "$racine/test_publication.ok" "$complet/outils/tests/test_publication.py"

# --- Une porte des tests vide ne passe pas ------------------------------------------------------------------------
cat > "$complet/outils/tests/test_publication.py" <<'FIN_VIDE'
import unittest
FIN_VIDE
lancer "$complet" "-" 0.6.0
if [[ $code -eq 1 ]] && [[ ! -e "$complet/.marqueur-publication" ]] \
  && /usr/bin/grep -q -E "aucun test lancé|tests en échec" "$sortie"; then
  ok "porte des tests vide (Ran 0 tests) : publication.py non lancé"
else
  ko "porte des tests vide" "code $code, publication $([[ -e "$complet/.marqueur-publication" ]] && echo lancée || echo non lancée)"
fi
cp "$racine/test_publication.ok" "$complet/outils/tests/test_publication.py"

# --- Les acceptations ---------------------------------------------------------------------------------------------
# Par défaut : exportations, tests, puis publication.py avec la version.
lancer "$complet" "-" 0.6.0
if [[ $code -eq 0 ]] && [[ -e "$complet/.marqueur-tests" ]] && [[ -e "$complet/.marqueur-publication" ]]; then
  attendu=$'args=0.6.0\nIDENTITE_SIGNATURE=Developer ID Application\nNOTARISER=1\nPROFIL_NOTARISATION=djoko-notarisation'
  if [[ "$(cat "$complet/.marqueur-publication")" == "$attendu" ]]; then
    ok "défauts : Developer ID, NOTARISER=1, profil djoko-notarisation exportés"
  else
    ko "défauts" "marqueur inattendu : $(tr '\n' '|' < "$complet/.marqueur-publication")"
  fi
else
  ko "défauts" "code $code (sortie : $(tail -n 3 "$sortie" | tr '\n' '|'))"
fi

# --repetition : accepté avec une autre identité et sans notarisation, jusqu'aux tests, puis passé à publication.py.
lancer "$complet" "IDENTITE_SIGNATURE=- NOTARISER=0" --repetition 0.6.0
if [[ $code -eq 0 ]] && [[ -e "$complet/.marqueur-tests" ]] && [[ -e "$complet/.marqueur-publication" ]] \
  && [[ "$(head -n 1 "$complet/.marqueur-publication")" == "args=--repetition 0.6.0" ]] \
  && /usr/bin/grep -q -F "NOTARISER=0" "$complet/.marqueur-publication"; then
  ok "--repetition accepté (IDENTITE_SIGNATURE=-, NOTARISER=0) jusqu'aux tests"
else
  ko "--repetition" "code $code (sortie : $(tail -n 3 "$sortie" | tr '\n' '|'))"
fi

# --repetition : les variables de remplacement sont admises (elles sont réservées à la répétition).
lancer "$complet" "IDENTITE_SIGNATURE=- NOTARISER=0 XCRUN=/usr/bin/true GARDE_LISTE=/essai/liste" --repetition 0.6.0
if [[ $code -eq 0 ]] && [[ -e "$complet/.marqueur-publication" ]]; then
  ok "--repetition accepté avec des variables de remplacement"
else
  ko "--repetition avec remplacements" "code $code (sortie : $(tail -n 3 "$sortie" | tr '\n' '|'))"
fi

# --repetition accepté aussi dans l'autre ordre, et sur un clone superficiel il reste refusé.
lancer "$complet" "-" 0.6.0 --repetition
if [[ $code -eq 0 ]] && [[ "$(head -n 1 "$complet/.marqueur-publication")" == "args=--repetition 0.6.0" ]]; then
  ok "--repetition après la version accepté"
else
  ko "--repetition après la version" "code $code"
fi
refus "clone superficiel refusé aussi en répétition" "$superficiel" "-" "superficiel" --repetition 0.6.0

# --- Les tests de publier.sh tournent dans l'environnement neutre ---------------------------------------------------
if /usr/bin/grep -q -F "env -i PATH=/usr/bin:/bin" "$depot/outils/publier.sh"; then
  ok "les tests sont lancés dans l'environnement neutre (env -i)"
else
  ko "environnement neutre" "« env -i PATH=/usr/bin:/bin » absent de publier.sh"
fi

# L'alarme : aucun vrai outil de signature n'a été appelé pendant tout le banc.
if [[ -s "$marqueur_outils" ]]; then
  ko "vrai outil appelé" "$(tr '\n' '|' < "$marqueur_outils")"
else
  ok "aucun vrai outil de signature appelé pendant le banc"
fi

if [[ $echec -eq 0 ]]; then
  echo "Tous les cas du banc de publier.sh passent."
  rm -rf "$racine"
fi
exit "$echec"
