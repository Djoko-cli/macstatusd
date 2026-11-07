#!/usr/bin/env python3
"""Signature, notarisation et garde de l'archive d'une version de macstatusd (plan 4, tâche 8 ; D9).

  publication.py X.Y.Z [--repetition]

Appelé par publier.sh. Dans l'ordre :
  0. les vérifications, avant toute construction : la version est X.Y.Z ; l'identité de signature est la seule
     « Developer ID Application » du trousseau (trouvée par ce préfixe), au sujet et à l'émetteur d'Apple ; le profil
     de notarisation répond ; la liste locale de la garde (garde.local.txt) est lisible ;
  1. l'assemblage : outils/assembler-app.sh --signer - ;
  2. la signature : d'abord le binaire, puis le paquet, runtime renforcé et horodatage, sans --deep et sans fichier
     de droits (une exception ne s'ajoute qu'après la preuve, au banc 3, qu'elle manque) ;
  3. codesign --verify --strict -R <exigence> (l'exigence de signature est écrite dans le dossier de travail) ;
  4. l'archive (ditto -c -k --norsrc --noextattr --keepParent), puis notarytool submit --keychain-profile <profil>
     --wait --output-format json (le statut « Accepted » est lu dans le JSON) ;
  5. stapler staple sur l'app, une nouvelle archive, spctl -a -vv -t exec et stapler validate ;
  6. la garde de l'archive finale : aucune entrée AppleDouble (« ._* », « __MACOSX/ ») dans le zip ; puis, sur une
     copie dépouillée de ses signatures (codesign --remove-signature), les chemins personnels et les motifs de
     garde.local.txt, dans tout le contenu ; les droits de l'app se contrôlent à part.

Tout le travail (assemblage, signatures, archives, copie de la garde, certificats, exigence) se fait sous
~/Library/Caches/macstatusd-build/<publication|repetition>/<version>/ : hors de ~/Documents (File Provider) et hors
des produits. Seuls macstatusd-<version>.zip et SHA256SUMS sont copiés dans build/<publication|repetition>/<version>/,
et seulement après une garde réussie. Avec --repetition : identité com.djoko.macstatusd.repetition, nom de support
macstatusd-repetition, dossiers build/repetition/<version>/ et .../repetition/<version>/.

L'environnement : IDENTITE_SIGNATURE (« Developer ID Application » par défaut ; « - » seulement en répétition, sans
notarisation), NOTARISER (1 pour notariser), PROFIL_NOTARISATION (le profil de notarytool store-credentials). Les
outils s'appellent par chemin absolu (/usr/bin/codesign, etc.). Seule la répétition peut les remplacer (CODESIGN,
SECURITY, OPENSSL, DITTO, XCRUN, SPCTL), donner une autre liste locale (GARDE_LISTE, par défaut garde.local.txt à la
racine du dépôt) et un autre dossier de développeur (DEVELOPER_DIR, que les relais xcselect de /usr/bin suivent) :
hors répétition, une de ces variables donne un refus avant le premier appel.

Le nom légal du titulaire et l'équipe d'un Developer ID ne vont que dans la signature : tout ce que ce module affiche
passe par masquer_identite (dire, et le message d'erreur de main). Aucun identifiant n'est écrit ici : l'empreinte est
lue dans le trousseau au moment de publier.
"""
import argparse
import hashlib
import json
import os
import plistlib
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import zipfile
from types import SimpleNamespace

VERSION = re.compile(r'^\d+\.\d+\.\d+$')
IDENTIFIANT = 'com.djoko.macstatusd'
DEVELOPER_ID = 'Developer ID Application'
AD_HOC = '-'
GET_TASK_ALLOW = 'com.apple.security.get-task-allow'
# La chaîne d'un Developer ID Application, vérifiée par codesign sur l'app signée : ancrée chez Apple, un
# intermédiaire Developer ID, une feuille Developer ID Application.
# Les variables qui remplacent un outil, la liste de la garde ou le dossier de développeur : réservées à la répétition.
REMPLACEMENTS = ('CODESIGN', 'SECURITY', 'OPENSSL', 'DITTO', 'XCRUN', 'SPCTL', 'GARDE_LISTE', 'DEVELOPER_DIR')
EXIGENCE_DEVELOPER_ID = ('=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
                         'certificate leaf[field.1.2.840.113635.100.6.1.13] exists')


class Refus(Exception):
    """Une vérification qui arrête la publication. Rien n'est publié : ce module ne pousse ni ne publie rien."""


class EchecCommande(Exception):
    """Une commande externe qui rend un code non nul."""

    def __init__(self, cmd, code, erreur='', sortie=''):
        super().__init__('%s (code %d)' % (' '.join(map(shlex.quote, cmd)), code))
        self.cmd = cmd
        self.code = code
        self.erreur = erreur
        self.sortie = sortie


# --- ce que l'on affiche ---------------------------------------------------------------------------------------

LIBELLES = (r'(?:Apple Development|Apple Distribution|Developer ID Application|Developer ID Installer'
            r'|iPhone Developer|iPhone Distribution|Mac Developer|Mac Installer Distribution'
            r'|3rd Party Mac Developer (?:Application|Installer))')
_VALEURS = None  # les valeurs de la liste locale, en complément (jamais affichées)


def definir_valeurs_masquees(valeurs):
    """Les valeurs de la liste locale déjà chargées (octets ou texte, 3 caractères au moins), masquées en complément
    du masque par la forme, sans casse. Une liste vide efface les valeurs."""
    global _VALEURS
    textes = sorted({(v.decode('utf-8', 'replace') if isinstance(v, bytes) else v).strip() for v in valeurs},
                    key=len, reverse=True)
    textes = [t for t in textes if len(t) >= 3]
    _VALEURS = re.compile('|'.join(re.escape(t) for t in textes), re.I) if textes else None


def masquer_identite(texte):
    """Le nom légal, l'équipe, l'empreinte et les adresses e-mail, masqués par leur forme dans tout ce que ce module
    affiche (exigence de signature, erreurs de codesign, de spctl ou de notarytool) : ils ne vont que dans la
    signature. Les formes sont celles de ~/.claude/outils/masquer (les dix libellés, avec des espaces autour des
    deux-points, équipe, empreintes de 40 et de 64 caractères, courriels), plus O=, OU= et UID= d'un
    certificat. Les échappements « \\= » qu'écrivent certains outils sont retirés d'abord. Les valeurs de la liste locale se masquent en dernier, en complément."""
    texte = texte.replace('\\=', '=').replace('\\ ', ' ')
    # Le libellé qui suit le préfixe d'une identité (titulaire, et équipe entre parenthèses).
    prefixe = r'(%s\s*:\s*)' % LIBELLES
    texte = re.sub(prefixe + r'[^\n"]*?(\s*\()[A-Z0-9]{10}(\))', r'\1<titulaire>\2<equipe>\3', texte)
    texte = re.sub(r'(%s\s*:)(?!\s*<titulaire>)(\s*)[^\n",;]+' % LIBELLES, r'\1\2<titulaire>', texte)
    texte = re.sub(r'\([A-Z0-9]{10}\)', '(<equipe>)', texte)
    texte = re.sub(r'(?<![A-Za-z0-9])[A-Z0-9]{10}\.(?=[A-Za-z])', '<equipe>.', texte)
    texte = re.sub(r'(subject\.OU\] ?= ?)"?[A-Z0-9]{10}"?', r'\1<equipe>', texte)
    texte = re.sub(r'(\b(?:[Tt]eam ?[Ii](?:[Dd]|dentifier)|TeamIdentifier)"?\s*[=:]\s*)"?[A-Z0-9]{10}"?',
                   r'\1<equipe>', texte)
    # Les champs d'un certificat (openssl -subject, -text) : le titulaire (O) et l'équipe (OU, UID).
    texte = re.sub(r'(?<![A-Za-z0-9])(UID|OU)(\s*=\s*)[^,/\n]*', r'\1\2<equipe>', texte)
    texte = re.sub(r'(?<![A-Za-z0-9])(O)(\s*=\s*)(?:\\.|[^,/\\\n])*', r'\1\2<titulaire>', texte)
    texte = re.sub(r'(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])', '<empreinte>', texte)
    texte = re.sub(r'(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}:){19}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])', '<empreinte>', texte)
    texte = re.sub(r'(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{64}|[0-9A-Fa-f]{40})(?![0-9A-Fa-f])', '<empreinte>', texte)
    texte = re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', '<courriel>', texte)
    texte = re.sub(r'(?<![A-Za-z0-9])(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10}(?![A-Za-z0-9])', '<equipe>', texte)
    if _VALEURS:
        texte = _VALEURS.sub('<masqué>', texte)
    return texte


def dire(texte):
    """Toute sortie normale du module passe ici, donc par le masque."""
    print(masquer_identite(texte), flush=True)


# --- les commandes externes -----------------------------------------------------------------------------------

class Outils:
    """Les commandes externes, appelées par chemin absolu (jamais trouvées par le PATH). Seule la répétition
    (remplacables=True) les laisse remplacer par l'environnement ; les tests redéfinissent executer dans une
    sous-classe (aucune commande réelle)."""

    def __init__(self, env=None, remplacables=False):
        e = (os.environ if env is None else env) if remplacables else {}
        self.codesign = e.get('CODESIGN', '/usr/bin/codesign')
        self.security = e.get('SECURITY', '/usr/bin/security')
        self.openssl = e.get('OPENSSL', '/usr/bin/openssl')
        self.ditto = e.get('DITTO', '/usr/bin/ditto')
        self.xcrun = e.get('XCRUN', '/usr/bin/xcrun')
        self.spctl = e.get('SPCTL', '/usr/sbin/spctl')

    def executer(self, cmd, entree=None):
        """Lance la commande ; rend (code, sortie, erreur) en texte. Ne lève rien pour un code non nul."""
        r = subprocess.run(cmd, input=entree, capture_output=True, text=True, errors='replace')
        return SimpleNamespace(code=r.returncode, sortie=r.stdout, erreur=r.stderr)

    def lancer(self, cmd, entree=None):
        """Comme executer, mais un code non nul lève EchecCommande. Rend la sortie standard."""
        r = self.executer(cmd, entree)
        if r.code != 0:
            raise EchecCommande(cmd, r.code, r.erreur, r.sortie)
        return r.sortie

    def lancer_muet(self, cmd, quoi, entree=None):
        """Comme lancer, pour un outil dont la sortie peut porter l'identité (security, openssl) : un échec devient un
        Refus qui ne recopie ni la ligne de commande ni la sortie, seulement le code."""
        r = self.executer(cmd, entree)
        if r.code != 0:
            raise Refus('%s a échoué (code %d) ; sa sortie n\'est pas affichée' % (quoi, r.code))
        return r.sortie


# --- l'identité de signature -----------------------------------------------------------------------------------

def developer_id(nom):
    """L'identité générique d'un Developer ID d'Apple. Son nom complet, « Developer ID Application: <titulaire>
    (<équipe>) », porte le nom légal du titulaire : il n'est jamais écrit ici ni affiché, et se trouve dans le
    trousseau par ce préfixe."""
    return nom == DEVELOPER_ID


def notariser(env=None):
    """La notarisation : NOTARISER=1 l'active."""
    return (os.environ if env is None else env).get('NOTARISER') == '1'


def empreinte_identite(sortie, nom):
    """L'empreinte SHA-1 de la seule identité de signature à ce nom exact (pour DEVELOPER_ID : de la forme
    « Developer ID Application: ... (<équipe de 10 caractères>) »), dans la sortie de security find-identity (qui peut
    la lister deux fois : toutes les identités, puis les valides). Lève Refus s'il n'y en a pas, ou plus d'une."""
    motif = re.escape(nom) + (r': [^"]+ \([A-Z0-9]{10}\)' if developer_id(nom) else '')
    empreintes = set(re.findall(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"%s"' % motif, sortie, re.M))
    if not empreintes:
        raise Refus('identité de signature introuvable dans le trousseau : %s' % nom)
    if len(empreintes) > 1:
        raise Refus('%d identités de signature portent le nom %s : une seule attendue' % (len(empreintes), nom))
    return empreintes.pop()


def certificat_du_trousseau(sortie, empreinte):
    """Le certificat (PEM) d'empreinte SHA-1 donnée, dans la sortie de security find-certificate -a -Z -p."""
    for sha1, pem in re.findall(r'SHA-1 hash: ([0-9A-F]{40})\s*\n(-----BEGIN CERTIFICATE-----.*?'
                                r'-----END CERTIFICATE-----)', sortie, re.S):
        if sha1 == empreinte:
            return pem + '\n'
    raise Refus("le certificat de l'identité de signature est introuvable dans le trousseau")


def sujet_conforme(sujet, nom):
    """Le sujet d'un certificat, en RFC 2253 : CN=<nom>, et au plus un code pays de deux lettres (C=FR, que
    Trousseaux d'accès pose de lui-même). Ni adresse, ni organisation, ni autre champ."""
    parts = sujet.split(',')
    if parts == ['CN=' + nom]:
        return True
    return (len(parts) == 2 and parts.count('CN=' + nom) == 1
            and any(re.fullmatch(r'C=[A-Z]{2}', x) for x in parts))


def champs_rfc2253(nom):
    """Les champs d'un nom en RFC 2253 (sortie d'openssl -nameopt RFC2253), {clé: valeur}, ou None : un champ
    double, un champ sans « = », ou un nom à plusieurs valeurs (« + » non échappé) n'est pas accepté."""
    champs = {}
    for part in re.split(r'(?<!\\),', nom):
        cle, egal, valeur = part.partition('=')
        if not egal or cle in champs or re.search(r'(?<!\\)\+', valeur):
            return None
        champs[cle] = valeur
    return champs


def sujet_developer_id(sujet):
    """Le sujet d'un certificat Developer ID Application d'Apple, en RFC 2253 : UID et OU = l'équipe (10 caractères),
    CN = « Developer ID Application: <titulaire> (<équipe>) », O = le titulaire, C = un pays de deux lettres ; chacun
    une fois, rien d'autre (ni adresse, ni autre champ)."""
    champs = champs_rfc2253(sujet)
    if champs is None or set(champs) != {'UID', 'CN', 'OU', 'O', 'C'} or not re.fullmatch(r'[A-Z]{2}', champs['C']):
        return False
    cn = re.fullmatch(r'%s: (.+) \(([A-Z0-9]{10})\)' % DEVELOPER_ID, champs['CN'])
    return bool(cn) and champs['UID'] == champs['OU'] == cn.group(2) and bool(champs['O'])


def emetteur_developer_id(emetteur):
    """L'émetteur d'un certificat Developer ID Application, en RFC 2253 : l'autorité Developer ID d'Apple (profil
    G2, ou l'ancien), et rien d'autre. La chaîne elle-même est vérifiée après la signature (EXIGENCE_DEVELOPER_ID)."""
    champs = champs_rfc2253(emetteur)
    return champs == {'CN': 'Developer ID Certification Authority', 'OU': 'G2', 'O': 'Apple Inc.', 'C': 'US'} or \
        champs == {'CN': 'Developer ID Certification Authority', 'OU': 'Apple Certification Authority',
                   'O': 'Apple Inc.', 'C': 'US'}


def verifier_certificat(o, nom, empreinte, pem=None, der=None, quoi='le certificat de signature'):
    """Le certificat est public (il est dans chaque signature). Developer ID : le sujet d'un Developer ID
    Application (sujet_developer_id), émis par l'autorité Developer ID d'Apple (emetteur_developer_id). Autre nom :
    CN=<nom> seulement, avec au plus un code pays (sujet_conforme). Dans les deux cas : sans autre nom
    (subjectAltName) ni « @ », et l'empreinte de l'identité. Le certificat est donné en PEM (pem) ou dans un fichier
    DER (der). Lève Refus, sans recopier le sujet."""
    base = [o.openssl, 'x509'] + (['-inform', 'DER', '-in', der] if der else []) + ['-noout']
    tete = o.lancer_muet(base + ['-subject', '-issuer', '-nameopt', 'RFC2253', '-fingerprint', '-sha1'],
                         'openssl x509', entree=pem)
    texte = o.lancer_muet(base + ['-text'], 'openssl x509', entree=pem)
    sujet = re.search(r'^subject=\s*(.*?)\s*$', tete, re.M)
    emetteur = re.search(r'^issuer=\s*(.*?)\s*$', tete, re.M)
    lue = re.search(r'Fingerprint=([0-9A-Fa-f:]+)', tete)
    if developer_id(nom):
        if not sujet or not sujet_developer_id(sujet.group(1)):
            raise Refus("%s : son sujet doit être celui d'un Developer ID Application (UID, CN, OU, O, C)" % quoi)
        if not emetteur or not emetteur_developer_id(emetteur.group(1)):
            raise Refus("%s n'est pas émis par l'autorité Developer ID d'Apple" % quoi)
    elif not sujet or not sujet_conforme(sujet.group(1), nom):
        raise Refus('%s : son sujet doit être seulement CN=%s, et au plus un pays (ni adresse, ni organisation)'
                    % (quoi, nom))
    if '@' in tete + texte or 'Subject Alternative Name' in texte:
        raise Refus("%s porte une adresse ou un autre nom (subjectAltName) : rien n'est publié" % quoi)
    if not lue or lue.group(1).replace(':', '').upper() != empreinte:
        raise Refus("%s n'est pas celui de l'identité choisie (empreinte)" % quoi)


def identite_verifiee(o, nom):
    """L'empreinte de la seule identité à ce nom dans le trousseau, son certificat relu (sujet, émetteur, empreinte).
    Lève Refus."""
    empreinte = empreinte_identite(
        o.lancer_muet([o.security, 'find-identity', '-p', 'codesigning'], 'security find-identity'), nom)
    pem = certificat_du_trousseau(
        o.lancer_muet([o.security, 'find-certificate', '-a', '-c', nom, '-Z', '-p'], 'security find-certificate'),
        empreinte)
    verifier_certificat(o, nom, empreinte, pem=pem)
    return empreinte


# --- la garde de l'archive -------------------------------------------------------------------------------------

def motifs_personnels(env=None):
    """Ce qu'aucun fichier publié ne doit porter : tout chemin sous le dossier des comptes (celui du système), le dossier personnel (HOME) et le nom du
    compte macOS (USER, LOGNAME et celui du système). Chaque motif avec ce qu'il est, jamais sa valeur."""
    e = os.environ if env is None else env
    # Assemblé à l'exécution : la garde pre-push refuserait ce fichier s'il portait un chemin personnel écrit en clair.
    motifs = [(b'/Us' + b'ers/', 'un chemin personnel (dossier des comptes)')]
    maison = e.get('HOME', '').rstrip('/')
    if maison:
        motifs.append((maison.encode(), 'le dossier personnel (HOME)'))
    comptes = {e.get('USER', ''), e.get('LOGNAME', '')}
    try:
        comptes.add(pwd.getpwuid(os.getuid()).pw_name)
    except KeyError:
        pass
    motifs += [(c.encode(), 'le nom du compte') for c in sorted(comptes) if c]
    return motifs


def motifs_liste_locale(chemin):
    """Les valeurs de la liste locale de la garde (garde.local.txt : une valeur réelle par ligne ; lignes vides et
    commentaires « # » ignorés, blancs des extrémités retirés, comme outils/pre-push). Chaque motif est étiqueté par
    sa position, jamais par sa valeur. Lève Refus si la liste est absente ou sans ligne utilisable : la garde ne
    laisse pas passer faute de liste."""
    try:
        with open(chemin, 'rb') as f:
            lignes = f.read().replace(b'\r', b'').split(b'\n')
    except OSError:
        raise Refus('liste locale de la garde illisible : garde.local.txt (ou GARDE_LISTE) est absent')
    motifs = [(l.strip(), 'une valeur de la liste locale (ligne %d)' % n)
              for n, l in enumerate(lignes, 1) if l.strip() and not l.strip().startswith(b'#')]
    if not motifs:
        raise Refus('liste locale de la garde sans ligne utilisable : une valeur réelle par ligne')
    return motifs


def chemins_personnels(dossier, motifs):
    """Ce qui, dans le dossier (la copie de l'archive), porte un motif : le contenu de chaque fichier ordinaire
    (binaires compris), la cible de chaque lien et chaque nom, sans tenir compte de la casse (ASCII). Rend
    [(chemin relatif, motif)] ; le chemin relatif est tu dès que le nom porte l'un des motifs (même si ce n'est pas
    celui qui a touché le contenu) : un nom de fichier ne recopie jamais une valeur de la liste."""
    trouves = []
    motifs = [(m.lower(), quoi) for m, quoi in motifs]
    for racine, dossiers, fichiers in os.walk(dossier):
        for nom in sorted(dossiers + fichiers):
            p = os.path.join(racine, nom)
            rel = os.path.relpath(p, dossier)
            if os.path.islink(p):
                contenu = os.readlink(p).encode()
            elif os.path.isfile(p):
                with open(p, 'rb') as f:
                    contenu = f.read()
            else:
                contenu = b''
            contenu = contenu.lower()
            nom_bas = rel.encode().lower()
            affiche = nom_affichable(rel, motifs)
            for motif, quoi in motifs:
                if motif in nom_bas or motif in contenu:
                    trouves.append((affiche, quoi))
                    break
    return trouves


NOM_TU = '(un nom de fichier)'


def nom_affichable(rel, motifs):
    """Le chemin relatif, ou NOM_TU s'il porte l'un des motifs (en minuscules, comparés sans casse)."""
    bas = rel.encode().lower()
    return NOM_TU if any(m.lower() in bas for m, _ in motifs) else rel


def codes_de_l_app(app):
    """Le code à dépouiller de sa signature, dans l'ordre : les exécutables de Contents/MacOS, puis l'app."""
    dossier = os.path.join(app, 'Contents', 'MacOS')
    codes = [os.path.join(dossier, n) for n in sorted(os.listdir(dossier))] if os.path.isdir(dossier) else []
    return [c for c in codes if os.path.isfile(c) and not os.path.islink(c)] + [app]


def copie_sans_signatures(o, archive, dossier, motifs=()):
    """Une copie du contenu de l'archive pour la garde, chaque code sans sa signature (codesign --remove-signature,
    sur la copie seulement) : la signature d'un Developer ID individuel porte le nom légal du titulaire, publié dans
    la signature et nulle part ailleurs. Le reste du code, les textes et les noms restent contrôlés. Un code dont
    codesign ne sait pas retirer la signature est refusé (Refus, sans recopier un nom qui porte un motif). Rend le
    dossier de la copie."""
    shutil.rmtree(dossier, ignore_errors=True)
    o.lancer([o.ditto, '-x', '-k', archive, dossier])
    for nom in sorted(os.listdir(dossier)):
        chemin = os.path.join(dossier, nom)
        if nom.endswith('.app') and os.path.isdir(chemin) and not os.path.islink(chemin):
            for code in codes_de_l_app(chemin):
                if o.executer([o.codesign, '--remove-signature', code]).code != 0:
                    shutil.rmtree(dossier, ignore_errors=True)
                    raise Refus("la signature de %s ne se retire pas de la copie contrôlée : rien n'est publié"
                                % nom_affichable(os.path.relpath(code, dossier), motifs))
    return dossier


def entrees_appledouble(archive):
    """Le nombre d'entrées de l'archive qui sont des attributs étendus ou des ressources (AppleDouble : un composant
    « ._* », ou un dossier « __MACOSX »). ditto les range ainsi ; extraites, elles redeviennent des attributs
    que la garde ne lit pas. Les noms ne sont pas rendus."""
    with zipfile.ZipFile(archive) as z:
        return sum(1 for n in z.namelist()
                   if any(c.startswith('._') or c == '__MACOSX' for c in n.split('/')))


def garder_archive(o, archive, dossier, motifs):
    """La garde de l'archive finale : chemins personnels et valeurs de la liste locale, dans tout le contenu d'une
    copie dépouillée de ses signatures. Lève Refus en nommant les fichiers (et ce qu'ils portent, jamais la
    valeur)."""
    entrees = entrees_appledouble(archive)
    if entrees:
        raise Refus("l'archive porte %d entrée(s) AppleDouble (« ._* » ou « __MACOSX/ », des attributs étendus que "
                    "la garde ne lit pas) ; rien n'est publié" % entrees)
    copie = copie_sans_signatures(o, archive, dossier, motifs)
    try:
        trouves = chemins_personnels(copie, motifs)
    finally:
        shutil.rmtree(copie, ignore_errors=True)
    if trouves:
        raise Refus("l'archive porte une donnée personnelle (%d) : %s ; rien n'est publié"
                    % (len(trouves), ' ; '.join('%s (%s)' % t for t in trouves[:5])))


# --- les droits ------------------------------------------------------------------------------------------------

def lire_droits(o, app):
    """Les droits d'une app, lus dans sa signature (codesign -d --entitlements - --xml). Une signature sans droits
    donne une sortie vide : {}. Lève Refus si la sortie n'est pas un plist de dictionnaire."""
    sortie = o.lancer([o.codesign, '-d', '--entitlements', '-', '--xml', app])
    if not sortie.strip():
        return {}
    try:
        droits = plistlib.loads(sortie.encode())
    except Exception:
        droits = None
    if not isinstance(droits, dict):
        raise Refus("droits de l'app signée illisibles (codesign -d --entitlements)")
    return droits


def verifier_droits(o, app):
    """Les droits de l'app signée, relus : aucun fichier de droits n'a été donné, donc aucune exception. Jamais
    get-task-allow (un débogueur pourrait s'attacher à l'app), ni aucune exception du runtime renforcé
    (com.apple.security.cs.*). Une exception ne s'ajoute qu'après la preuve, au banc 3, qu'elle manque. Lève
    Refus."""
    droits = lire_droits(o, app)
    if GET_TASK_ALLOW in droits:
        raise Refus("droits de l'app signée : %s est présent" % GET_TASK_ALLOW)
    exceptions = sorted(k for k in droits if k.startswith('com.apple.security.cs.'))
    if exceptions:
        raise Refus("droits de l'app signée : exception du runtime renforcé %s" % ', '.join(exceptions))


# --- la publication --------------------------------------------------------------------------------------------

def signer(o, identite, chemin, horodatage):
    """Signe un code (par l'empreinte de l'identité, ou « - » pour l'ad hoc) : runtime renforcé, horodatage, aucun
    fichier de droits, jamais --deep."""
    o.lancer([o.codesign, '--force', '--sign', identite, '--options', 'runtime',
              '--timestamp' if horodatage else '--timestamp=none', chemin])


def archiver(o, app, archive):
    """L'archive d'une app : sans ressources ni attributs étendus (--norsrc --noextattr), pour qu'aucune entrée
    AppleDouble « ._* » n'emporte un attribut (URL de téléchargement, nom d'appareil) que la garde ne lit pas."""
    if os.path.exists(archive):
        os.remove(archive)
    o.lancer([o.ditto, '-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, archive])


def somme_sha256(chemin):
    h = hashlib.sha256()
    with open(chemin, 'rb') as f:
        for bloc in iter(lambda: f.read(1 << 20), b''):
            h.update(bloc)
    return h.hexdigest()


def racine_travail_par_defaut():
    """Le travail vit dans les caches de l'utilisateur : hors de ~/Documents (File Provider) et hors du dépôt."""
    return os.path.join(os.path.expanduser('~'), 'Library', 'Caches', 'macstatusd-build')


def reponse_notarisation(retour):
    """La réponse JSON de la soumission à Apple (--output-format json), ou Refus (sans la recopier)."""
    try:
        reponse = json.loads(retour)
    except ValueError:
        reponse = None
    if not isinstance(reponse, dict):
        raise Refus("la réponse de l'outil de notarisation n'est pas du JSON (--output-format json) : "
                    "rien n'est publié")
    return reponse


def publier(a, o=None, env=None):
    """Les étapes dans l'ordre (voir l'en-tête). Rend le dossier des produits. a : version, repetition, depot,
    racine_travail (facultatif)."""
    e = dict(os.environ) if env is None else env
    if not VERSION.match(a.version):
        raise Refus('version attendue sous la forme X.Y.Z : ' + a.version)
    if not a.repetition:
        remplaces = [v for v in REMPLACEMENTS if v in e]
        if remplaces:
            raise Refus('hors --repetition, aucun outil ni liste de la garde ne se remplace : %s' % ', '.join(remplaces))
    o = o or Outils(e, a.repetition)
    identite = e.get('IDENTITE_SIGNATURE', DEVELOPER_ID)
    notarise = notariser(e)
    profil = e.get('PROFIL_NOTARISATION', '')

    # 0. les vérifications, avant toute construction
    if not a.repetition and (not developer_id(identite) or not notarise):
        raise Refus('une version publiée est signée par le Developer ID et notarisée (IDENTITE_SIGNATURE, NOTARISER)')
    if notarise and not developer_id(identite):
        raise Refus('la notarisation (NOTARISER=1) va avec le Developer ID, et lui seul : une signature ad hoc '
                    "n'est pas notarisable")
    if not developer_id(identite) and identite != AD_HOC:
        raise Refus('identité de signature attendue : %s (ou « - » en répétition, sans notarisation)' % DEVELOPER_ID)
    if notarise and not profil:
        raise Refus('NOTARISER=1 demande PROFIL_NOTARISATION, le profil du trousseau pour la notarisation')
    # GARDE_LISTE n'arrive jusqu'ici qu'en répétition : hors répétition, elle est refusée plus haut.
    liste = e.get('GARDE_LISTE') or os.path.join(a.depot, 'garde.local.txt')
    motifs_liste = motifs_liste_locale(liste)
    definir_valeurs_masquees([m for m, _ in motifs_liste])
    motifs = motifs_personnels(e) + motifs_liste
    empreinte = identite_verifiee(o, identite) if developer_id(identite) else AD_HOC
    if notarise and o.executer([o.xcrun, 'notarytool', 'history', '--keychain-profile', profil]).code != 0:
        raise Refus('le profil de notarisation %s ne répond pas (notarytool history)' % profil)

    # Le travail (hors du dépôt) et les produits (le zip et SHA256SUMS, après la garde seulement).
    genre = 'repetition' if a.repetition else 'publication'
    racine = getattr(a, 'racine_travail', None) or racine_travail_par_defaut()
    travail = os.path.join(racine, genre, a.version)
    produits = os.path.join(a.depot, 'build', genre, a.version)
    shutil.rmtree(travail, ignore_errors=True)
    shutil.rmtree(produits, ignore_errors=True)
    os.makedirs(travail, mode=0o700)

    # 1. l'assemblage (signature ad hoc, refaite à l'étape 2)
    cmd = ['/bin/bash', os.path.join(a.depot, 'outils', 'assembler-app.sh'), '--signer', '-',
           '--sortie', os.path.join(travail, 'app')]
    if a.repetition:
        cmd += ['--identifiant', IDENTIFIANT + '.repetition', '--nom-support', 'macstatusd-repetition']
    lignes = o.lancer(cmd).strip().splitlines()
    app = lignes[-1] if lignes else ''
    if not app or not os.path.isdir(app):
        raise Refus("l'assembleur n'a pas donné le chemin de l'app sur sa dernière ligne")
    dire('app assemblée : ' + os.path.relpath(app, racine))

    # 2. la signature : le binaire, puis le paquet
    horodatage = developer_id(identite)
    for code in codes_de_l_app(app):
        signer(o, empreinte, code, horodatage)

    # 3. la vérification : droits, certificat feuille, exigence
    verifier_droits(o, app)
    if developer_id(identite):
        prefixe = os.path.join(travail, 'certificat-')
        o.lancer([o.codesign, '-d', '--extract-certificates=' + prefixe, app])
        if not os.path.isfile(prefixe + '0'):
            raise Refus("aucun certificat dans la signature de l'app")
        verifier_certificat(o, identite, empreinte, der=prefixe + '0', quoi="le certificat feuille de l'app")
    exigence = o.lancer([o.codesign, '-d', '-r-', app]).strip()
    with open(os.path.join(travail, 'exigence.txt'), 'w', encoding='utf-8') as f:
        f.write(exigence + '\n')
    dire('exigence de signature : ' + exigence)
    if developer_id(identite):
        o.lancer([o.codesign, '--verify', '--strict', '-R' + EXIGENCE_DEVELOPER_ID, app])
    else:
        o.lancer([o.codesign, '--verify', '--strict', app])

    # 4. l'archive, puis la notarisation
    if notarise:
        soumission = os.path.join(travail, 'soumission.zip')
        archiver(o, app, soumission)
        retour = o.lancer([o.xcrun, 'notarytool', 'submit', soumission, '--keychain-profile', profil, '--wait',
                           '--output-format', 'json'])
        os.remove(soumission)
        reponse = reponse_notarisation(retour)
        if reponse.get('status') != 'Accepted':
            # Seuls id, status et message, masqués d'abord ; la coupe vient après le masque.
            resume = 'id=%s status=%s message=%s' % (reponse.get('id'), reponse.get('status'), reponse.get('message'))
            raise Refus('notarisation non acceptée par Apple : ' + masquer_identite(resume)[:500])
        dire('notarisation acceptée (id %s)' % reponse.get('id'))
        # 5. l'agrafe, puis la vérification de l'app agrafée
        o.lancer([o.xcrun, 'stapler', 'staple', app])

    final = os.path.join(travail, 'macstatusd-%s.zip' % a.version)
    archiver(o, app, final)
    if notarise:
        o.lancer([o.spctl, '-a', '-vv', '-t', 'exec', app])
        o.lancer([o.xcrun, 'stapler', 'validate', app])
        dire('app agrafée et acceptée par Gatekeeper')

    # 6. la garde de l'archive finale ; les produits ne reçoivent le zip qu'après elle
    try:
        garder_archive(o, final, os.path.join(travail, 'controle'), motifs)
    except BaseException:
        if os.path.exists(final):
            os.remove(final)
        raise
    dire("garde de l'archive : aucun chemin personnel, aucune valeur de la liste locale")
    os.makedirs(produits)
    livre = os.path.join(produits, os.path.basename(final))
    shutil.copyfile(final, livre)
    with open(os.path.join(produits, 'SHA256SUMS'), 'w', encoding='utf-8') as f:
        f.write('%s  %s\n' % (somme_sha256(livre), os.path.basename(livre)))
    dire('produits : ' + os.path.relpath(produits, a.depot))
    return produits


def arguments(argv, depot=None, racine_travail=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('version', help='X.Y.Z')
    p.add_argument('--repetition', action='store_true',
                   help='identité com.djoko.macstatusd.repetition, dossier build/repetition/<version>/')
    a = p.parse_args(argv)
    a.depot = depot or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    a.racine_travail = racine_travail or racine_travail_par_defaut()
    return a


def main(argv=None, o=None, env=None, depot=None, racine_travail=None):
    a = arguments(sys.argv[1:] if argv is None else argv, depot, racine_travail)
    definir_valeurs_masquees([])  # publier y met les valeurs de la liste locale, dès qu'il les a lues
    try:
        publier(a, o, env)
    except Refus as e:
        print(masquer_identite('refus : %s' % e), file=sys.stderr)
        return 1
    except EchecCommande as e:
        # Masquer avant de couper : une coupure au milieu d'un nom le laisserait en clair.
        print(masquer_identite('échec : %s\n%s\n%s' % (e, e.sortie, e.erreur)).rstrip()[-2500:], file=sys.stderr)
        return 1
    except OSError as e:
        print(masquer_identite('échec : %s' % e), file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 - une erreur imprévue n'affiche que son type, jamais sa trace ni son texte
        print(masquer_identite('échec imprévu : %s' % type(e).__name__), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
