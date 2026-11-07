"""Tests de outils/publication.py (plan 4, tâche 8).

Lancer, dans l'environnement neutre :
  env -i PATH=/usr/bin:/bin HOME="$HOME" python3 -m unittest discover -s outils/tests -p 'test_publication.py'

Aucune commande réelle : les outils (codesign, security, openssl, ditto, xcrun, spctl, l'assembleur) sont
remplacés par FauxOutils, qui note ses appels et fabrique à la main les fichiers que les vrais produiraient.
Toutes les identités sont inventées. Les valeurs « interdites » plantées (chemin personnel, courriel) sont assemblées
à l'exécution, à partir de morceaux, sinon la garde pre-push refuserait ce fichier lui-même.
"""
import contextlib
import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import sys
import tempfile
import unittest
import zipfile
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import publication  # noqa: E402

RACINE = '/private/tmp/macstatusd-plan4/essais-publication'

# --- Valeurs plantées (inventées, assemblées à l'exécution) ----------------------------------------------------
TITULAIRE = 'Prénom Nom'
EQUIPE = 'ABCDE12345'
EMPREINTE = '0123456789ABCDEF0123456789ABCDEF01234567'
COURRIEL = 'essai' + '@' + 'exemple' + '.invalide'
CHEMIN_PERSO = '/Us' + 'ers/Essai/Dev/macstatusd'
NOM_COMPLET = 'Developer ID Application: %s (%s)' % (TITULAIRE, EQUIPE)
SUJET = 'UID=%s,CN=%s,OU=%s,O=%s,C=FR' % (EQUIPE, NOM_COMPLET, EQUIPE, TITULAIRE)
EMETTEUR = 'CN=Developer ID Certification Authority,OU=G2,O=Apple Inc.,C=US'
NOTARISATION_ACCEPTEE = json.dumps({'id': 'essai', 'status': 'Accepted', 'message': 'Processing complete'})
PLANTE = ('%s ; %s.com.djoko.macstatusd ; %s ; %s ; Apple Development: Autre Nom (ZZZZZ99999)'
          % (NOM_COMPLET, EQUIPE, EMPREINTE.lower(), COURRIEL))


def vu(texte):
    """Ce qui, dans le texte, survit des formes interdites (liste de noms, jamais de valeurs de la maison)."""
    formes = {'titulaire': TITULAIRE, 'équipe': EQUIPE, 'empreinte': EMPREINTE.lower(), 'courriel': COURRIEL,
              'autre libellé': 'Autre Nom', 'empreinte majuscules': EMPREINTE}
    return sorted(nom for nom, valeur in formes.items() if valeur in texte)


def sans_bruit():
    return contextlib.redirect_stdout(io.StringIO())


class FauxOutils(publication.Outils):
    """Les outils externes, sans aucune commande réelle. Les appels sont notés dans self.appels."""

    def __init__(self, env=None, identites=None, emetteur=EMETTEUR, retrait_rate=False, ressources=None,
                 signature=b'signature', notarisation=NOTARISATION_ACCEPTEE, echec_signature=None,
                 droits='', echecs=None, entrees_zip=None):
        super().__init__(env)
        self.appels = []
        self.identites = [(EMPREINTE, NOM_COMPLET)] if identites is None else identites
        self.emetteur = emetteur
        self.retrait_rate = retrait_rate
        self.ressources = ressources or {}
        self.signature = signature
        self.notarisation = notarisation
        self.echec_signature = echec_signature
        self.droits = droits
        self.echecs = echecs or {}          # nom d'outil -> (code, sortie, erreur) : l'outil échoue toujours
        self.entrees_zip = entrees_zip or {}  # entrées plantées dans chaque archive créée (nom -> contenu)

    def executer(self, cmd, entree=None):
        self.appels.append(list(cmd))
        nom = os.path.basename(cmd[0])
        for cle, echec in self.echecs.items():
            # la clé est un nom d'outil, ou (nom d'outil, argument) pour ne faire échouer qu'un de ses appels
            if cle == nom or (isinstance(cle, tuple) and cle[0] == nom and cle[1] in cmd):
                return self.rendre(*echec)
        if nom == 'bash':
            return self._assembler(cmd)
        if nom == 'security':
            return self._security(cmd)
        if nom == 'openssl':
            return self._openssl(cmd)
        if nom == 'codesign':
            return self._codesign(cmd)
        if nom == 'ditto':
            return self._ditto(cmd)
        if nom == 'xcrun' and cmd[1] == 'notarytool' and cmd[2] == 'submit':
            return self.rendre(0, self.notarisation)
        return self.rendre(0)

    @staticmethod
    def rendre(code, sortie='', erreur=''):
        return SimpleNamespace(code=code, sortie=sortie, erreur=erreur)

    def _assembler(self, cmd):
        sortie = cmd[cmd.index('--sortie') + 1]
        identifiant = cmd[cmd.index('--identifiant') + 1] if '--identifiant' in cmd else 'com.djoko.macstatusd'
        suffixe = identifiant[len('com.djoko.macstatusd.'):] if identifiant != 'com.djoko.macstatusd' else ''
        app = os.path.join(sortie, 'macstatusd%s.app' % ('-' + suffixe if suffixe else ''))
        os.makedirs(os.path.join(app, 'Contents', 'MacOS'))
        os.makedirs(os.path.join(app, 'Contents', 'Resources'))
        with open(os.path.join(app, 'Contents', 'MacOS', 'macstatusd'), 'wb') as f:
            f.write(b'binaire')
        with open(os.path.join(app, 'Contents', 'Info.plist'), 'wb') as f:
            plistlib.dump({'CFBundleIdentifier': identifiant}, f)
        for rel, contenu in self.ressources.items():
            chemin = os.path.join(app, rel)
            os.makedirs(os.path.dirname(chemin), exist_ok=True)
            with open(chemin, 'wb') as f:
                f.write(contenu)
        return self.rendre(0, 'assemblage\n%s\n' % app)

    def _security(self, cmd):
        if cmd[1] == 'find-identity':
            lignes = ['  %d) %s "%s"' % (i, e, n) for i, (e, n) in enumerate(self.identites, 1)]
            return self.rendre(0, '\n'.join(lignes + ['     %d valid identities found' % len(self.identites)]) + '\n')
        blocs = ['SHA-1 hash: %s\n-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----' % e
                 for e, _ in self.identites]
        return self.rendre(0, '\n'.join(blocs) + '\n')

    def _openssl(self, cmd):
        if '-text' in cmd:
            return self.rendre(0, 'Certificate:\n    Data:\n        Version: 3 (0x2)\n')
        fp = ':'.join(EMPREINTE[i:i + 2] for i in range(0, 40, 2))
        return self.rendre(0, 'subject=%s\nissuer=%s\nsha1 Fingerprint=%s\n' % (SUJET, self.emetteur, fp))

    def _codesign(self, cmd):
        if '--force' in cmd:
            if self.echec_signature:
                return self.rendre(1, '', self.echec_signature)
            if cmd[-1].endswith('.app'):
                dossier = os.path.join(cmd[-1], 'Contents', '_CodeSignature')
                os.makedirs(dossier, exist_ok=True)
                with open(os.path.join(dossier, 'CodeResources'), 'wb') as f:
                    f.write(self.signature)
            return self.rendre(0)
        if '--remove-signature' in cmd:
            if self.retrait_rate:
                return self.rendre(1, '', 'code object is not signed at all')
            if cmd[-1].endswith('.app'):
                shutil.rmtree(os.path.join(cmd[-1], 'Contents', '_CodeSignature'), ignore_errors=True)
            return self.rendre(0)
        if '--entitlements' in cmd:
            return self.rendre(0, self.droits)
        if any(x.startswith('--extract-certificates=') for x in cmd):
            prefixe = [x for x in cmd if x.startswith('--extract-certificates=')][0].split('=', 1)[1]
            with open(prefixe + '0', 'wb') as f:
                f.write(b'der')
            return self.rendre(0)
        if '-r-' in cmd:
            return self.rendre(0, 'designated => anchor apple generic and certificate leaf[subject.OU] = %s\n' % EQUIPE)
        return self.rendre(0)

    def _ditto(self, cmd):
        if '-c' in cmd:
            source, archive = cmd[-2], cmd[-1]
            parent = os.path.dirname(source)
            with zipfile.ZipFile(archive, 'w') as z:
                for racine, _, fichiers in os.walk(source):
                    for n in fichiers:
                        p = os.path.join(racine, n)
                        z.write(p, os.path.relpath(p, parent))
                for entree, contenu in self.entrees_zip.items():
                    z.writestr(entree, contenu)
        else:
            with zipfile.ZipFile(cmd[-2]) as z:
                z.extractall(cmd[-1])
        return self.rendre(0)

    def etapes(self):
        """Les gestes de la publication, dans l'ordre des appels, chacun sous son nom."""
        liste = []
        for c in self.appels:
            nom = os.path.basename(c[0])
            geste = None
            if nom == 'bash' and c[1].endswith('assembler-app.sh'):
                geste = 'assembler'
            elif nom == 'codesign' and '--force' in c:
                geste = 'signer'
            elif nom == 'codesign' and '--verify' in c:
                geste = 'vérifier'
            elif nom == 'codesign' and '--remove-signature' in c:
                geste = 'garder'
            elif nom == 'ditto' and '-c' in c:
                geste = 'archiver'
            elif nom == 'ditto' and '-x' in c:
                geste = 'garder'
            elif nom == 'xcrun' and c[1] == 'notarytool' and c[2] == 'submit':
                geste = 'notariser'
            elif nom == 'xcrun' and c[1] == 'stapler' and c[2] == 'staple':
                geste = 'agrafer'
            elif nom == 'spctl':
                geste = 'évaluer'
            elif nom == 'xcrun' and c[1] == 'stapler' and c[2] == 'validate':
                geste = 'valider'
            if geste and (not liste or liste[-1] != geste):
                liste.append(geste)
        return liste


class Base(unittest.TestCase):
    def setUp(self):
        os.makedirs(RACINE, exist_ok=True)
        self.tmp = tempfile.mkdtemp(dir=RACINE)
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.depot = os.path.join(self.tmp, 'depot')
        os.makedirs(self.depot)
        self.cache = os.path.join(self.tmp, 'cache')  # la racine du travail (hors du dépôt)
        self.liste = os.path.join(self.depot, 'garde.local.txt')
        self.ecrire_liste(TITULAIRE, EQUIPE)
        self.addCleanup(publication.definir_valeurs_masquees, [])

    def ecrire_liste(self, *valeurs):
        with open(self.liste, 'w', encoding='utf-8') as f:
            f.write('# valeurs d\'essai\n%s\n' % '\n'.join(valeurs))

    def env(self, **plus):
        """L'environnement neutre, recalculé à chaque appel."""
        e = {'PATH': '/usr/bin:/bin', 'HOME': '/home/exemple', 'NOTARISER': '1',
             'PROFIL_NOTARISATION': 'djoko-notarisation'}
        e.update(plus)
        return e

    def args(self, repetition=False):
        return SimpleNamespace(version='0.6.0', repetition=repetition, depot=self.depot, racine_travail=self.cache)

    def publier(self, o=None, repetition=False, **env):
        e = self.env(**env)
        o = o or FauxOutils(e)
        with sans_bruit():
            sortie = publication.publier(self.args(repetition), o, e)
        return o, sortie


class TestMasque(Base):
    def test_masque_titulaire_equipe_empreinte_et_courriel(self):
        masque = publication.masquer_identite(PLANTE)
        self.assertEqual([], vu(masque), masque)
        self.assertNotIn('ZZZZZ99999', masque)
        # Les échappements « \= » qu'écrit xcodebuild sont retirés avant le masque.
        masque = publication.masquer_identite(PLANTE.replace('=', '\\=') + ' X\\=Y')
        self.assertEqual([], vu(masque), masque)
        self.assertIn('X=Y', masque)

    def test_masque_chaque_libelle_de_la_session_seul(self):
        # Les dix libellés de ~/.claude/outils/masquer, chacun testé seul, avec ou sans équipe entre parenthèses.
        libelles = ('Apple Development', 'Apple Distribution', 'Developer ID Application', 'Developer ID Installer',
                    'iPhone Developer', 'iPhone Distribution', 'Mac Developer', 'Mac Installer Distribution',
                    '3rd Party Mac Developer Application', '3rd Party Mac Developer Installer')
        for libelle in libelles:
            for echantillon in ('%s: %s (%s)', '%s: %s', '"%s: %s"'):
                with self.subTest(libelle=libelle, forme=echantillon):
                    texte = echantillon % ((libelle, TITULAIRE, EQUIPE) if echantillon.count('%s') == 3
                                           else (libelle, TITULAIRE))
                    masque = publication.masquer_identite(texte)
                    self.assertEqual([], vu(masque), masque)
                    self.assertIn('<titulaire>', masque)

    def test_masque_les_deux_points_avec_ou_sans_espaces(self):
        for libelle in ('Developer ID Application', 'Mac Developer', '3rd Party Mac Developer Installer'):
            for separateur in (':', ' :', ': ', ' : ', ':  ', '\t:\t'):
                for fin in (' (%s)' % EQUIPE, '(%s)' % EQUIPE, ''):
                    with self.subTest(libelle=libelle, separateur=separateur, fin=fin):
                        masque = publication.masquer_identite('%s%s%s%s' % (libelle, separateur, TITULAIRE, fin))
                        self.assertEqual([], vu(masque), masque)

    def test_masque_un_titulaire_invente_que_la_relecture_laissait_en_clair(self):
        for ligne in ('Mac Developer: %s (%s)' % (TITULAIRE, EQUIPE),
                      'iPhone Distribution:%s (%s)' % (TITULAIRE, EQUIPE),
                      '3rd Party Mac Developer Application : %s' % TITULAIRE):
            with self.subTest(ligne=ligne):
                self.assertEqual([], vu(publication.masquer_identite(ligne)))

    def test_masque_le_titulaire_d_un_O_a_virgule_echappee(self):
        for sujet in ('O=Prénom\\, Nom', 'CN=x,O=Prénom\\, Nom,C=FR', 'O = Prénom\\, Nom\\, Fils,C=FR'):
            with self.subTest(sujet=sujet):
                masque = publication.masquer_identite(sujet)
                self.assertNotIn('Prénom', masque)
                self.assertNotIn('Nom', masque)
                self.assertNotIn('Fils', masque)
        self.assertEqual('CN=x,O=<titulaire>,C=FR',
                         publication.masquer_identite('CN=x,O=Prénom\\, Nom,C=FR'))

    def test_masque_le_texte_d_une_exception(self):
        # Une commande qui échoue : son erreur, sa sortie et sa ligne de commande passent par le masque.
        o = FauxOutils(self.env(), echec_signature=PLANTE)
        sortie, erreur = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(sortie), contextlib.redirect_stderr(erreur):
            code = publication.main(['0.6.0'], o, self.env(), self.depot, self.cache)
        self.assertEqual(1, code)
        self.assertEqual([], vu(erreur.getvalue() + sortie.getvalue()), erreur.getvalue())
        self.assertIn('<equipe>', erreur.getvalue())
        # Un refus qui nommerait une identité : même masque.
        erreur = io.StringIO()
        with mock.patch.object(publication, 'publier', side_effect=publication.Refus(PLANTE)), \
                contextlib.redirect_stderr(erreur):
            self.assertEqual(1, publication.main(['0.6.0'], None, self.env(), self.depot, self.cache))
        self.assertEqual([], vu(erreur.getvalue()), erreur.getvalue())
        # Une erreur du système (OSError) : même masque.
        erreur = io.StringIO()
        with mock.patch.object(publication, 'publier', side_effect=OSError(PLANTE)), \
                contextlib.redirect_stderr(erreur):
            self.assertEqual(1, publication.main(['0.6.0'], None, self.env(), self.depot, self.cache))
        self.assertEqual([], vu(erreur.getvalue()), erreur.getvalue())

    def test_dire_masque(self):
        sortie = io.StringIO()
        with contextlib.redirect_stdout(sortie):
            publication.dire(PLANTE)
        self.assertEqual([], vu(sortie.getvalue()), sortie.getvalue())

    def test_tout_ce_que_le_deroulement_affiche_est_masque(self):
        # Le dessin planté par les faux outils (exigence avec l'équipe) ne survit pas dans la sortie normale.
        e = self.env()
        sortie = io.StringIO()
        with contextlib.redirect_stdout(sortie):
            publication.publier(self.args(), FauxOutils(e), e)
        self.assertEqual([], vu(sortie.getvalue()), sortie.getvalue())
        self.assertIn('<equipe>', sortie.getvalue())


class TestIdentite(Base):
    def lancer_refuse(self, o):
        e = self.env()
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), o, e)
        self.assertEqual([], vu(str(r.exception)))
        self.assertNotIn('assembler', o.etapes())  # refusé avant toute construction
        self.assertNotIn('signer', o.etapes())

    def test_identite_aucune_refus(self):
        self.lancer_refuse(FauxOutils(self.env(), identites=[]))

    def test_identite_deux_refus(self):
        autre = '89ABCDEF0123456789ABCDEF0123456789ABCDEF'
        self.lancer_refuse(FauxOutils(self.env(), identites=[(EMPREINTE, NOM_COMPLET),
                                                             (autre, 'Developer ID Application: Autre Nom (ZZZZZ99999)')]))

    def test_identite_emetteur_inconnu_refus(self):
        self.lancer_refuse(FauxOutils(self.env(), emetteur='CN=Autorite Quelconque,O=Quelqu un,C=FR'))

    def test_notarisation_exige_le_developer_id(self):
        # NOTARISER=1 avec une signature ad hoc : refus, avant toute construction, répétition comprise.
        for repetition in (True, False):
            e = self.env(IDENTITE_SIGNATURE='-')
            o = FauxOutils(e)
            with sans_bruit(), self.assertRaises(publication.Refus):
                publication.publier(self.args(repetition), o, e)
            self.assertEqual([], o.appels)

    def test_cliquet_hors_repetition(self):
        for plus in ({'IDENTITE_SIGNATURE': '-', 'NOTARISER': '0'}, {'NOTARISER': '0'},
                     {'IDENTITE_SIGNATURE': 'Autre identite'}):
            e = self.env(**plus)
            o = FauxOutils(e)
            with sans_bruit(), self.assertRaises(publication.Refus):
                publication.publier(self.args(False), o, e)
            self.assertEqual([], o.appels, plus)

    def test_version_invalide_refus(self):
        e = self.env()
        a = self.args()
        a.version = '0.6.0-dev'
        with sans_bruit(), self.assertRaises(publication.Refus):
            publication.publier(a, FauxOutils(e), e)

    def test_profil_de_notarisation_absent_refus(self):
        e = self.env(PROFIL_NOTARISATION='')
        with sans_bruit(), self.assertRaises(publication.Refus):
            publication.publier(self.args(), FauxOutils(e), e)

    def test_liste_locale_absente_refus(self):
        os.remove(self.liste)
        e = self.env()
        o = FauxOutils(e)
        with sans_bruit(), self.assertRaises(publication.Refus):
            publication.publier(self.args(), o, e)
        self.assertEqual([], o.appels)


class TestGarde(Base):
    def test_garde_cheminPersonnel_dansUneRessource_refus(self):
        o = FauxOutils(self.env(), ressources={'Contents/Resources/reglages.json':
                                               ('{"dossier": "%s"}' % CHEMIN_PERSO).encode()})
        e = self.env()
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), o, e)
        self.assertIn('reglages.json', str(r.exception))
        self.assertNotIn('Essai', str(r.exception))  # le chemin planté n'est pas recopié
        # Rien n'est livré : ni archive, ni somme.
        sortie = os.path.join(self.depot, 'build', 'publication', '0.6.0')
        self.assertFalse(os.path.exists(os.path.join(sortie, 'macstatusd-0.6.0.zip')))
        self.assertFalse(os.path.exists(os.path.join(sortie, 'SHA256SUMS')))

    def test_garde_valeurDeLaListeLocale_dansUneRessource_refus(self):
        o = FauxOutils(self.env(), ressources={'Contents/Resources/notes.txt': ('par %s' % TITULAIRE).encode()})
        e = self.env()
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), o, e)
        self.assertIn('notes.txt', str(r.exception))
        self.assertEqual([], vu(str(r.exception)))
        self.assertIn('ligne 2', str(r.exception))

    def test_garde_titulaireDansLaSignatureSeulement_accepte(self):
        # Le faux nom légal vit dans la signature (retirée de la copie) et nulle part ailleurs : accepté.
        signature = ('%s (%s)' % (TITULAIRE, EQUIPE)).encode()
        o, sortie = self.publier(FauxOutils(self.env(), signature=signature))
        self.assertTrue(os.path.isfile(os.path.join(sortie, 'macstatusd-0.6.0.zip')))
        # La preuve que le nom est bien dans l'archive finale, et qu'il ne passe que parce qu'on le retire :
        with zipfile.ZipFile(os.path.join(sortie, 'macstatusd-0.6.0.zip')) as z:
            contenus = b''.join(z.read(n) for n in z.namelist())
        self.assertIn(signature, contenus)

    def test_garde_retraitDeSignatureRate_refus(self):
        o = FauxOutils(self.env(), retrait_rate=True)
        e = self.env()
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), o, e)
        self.assertIn('ne se retire pas', str(r.exception))
        sortie = os.path.join(self.depot, 'build', 'publication', '0.6.0')
        self.assertFalse(os.path.exists(os.path.join(sortie, 'macstatusd-0.6.0.zip')))
        self.assertFalse(os.path.exists(os.path.join(sortie, 'SHA256SUMS')))

    def test_garde_lit_les_motifs_sans_casse_et_sans_les_afficher(self):
        motifs = publication.motifs_liste_locale(self.liste)
        self.assertEqual(2, len(motifs))
        self.assertEqual([], vu(' '.join(m[1] for m in motifs)))
        dossier = os.path.join(self.tmp, 'copie')
        os.makedirs(dossier)
        with open(os.path.join(dossier, 'x.txt'), 'wb') as f:
            f.write(TITULAIRE.encode().upper() + b' ' + EQUIPE.lower().encode())
        self.assertEqual(['x.txt'], [t[0] for t in publication.chemins_personnels(dossier, motifs)])

    def test_garde_nom_de_fichier_personnel_tu(self):
        dossier = os.path.join(self.tmp, 'copie')
        os.makedirs(dossier)
        open(os.path.join(dossier, EQUIPE + '.txt'), 'w').close()
        trouves = publication.chemins_personnels(dossier, publication.motifs_liste_locale(self.liste))
        self.assertEqual([('(un nom de fichier)', 'une valeur de la liste locale (ligne 3)')], trouves)


class TestDeroulement(Base):
    def test_ordre_des_gestes(self):
        o, _ = self.publier()
        self.assertEqual(['assembler', 'signer', 'vérifier', 'archiver', 'notariser', 'agrafer', 'archiver',
                          'évaluer', 'valider', 'garder'], o.etapes())

    def test_signature_binaire_puis_paquet_sans_deep_ni_droits(self):
        o, sortie = self.publier()
        signatures = [c for c in o.appels if os.path.basename(c[0]) == 'codesign' and '--force' in c]
        self.assertEqual(2, len(signatures))
        self.assertTrue(signatures[0][-1].endswith('Contents/MacOS/macstatusd'))
        self.assertTrue(signatures[1][-1].endswith('.app'))
        for c in signatures:
            self.assertEqual(['--sign', EMPREINTE], c[c.index('--sign'):c.index('--sign') + 2])
            self.assertEqual('runtime', c[c.index('--options') + 1])
            self.assertIn('--timestamp', c)
            self.assertNotIn('--entitlements', c)
        for c in o.appels:
            self.assertNotIn('--deep', c)

    def test_verification_par_exigence_ecrite_dans_le_travail(self):
        o, sortie = self.publier()
        verif = [c for c in o.appels if '--verify' in c]
        self.assertEqual(1, len(verif))
        self.assertIn('--strict', verif[0])
        self.assertTrue(any(x.startswith('-R=anchor apple generic') for x in verif[0]))
        # Le travail est hors des produits et hors du dépôt : l'exigence (l'équipe) n'est pas dans build/.
        exigence = os.path.join(self.cache, 'publication', '0.6.0', 'exigence.txt')
        self.assertTrue(os.path.isfile(exigence))
        self.assertFalse(os.path.exists(os.path.join(sortie, 'exigence.txt')))

    def test_notarisation_par_le_profil_et_archive_avant_agrafe(self):
        o, _ = self.publier()
        soumission = [c for c in o.appels if c[1:3] == ['notarytool', 'submit']][0]
        self.assertEqual(['--keychain-profile', 'djoko-notarisation', '--wait', '--output-format', 'json'],
                         soumission[-5:])
        self.assertTrue(soumission[3].endswith('.zip'))
        ditto = [c for c in o.appels if os.path.basename(c[0]) == 'ditto' and '-c' in c]
        self.assertEqual(2, len(ditto))
        for c in ditto:
            # C2 : ni ressources ni attributs étendus (entrées AppleDouble « ._* ») dans l'archive.
            self.assertEqual(['-c', '-k', '--norsrc', '--noextattr', '--keepParent'], c[1:6])
        evaluer = [c for c in o.appels if os.path.basename(c[0]) == 'spctl'][0]
        self.assertEqual(['-a', '-vv', '-t', 'exec'], evaluer[1:5])

    def test_notarisation_refusee_par_apple_refus(self):
        e = self.env()
        o = FauxOutils(e, notarisation=json.dumps({'id': 'essai', 'status': 'Invalid', 'message': 'refusée'}))
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), o, e)
        self.assertNotIn('agrafer', o.etapes())
        self.assertIn('Invalid', str(r.exception))
        self.assertIn('essai', str(r.exception))

    def test_produits_de_la_publication(self):
        o, sortie = self.publier()
        self.assertEqual(os.path.join(self.depot, 'build', 'publication', '0.6.0'), sortie)
        archive = os.path.join(sortie, 'macstatusd-0.6.0.zip')
        with open(archive, 'rb') as f:
            somme = hashlib.sha256(f.read()).hexdigest()
        with open(os.path.join(sortie, 'SHA256SUMS'), encoding='utf-8') as f:
            self.assertEqual('%s  macstatusd-0.6.0.zip\n' % somme, f.read())
        # Seuls l'archive et la somme sont des produits : le travail (app signée, certificats, exigence) est ailleurs.
        self.assertEqual(['SHA256SUMS', 'macstatusd-0.6.0.zip'], sorted(os.listdir(sortie)))
        self.assertTrue(os.path.isdir(os.path.join(self.cache, 'publication', '0.6.0', 'app')))
        assembleur = [c for c in o.appels if os.path.basename(c[0]) == 'bash'][0]
        self.assertEqual(['--signer', '-'], assembleur[2:4])
        self.assertNotIn('--identifiant', assembleur)

    def test_repetition_identite_et_dossier(self):
        o, sortie = self.publier(repetition=True)
        self.assertEqual(os.path.join(self.depot, 'build', 'repetition', '0.6.0'), sortie)
        assembleur = [c for c in o.appels if os.path.basename(c[0]) == 'bash'][0]
        self.assertEqual('com.djoko.macstatusd.repetition', assembleur[assembleur.index('--identifiant') + 1])
        self.assertEqual('macstatusd-repetition', assembleur[assembleur.index('--nom-support') + 1])
        with zipfile.ZipFile(os.path.join(sortie, 'macstatusd-0.6.0.zip')) as z:
            self.assertTrue(all(n.startswith('macstatusd-repetition.app/') for n in z.namelist()))

    def test_ad_hoc_en_repetition_sans_notarisation(self):
        o, _ = self.publier(repetition=True, IDENTITE_SIGNATURE='-', NOTARISER='0')
        self.assertEqual(['assembler', 'signer', 'vérifier', 'archiver', 'garder'], o.etapes())
        signatures = [c for c in o.appels if '--force' in c]
        for c in signatures:
            self.assertEqual('-', c[c.index('--sign') + 1])
            self.assertIn('--timestamp=none', c)
        self.assertEqual([], [c for c in o.appels if os.path.basename(c[0]) in ('security', 'openssl')])

    def test_droits_inattendus_refus(self):
        for xml in (plistlib.dumps({'com.apple.security.get-task-allow': True}),
                    plistlib.dumps({'com.apple.security.cs.allow-jit': True})):
            e = self.env()
            o = FauxOutils(e, droits=xml.decode())
            with sans_bruit(), self.assertRaises(publication.Refus):
                publication.publier(self.args(), o, e)
            self.assertNotIn('archiver', o.etapes())

    def test_arguments(self):
        a = publication.arguments(['0.6.0', '--repetition'], self.depot)
        self.assertEqual(('0.6.0', True, self.depot), (a.version, a.repetition, a.depot))
        a = publication.arguments(['--repetition', '0.6.0'], self.depot)
        self.assertEqual(('0.6.0', True), (a.version, a.repetition))
        a = publication.arguments(['0.6.0'], self.depot)
        self.assertEqual(('0.6.0', False), (a.version, a.repetition))


# --- Correction 1 de la relecture de la tâche 8 -----------------------------------------------------------------------

SANS_CHIFFRE = 'ABCDEFGHIJ'  # une équipe sans chiffre : seule la règle de sa forme la masque


class TestFormesDuMasque(Base):
    """Un échantillon par forme, testé seul (I4, I5) : une règle supprimée du masque fait échouer son test. Les
    échantillons des formes « équipe » n'ont aucun chiffre, pour que la règle de l'équipe isolée ne masque pas à
    leur place."""

    def masque(self, texte):
        return publication.masquer_identite(texte)

    def assertMasque(self, texte, valeur, marque):
        sortie = self.masque(texte)
        self.assertEqual(0, sortie.count(valeur), 'la valeur survit dans : ' + sortie)
        self.assertIn(marque, sortie)

    def test_forme_equipe_seule_entre_parentheses(self):
        self.assertEqual('(<equipe>)', self.masque('(%s)' % SANS_CHIFFRE))

    def test_forme_equipe_en_tete_d_un_identifiant(self):
        self.assertEqual('<equipe>.com.djoko.x', self.masque(SANS_CHIFFRE + '.com.djoko.x'))

    def test_forme_equipe_isolee_avec_chiffre(self):
        self.assertEqual('equipe <equipe> seule', self.masque('equipe %s seule' % EQUIPE))

    def test_forme_libelle_sans_equipe_pour_chaque_prefixe(self):
        for prefixe in ('Developer ID Application', 'Developer ID Installer', 'Apple Development',
                        'Apple Distribution'):
            with self.subTest(prefixe):
                self.assertEqual('%s: <titulaire>' % prefixe, self.masque('%s: %s' % (prefixe, TITULAIRE)))

    def test_forme_libelle_avec_equipe_pour_chaque_prefixe(self):
        for prefixe in ('Developer ID Application', 'Developer ID Installer', 'Apple Development',
                        'Apple Distribution'):
            with self.subTest(prefixe):
                self.assertEqual('%s: <titulaire> (<equipe>)' % prefixe,
                                 self.masque('%s: %s (%s)' % (prefixe, TITULAIRE, EQUIPE)))

    def test_forme_team_identifier(self):
        for texte in ('TeamIdentifier=%s', 'TeamIdentifier = %s', '"teamId": "%s"', 'teamID=%s', 'Team ID: %s',
                      'certificate leaf[subject.OU] = %s'):
            with self.subTest(texte):
                self.assertMasque(texte % SANS_CHIFFRE, SANS_CHIFFRE, '<equipe>')

    def test_forme_echappement_retire_avant_les_motifs(self):
        self.assertEqual('X=Y', self.masque('X\\=Y'))
        self.assertMasque('TeamIdentifier\\=%s' % SANS_CHIFFRE, SANS_CHIFFRE, 'TeamIdentifier=<equipe>')

    def test_forme_champs_o_ou_uid_d_un_certificat(self):
        self.assertMasque('subject=UID=%s,OU=%s,O=%s,C=FR' % (SANS_CHIFFRE, SANS_CHIFFRE, TITULAIRE),
                          TITULAIRE, 'C=FR')
        self.assertEqual(0, self.masque('UID=%s' % SANS_CHIFFRE).count(SANS_CHIFFRE))
        self.assertEqual(0, self.masque('OU=%s' % SANS_CHIFFRE).count(SANS_CHIFFRE))
        self.assertEqual(0, self.masque('O=%s' % TITULAIRE).count(TITULAIRE))
        self.assertEqual(0, self.masque('Subject: O = %s, C = FR' % TITULAIRE).count(TITULAIRE))

    def test_forme_empreintes_de_40_et_de_64_caracteres(self):
        sha1, sha256 = EMPREINTE, EMPREINTE + EMPREINTE[:24]
        for hexa in (sha1, sha1.lower(), sha256, sha256.lower()):
            with self.subTest(len(hexa)):
                self.assertEqual('empreinte <empreinte> fin', self.masque('empreinte %s fin' % hexa))
        deux_points = ':'.join(sha1[i:i + 2] for i in range(0, 40, 2))
        self.assertEqual('<empreinte>', self.masque(deux_points))

    def test_forme_courriel(self):
        self.assertEqual('ecrire a <courriel> svp', self.masque('ecrire a %s svp' % COURRIEL))

    def test_un_texte_ordinaire_reste_intact(self):
        texte = 'app assemblée : macstatusd-repetition.app (12 fichiers) version 0.6.0 sha256 abc123'
        self.assertEqual(texte, self.masque(texte))

    def test_valeurs_de_la_liste_masquees_en_complement(self):
        publication.definir_valeurs_masquees([b'ZQXMOTIF', b'ab'])  # « ab » est trop court pour être masqué
        sortie = self.masque('le zqxmotif-dossier et ab restent : ZQXMOTIF')
        self.assertEqual(0, sortie.lower().count('zqxmotif'))
        self.assertIn('<masqué>', sortie)
        self.assertIn(' ab ', sortie)
        publication.definir_valeurs_masquees([])
        self.assertEqual('ZQXMOTIF', self.masque('ZQXMOTIF'))

    def test_publier_charge_les_valeurs_de_la_liste_dans_le_masque(self):
        self.ecrire_liste('ZQXMOTIF')
        e = self.env()
        o = FauxOutils(e, echecs={'codesign': (1, '', 'echec avec ZQXMOTIF dedans')})
        erreur = io.StringIO()
        with sans_bruit(), contextlib.redirect_stderr(erreur):
            self.assertEqual(1, publication.main(['0.6.0'], o, e, self.depot, self.cache))
        self.assertEqual(0, erreur.getvalue().lower().count('zqxmotif'))
        self.assertIn('<masqué>', erreur.getvalue())

    def test_exception_imprevue_n_affiche_que_son_type(self):
        erreur = io.StringIO()
        with mock.patch.object(publication, 'publier', side_effect=RuntimeError('SORTIEBRUTE ' + PLANTE)), \
                contextlib.redirect_stderr(erreur):
            self.assertEqual(1, publication.main(['0.6.0'], None, self.env(), self.depot, self.cache))
        self.assertIn('RuntimeError', erreur.getvalue())
        self.assertEqual(0, erreur.getvalue().count('SORTIEBRUTE'))
        self.assertEqual([], vu(erreur.getvalue()))
        self.assertNotIn('Traceback', erreur.getvalue())

    def test_echec_d_openssl_ou_de_security_est_un_refus_sans_leur_sortie(self):
        for outil in ('security', 'openssl', ('security', 'find-identity'), ('security', 'find-certificate'),
                      ('openssl', '-subject'), ('openssl', '-text')):
            with self.subTest(outil):
                e = self.env()
                o = FauxOutils(e, echecs={outil: (1, 'SORTIEBRUTE ' + PLANTE, 'SORTIEBRUTE ' + PLANTE)})
                with sans_bruit(), self.assertRaises(publication.Refus) as r:
                    publication.publier(self.args(), o, e)
                self.assertEqual(0, str(r.exception).count('SORTIEBRUTE'))
                self.assertEqual([], vu(str(r.exception)))
                self.assertNotIn('assembler', o.etapes())


class TestGardeCorrection1(Base):
    def test_garde_une_valeur_de_la_liste_dans_un_nom_n_est_jamais_recopiee(self):
        # C1 : le contenu porte un chemin personnel (motif testé en premier), le nom porte une valeur de la liste.
        self.ecrire_liste('ZQXMOTIF')
        ressources = {'Contents/Resources/notes-ZQXMOTIF.txt': CHEMIN_PERSO.encode(),
                      'Contents/Resources/ZQXMOTIF-dossier/y.txt': CHEMIN_PERSO.encode()}
        e = self.env()
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), FauxOutils(e, ressources=ressources), e)
        self.assertEqual(0, str(r.exception).lower().count('zqxmotif'), 'une valeur de la liste est recopiée')
        self.assertIn('(un nom de fichier)', str(r.exception))

    def test_garde_chemins_personnels_un_nom_qui_porte_une_valeur_est_tu(self):
        dossier = os.path.join(self.tmp, 'copie')
        os.makedirs(os.path.join(dossier, 'ZQXMOTIF-dossier'))
        with open(os.path.join(dossier, 'ZQXMOTIF-dossier', 'y.txt'), 'w') as f:
            f.write(CHEMIN_PERSO)
        motifs = [(b'/Us' + b'ers/', 'un chemin personnel'), (b'ZQXMOTIF', 'une valeur (ligne 2)')]
        trouves = publication.chemins_personnels(dossier, motifs)
        self.assertEqual(2, len(trouves))  # le dossier (son nom) et le fichier (le nom du dossier dans son chemin)
        for rel, quoi in trouves:
            self.assertEqual(0, (rel + quoi).lower().count('zqxmotif'))

    def test_garde_retrait_rate_ne_recopie_pas_une_valeur_de_la_liste(self):
        self.ecrire_liste('ZQXMOTIF')
        e = self.env()
        o = FauxOutils(e, retrait_rate=True, ressources={'Contents/MacOS/ZQXMOTIF-outil': b'x'})
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), o, e)
        self.assertIn('ne se retire pas', str(r.exception))
        self.assertEqual(0, str(r.exception).lower().count('zqxmotif'))

    def test_garde_entree_appledouble_dans_l_archive_refus(self):
        # C2 : les attributs étendus d'une copie extraite ne se lisent pas ; l'archive finale ne doit pas en porter.
        for entree in ('macstatusd.app/Contents/Resources/._icone.icns', '__MACOSX/macstatusd.app/x', '._a'):
            with self.subTest(entree):
                e = self.env()
                o = FauxOutils(e, entrees_zip={entree: b'attributs'})
                with sans_bruit(), self.assertRaises(publication.Refus) as r:
                    publication.publier(self.args(), o, e)
                self.assertIn('AppleDouble', str(r.exception))
                self.assertFalse(os.path.exists(os.path.join(self.depot, 'build', 'publication', '0.6.0')))

    def test_garde_une_archive_sans_appledouble_passe(self):
        _, sortie = self.publier(FauxOutils(self.env(), entrees_zip={'macstatusd.app/Contents/Resources/a._b': b'x'}))
        self.assertTrue(os.path.isfile(os.path.join(sortie, 'macstatusd-0.6.0.zip')))


class TestNotarisationJson(Base):
    def refuse(self, notarisation):
        e = self.env()
        o = FauxOutils(e, notarisation=notarisation)
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), o, e)
        self.assertNotIn('agrafer', o.etapes())
        return str(r.exception)

    def test_statut_invalid_refus(self):
        texte = self.refuse(json.dumps({'id': 'abc-123', 'status': 'Invalid', 'message': 'Archive rejetée'}))
        for fragment in ('abc-123', 'Invalid', 'Archive rejetée'):
            self.assertIn(fragment, texte)

    def test_message_avec_un_faux_titulaire_sort_masque_avant_toute_coupe(self):
        # L'empreinte chevauche la limite de 500 caractères : coupée avant le masque, il en resterait un morceau.
        message = 'x' * 455 + ' ' + EMPREINTE.lower() + ' ' + NOM_COMPLET + ' ' + COURRIEL
        texte = self.refuse(json.dumps({'id': 'abc', 'status': 'Invalid', 'message': message}))
        self.assertEqual([], vu(texte), texte)
        self.assertIsNone(re.search(r'[0-9a-fA-F]{10}', texte), 'un morceau d\'empreinte survit : ' + texte)
        self.assertIn('<empreinte>', texte)
        self.assertLessEqual(len(texte), 700)

    def test_sortie_qui_n_est_pas_du_json_refus_sans_la_recopier(self):
        texte = self.refuse('  status: Accepted\n SORTIEBRUTE ' + PLANTE)
        self.assertEqual(0, texte.count('SORTIEBRUTE'))
        self.assertEqual([], vu(texte))

    def test_statut_absent_ou_different_refus(self):
        for brut in (json.dumps({'id': 'a'}), json.dumps({'id': 'a', 'status': 'accepted'}), json.dumps([1])):
            with self.subTest(brut):
                self.refuse(brut)


class TestProduitsEtTravail(Base):
    def test_evaluation_en_echec_aucune_archive_dans_les_produits(self):
        # I2 : spctl refuse l'app ; l'archive n'a pas passé la garde, elle ne doit pas être dans les produits.
        e = self.env()
        o = FauxOutils(e, echecs={'spctl': (3, '', 'rejected')})
        with sans_bruit(), self.assertRaises(publication.EchecCommande):
            publication.publier(self.args(), o, e)
        produits = os.path.join(self.depot, 'build', 'publication', '0.6.0')
        self.assertEqual([], [n for n in (os.listdir(produits) if os.path.isdir(produits) else [])])
        self.assertNotIn('garder', o.etapes())

    def test_garde_refusee_rien_dans_les_produits(self):
        o = FauxOutils(self.env(), ressources={'Contents/Resources/r.json': CHEMIN_PERSO.encode()})
        e = self.env()
        with sans_bruit(), self.assertRaises(publication.Refus):
            publication.publier(self.args(), o, e)
        self.assertFalse(os.path.exists(os.path.join(self.depot, 'build', 'publication', '0.6.0')))

    def test_tout_le_travail_est_sous_la_racine_injectee(self):
        o, sortie = self.publier()
        travail = os.path.join(self.cache, 'publication', '0.6.0')
        assembleur = [c for c in o.appels if os.path.basename(c[0]) == 'bash'][0]
        self.assertTrue(assembleur[assembleur.index('--sortie') + 1].startswith(travail + os.sep))
        for c in o.appels:
            if os.path.basename(c[0]) in ('ditto', 'codesign'):
                for x in c[1:]:
                    if x.startswith(self.depot):
                        self.fail('un outil travaille dans le dépôt : ' + os.path.basename(c[0]))
        self.assertEqual([], [n for n in os.listdir(sortie) if n not in ('SHA256SUMS', 'macstatusd-0.6.0.zip')])

    def test_repetition_travail_et_produits_separes(self):
        o, sortie = self.publier(repetition=True)
        self.assertTrue(os.path.isdir(os.path.join(self.cache, 'repetition', '0.6.0', 'app')))
        self.assertEqual(['SHA256SUMS', 'macstatusd-0.6.0.zip'], sorted(os.listdir(sortie)))

    def test_la_racine_du_travail_par_defaut_est_dans_les_caches_de_l_utilisateur(self):
        a = publication.arguments(['0.6.0'], self.depot)
        self.assertTrue(a.racine_travail.endswith(os.path.join('Library', 'Caches', 'macstatusd-build')))
        a = publication.arguments(['0.6.0'], self.depot, self.cache)
        self.assertEqual(self.cache, a.racine_travail)


class TestOutilsNonRemplacables(Base):
    def test_hors_repetition_une_variable_de_remplacement_est_refusee_avant_tout_appel(self):
        for nom in ('CODESIGN', 'SECURITY', 'OPENSSL', 'DITTO', 'XCRUN', 'SPCTL', 'GARDE_LISTE'):
            with self.subTest(nom):
                e = self.env(**{nom: '/usr/bin/true'})
                o = FauxOutils(e)
                with sans_bruit(), self.assertRaises(publication.Refus) as r:
                    publication.publier(self.args(), o, e)
                self.assertIn(nom, str(r.exception))
                self.assertEqual([], o.appels)

    def test_developer_dir_est_refuse_hors_repetition_et_accepte_en_repetition(self):
        e = self.env(DEVELOPER_DIR='/essai/Developer')
        o = FauxOutils(e)
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(), o, e)
        self.assertIn('DEVELOPER_DIR', str(r.exception))
        self.assertEqual([], o.appels)
        o, _ = self.publier(repetition=True, DEVELOPER_DIR='/essai/Developer')
        self.assertTrue(o.appels)

    def test_les_outils_s_appellent_par_chemin_absolu(self):
        o = publication.Outils({})
        attendus = {'codesign': '/usr/bin/codesign', 'security': '/usr/bin/security', 'ditto': '/usr/bin/ditto',
                    'xcrun': '/usr/bin/xcrun', 'spctl': '/usr/sbin/spctl', 'openssl': '/usr/bin/openssl'}
        for attribut, chemin in attendus.items():
            self.assertEqual(chemin, getattr(o, attribut))
            self.assertTrue(os.path.isfile(chemin), chemin)  # présent sur la machine (jamais lancé ici)

    def test_les_variables_ne_remplacent_les_outils_qu_en_repetition(self):
        e = {'XCRUN': '/essai/xcrun', 'GARDE_LISTE': '/essai/liste'}
        self.assertEqual('/usr/bin/xcrun', publication.Outils(e).xcrun)
        self.assertEqual('/essai/xcrun', publication.Outils(e, remplacables=True).xcrun)

    def test_l_assembleur_s_appelle_par_chemin_absolu(self):
        o, _ = self.publier()
        self.assertEqual('/bin/bash', [c for c in o.appels if c[1].endswith('assembler-app.sh')][0][0])

    def test_en_repetition_la_liste_de_remplacement_est_honoree(self):
        autre = os.path.join(self.tmp, 'autre-liste.txt')
        with open(autre, 'w', encoding='utf-8') as f:
            f.write('ZQXMOTIF\n')
        e = self.env(GARDE_LISTE=autre, IDENTITE_SIGNATURE='-', NOTARISER='0')
        o = FauxOutils(e, ressources={'Contents/Resources/n.txt': b'avec zqxmotif'})
        with sans_bruit(), self.assertRaises(publication.Refus) as r:
            publication.publier(self.args(True), o, e)
        self.assertIn('ligne 1', str(r.exception))


if __name__ == '__main__':
    unittest.main()
