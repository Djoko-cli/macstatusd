#!/bin/bash
# Banc d'essai de la garde pre-push (outils/pre-push).
#
# Usage : bash outils/tests/test-garde.sh
#
# Le script crée, dans un dossier temporaire, un dépôt nu « distant » et un clone
# où la garde est installée avec une liste d'essai. Il enchaîne ensuite des
# poussées valides et des poussées qui doivent être refusées. Il ne touche jamais
# au vrai dépôt. Code de sortie : 0 si tous les cas passent, 1 sinon.
#
# IMPORTANT : les valeurs « interdites » plantées par les cas ne figurent jamais en
# clair ici. Elles sont assemblées à l'exécution, à partir de morceaux, sinon la
# garde refuserait de publier ce script lui-même (cas « propre-script »).

set -u

ici=$(cd "$(dirname "$0")" && pwd)
outils=$(dirname "$ici")

tmp=$(mktemp -d) || { echo "ÉCHEC préparation : mktemp -d a échoué" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# --- Valeurs plantées (assemblées à l'exécution) -----------------------------
prenom="Prenom""-Essai"
ip_privee="192.""168.$((3+4)).9"
chemin_perso="/Us""ers/Essai"
courriel="essai""@""example"".com"
identite_noreply="1+Essai@users.noreply.github.com"

distant="$tmp/distant.git"
clone="$tmp/clone"
liste="$tmp/liste-essai.txt"
sorties_refus="$tmp/sorties-refus.txt"
sortie="$tmp/sortie.txt"
: > "$sorties_refus"

nb_ok=0
nb_echec=0

verdict() { # $1 nom du cas, $2 code (0 = réussi), $3 détail en cas d'échec
  if [ "$2" -eq 0 ]; then
    echo "OK      $1"
    nb_ok=$((nb_ok + 1))
  else
    echo "ÉCHEC   $1 : $3"
    nb_echec=$((nb_echec + 1))
  fi
}

git_c() { git -C "$clone" "$@"; }

etat_distant() { git --git-dir="$distant" for-each-ref --format='%(refname) %(objectname)'; }

# Pousse vers le distant ; la sortie complète (y compris celle de la garde) va dans $sortie.
pousser() { git_c push -q origin "$@" > "$sortie" 2>&1; }

attendre_acceptee() { # $1 nom du cas, puis les arguments de git push
  local nom=$1
  shift
  if pousser "$@"; then
    verdict "$nom" 0
  else
    verdict "$nom" 1 "poussée refusée à tort : $(tr '\n' ' ' < "$sortie")"
  fi
}

attendre_refusee() { # $1 nom du cas, $2 fragment attendu dans le message, puis les arguments de git push
  local nom=$1 attendu=$2 avant apres
  shift 2
  avant=$(etat_distant)
  if pousser "$@"; then
    verdict "$nom" 1 "poussée acceptée à tort"
    return
  fi
  apres=$(etat_distant)
  if [ "$avant" != "$apres" ]; then
    verdict "$nom" 1 "poussée refusée mais le distant a changé"
  elif ! grep -q -F -- "$attendu" "$sortie"; then
    verdict "$nom" 1 "refusée sans le message attendu « $attendu » : $(tr '\n' ' ' < "$sortie")"
  else
    cat "$sortie" >> "$sorties_refus"
    verdict "$nom" 0
  fi
}

# Copie la garde et ses scripts dans le clone (identiques aux fichiers du dépôt courant).
copier_outils() {
  mkdir -p "$clone/outils/tests"
  cp "$outils/pre-push" "$outils/installer-garde.sh" "$clone/outils/"
  cp "$ici/test-garde.sh" "$clone/outils/tests/"
}

# Remet le clone sur l'état publié. La garde est recopiée ensuite : si le cas « propre-script »
# échoue, le retour à l'état publié l'effacerait, et les cas suivants deviendraient illisibles.
repartir() {
  git_c checkout -q -f main
  git_c reset -q --hard origin/main
  git_c branch -q -D essai 2> /dev/null || true
  git_c clean -fdq -e outils
  copier_outils
}

commiter() { # $1 message, puis les chemins à ajouter
  local message=$1
  shift
  git_c add -- "$@"
  git_c commit -q -m "$message"
}

# --- Préparation --------------------------------------------------------------
if [ ! -f "$outils/pre-push" ] || [ ! -f "$outils/installer-garde.sh" ]; then
  echo "ÉCHEC préparation : outils/pre-push ou outils/installer-garde.sh introuvable" >&2
  exit 1
fi

git init -q --bare -b main "$distant" || { echo "ÉCHEC préparation : dépôt distant" >&2; exit 1; }
git clone -q "$distant" "$clone" 2> /dev/null || { echo "ÉCHEC préparation : clone" >&2; exit 1; }
git_c symbolic-ref HEAD refs/heads/main
git_c config user.name "Essai"
git_c config user.email "$identite_noreply"
git_c config commit.gpgsign false
git_c config tag.gpgsign false

# La liste d'essai : un commentaire, une ligne vide (elles doivent être ignorées) et la valeur.
printf '# liste d'\''essai\n\n%s\n' "$prenom" > "$liste"
export GARDE_LISTE="$liste"

# Les outils sont copiés dans le clone mais restent non suivis jusqu'au cas « propre-script ».
copier_outils
if ! (cd "$clone" && bash outils/installer-garde.sh > "$tmp/installation.txt" 2>&1); then
  echo "ÉCHEC préparation : l'installation de la garde a échoué" >&2
  cat "$tmp/installation.txt" >&2
  exit 1
fi

# --- Cas ----------------------------------------------------------------------

# propre : un commit sans rien d'interdit est publié (la liste contient une ligne vide et un
# commentaire : si l'un d'eux était pris pour un motif, tout serait refusé).
printf 'contenu propre\n' > "$clone/README.txt"
commiter "Commit propre" README.txt
attendre_acceptee "propre" main

# propre-script : le commit qui ajoute outils/ (donc la garde et ce script) est accepté.
commiter "Ajout des outils" outils
attendre_acceptee "propre-script" main

# liste-ajout-retrait : la valeur est ajoutée au commit 1 et retirée au commit 2 ; le commit
# intermédiaire est publié, donc la poussée est refusée.
repartir
printf 'ligne avec %s\n' "$prenom" > "$clone/a.txt"
commiter "Ajout" a.txt
git_c rm -q a.txt
git_c commit -q -m "Retrait"
attendre_refusee "liste-ajout-retrait" "liste locale" main

# liste-message : la valeur est dans le message du commit, le contenu est propre.
repartir
printf 'contenu propre 2\n' > "$clone/b.txt"
commiter "Commit qui cite $prenom" b.txt
attendre_refusee "liste-message" "liste locale" main

# liste-binaire : la valeur est au milieu d'octets nuls dans un fichier binaire.
repartir
printf '\0\0%s\0\0' "$prenom" > "$clone/b.bin"
commiter "Ajout d'un binaire" b.bin
attendre_refusee "liste-binaire" "liste locale" main

# arbre-seul (témoin) : la valeur n'existe que dans l'arbre de travail (fichier non suivi et
# modification non indexée) ; le commit publié est propre, donc la poussée est acceptée.
repartir
printf 'contenu propre 3\n' >> "$clone/README.txt"
commiter "Commit propre sans la valeur" README.txt
printf 'secret local %s\n' "$prenom" > "$clone/local.txt"
printf 'modification non commitée %s\n' "$prenom" >> "$clone/README.txt"
attendre_acceptee "arbre-seul" main

# ip-privee : une IPv4 de la plage privée « 192.168 » est ajoutée.
repartir
printf 'serveur %s\n' "$ip_privee" > "$clone/c.txt"
commiter "Ajout d'une adresse privée" c.txt
attendre_refusee "ip-privee" "IPv4 privée" main

# ip-doc (témoin) : les trois plages de documentation sont acceptées, y compris dans une URL à
# identifiants (utilisateur:mot-de-passe@hôte), qui ne doit pas passer pour une adresse e-mail.
repartir
printf 'serveurs 192.0.2.10 198.51.100.7 203.0.113.5\nurl http://u:secret@192.0.2.10:8123/x\n' > "$clone/d.txt"
commiter "Ajout d'adresses de documentation" d.txt
attendre_acceptee "ip-doc" main

# chemin : un chemin personnel est ajouté.
repartir
printf 'dossier %s/projet\n' "$chemin_perso" > "$clone/e.txt"
commiter "Ajout d'un chemin" e.txt
attendre_refusee "chemin" "chemin personnel" main

# email : une adresse e-mail qui n'est pas une adresse noreply est ajoutée.
repartir
printf 'contact %s\n' "$courriel" > "$clone/f.txt"
commiter "Ajout d'une adresse" f.txt
attendre_refusee "email" "e-mail" main

# auteur : contenu propre, mais l'e-mail de l'auteur n'est pas une adresse noreply.
repartir
printf 'contenu propre 4\n' > "$clone/g.txt"
git_c add -- g.txt
env GIT_AUTHOR_EMAIL="$courriel" git -C "$clone" commit -q -m "Commit à l'auteur inattendu"
attendre_refusee "auteur" "e-mail d'auteur" main

# committer : contenu propre, mais l'e-mail du committer n'est pas une adresse noreply.
repartir
printf 'contenu propre 5\n' > "$clone/h.txt"
git_c add -- h.txt
env GIT_COMMITTER_EMAIL="$courriel" git -C "$clone" commit -q -m "Commit au committer inattendu"
attendre_refusee "committer" "e-mail de committer" main

# autre-branche : la violation est sur la branche « essai », qui est poussée seule (branche
# nouvelle : la garde contrôle les commits que le distant n'a pas encore).
repartir
git_c checkout -q -b essai
printf 'ligne avec %s\n' "$prenom" > "$clone/i.txt"
commiter "Violation sur une autre branche" i.txt
attendre_refusee "autre-branche" "liste locale" essai

# message-sans-valeur : aucune sortie de refus ne contient une valeur plantée.
if [ ! -s "$sorties_refus" ]; then
  verdict "message-sans-valeur" 1 "aucune sortie de refus à examiner"
elif grep -q -i -F -e "$prenom" -e "$ip_privee" -e "$chemin_perso" -e "$courriel" "$sorties_refus"; then
  verdict "message-sans-valeur" 1 "une valeur plantée apparaît dans un message de refus"
else
  verdict "message-sans-valeur" 0
fi

# --- Cas supplémentaires : la garde échoue « fermée » sans liste ---------------

# garde-sans-liste : sans liste locale lisible, la poussée est refusée (jamais acceptée par défaut).
repartir
printf 'contenu propre 6\n' > "$clone/j.txt"
commiter "Commit propre sans liste" j.txt
avant=$(etat_distant)
if env GARDE_LISTE="$tmp/liste-absente.txt" git -C "$clone" push -q origin main > "$sortie" 2>&1; then
  verdict "garde-sans-liste" 1 "poussée acceptée sans liste"
elif [ "$avant" != "$(etat_distant)" ]; then
  verdict "garde-sans-liste" 1 "refusée mais le distant a changé"
elif ! grep -q -F -- "liste locale introuvable" "$sortie"; then
  verdict "garde-sans-liste" 1 "message inattendu : $(tr '\n' ' ' < "$sortie")"
else
  verdict "garde-sans-liste" 0
fi

# installeur-sans-liste : l'installeur échoue avec un message clair et ne règle rien.
vierge="$tmp/vierge"
git init -q "$vierge"
mkdir -p "$vierge/outils"
cp "$outils/pre-push" "$outils/installer-garde.sh" "$vierge/outils/"
if (cd "$vierge" && env GARDE_LISTE="$tmp/liste-absente.txt" bash outils/installer-garde.sh > "$sortie" 2>&1); then
  verdict "installeur-sans-liste" 1 "l'installeur a réussi sans liste"
elif ! grep -q -F -- "liste locale introuvable" "$sortie"; then
  verdict "installeur-sans-liste" 1 "message inattendu : $(tr '\n' ' ' < "$sortie")"
elif [ -n "$(git -C "$vierge" config core.hooksPath)" ]; then
  verdict "installeur-sans-liste" 1 "core.hooksPath a été réglé malgré l'échec"
else
  verdict "installeur-sans-liste" 0
fi

echo
echo "$nb_ok cas OK, $nb_echec ÉCHEC"
[ "$nb_echec" -eq 0 ]
