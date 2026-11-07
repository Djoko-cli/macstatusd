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
import os
import plistlib
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
                 signature=b'signature', notarisation='  id: essai\n  status: Accepted\n', echec_signature=None,
                 droits=''):
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

    def executer(self, cmd, entree=None):
        self.appels.append(list(cmd))
        nom = os.path.basename(cmd[0])
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
        self.liste = os.path.join(self.tmp, 'liste.txt')
        with open(self.liste, 'w', encoding='utf-8') as f:
            f.write('# valeurs d\'essai\n%s\n%s\n' % (TITULAIRE, EQUIPE))

    def env(self, **plus):
        """L'environnement neutre, recalculé à chaque appel."""
        e = {'PATH': '/usr/bin:/bin', 'HOME': '/home/exemple', 'NOTARISER': '1',
             'PROFIL_NOTARISATION': 'djoko-notarisation', 'GARDE_LISTE': self.liste}
        e.update(plus)
        return e

    def args(self, repetition=False):
        return SimpleNamespace(version='0.6.0', repetition=repetition, depot=self.depot)

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

    def test_masque_le_texte_d_une_exception(self):
        # Une commande qui échoue : son erreur, sa sortie et sa ligne de commande passent par le masque.
        o = FauxOutils(self.env(), echec_signature=PLANTE)
        sortie, erreur = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(sortie), contextlib.redirect_stderr(erreur):
            code = publication.main(['0.6.0'], o, self.env(), self.depot)
        self.assertEqual(1, code)
        self.assertEqual([], vu(erreur.getvalue() + sortie.getvalue()), erreur.getvalue())
        self.assertIn('<equipe>', erreur.getvalue())
        # Un refus qui nommerait une identité : même masque.
        erreur = io.StringIO()
        with mock.patch.object(publication, 'publier', side_effect=publication.Refus(PLANTE)), \
                contextlib.redirect_stderr(erreur):
            self.assertEqual(1, publication.main(['0.6.0'], None, self.env(), self.depot))
        self.assertEqual([], vu(erreur.getvalue()), erreur.getvalue())
        # Une erreur du système (OSError) : même masque.
        erreur = io.StringIO()
        with mock.patch.object(publication, 'publier', side_effect=OSError(PLANTE)), \
                contextlib.redirect_stderr(erreur):
            self.assertEqual(1, publication.main(['0.6.0'], None, self.env(), self.depot))
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
        e = self.env(GARDE_LISTE=os.path.join(self.tmp, 'absente.txt'))
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

    def test_verification_par_exigence_ecrite_dans_build(self):
        o, sortie = self.publier()
        verif = [c for c in o.appels if '--verify' in c]
        self.assertEqual(1, len(verif))
        self.assertIn('--strict', verif[0])
        self.assertTrue(any(x.startswith('-R=anchor apple generic') for x in verif[0]))
        exigence = os.path.join(sortie, 'travail', 'exigence.txt')
        self.assertTrue(os.path.isfile(exigence))
        self.assertIn(os.path.join(self.depot, 'build') + os.sep, exigence)

    def test_notarisation_par_le_profil_et_archive_avant_agrafe(self):
        o, _ = self.publier()
        soumission = [c for c in o.appels if c[1:3] == ['notarytool', 'submit']][0]
        self.assertEqual(['--keychain-profile', 'djoko-notarisation', '--wait'], soumission[-3:])
        self.assertTrue(soumission[3].endswith('.zip'))
        ditto = [c for c in o.appels if os.path.basename(c[0]) == 'ditto' and '-c' in c]
        self.assertEqual(2, len(ditto))
        for c in ditto:
            self.assertEqual(['-c', '-k', '--keepParent'], c[1:4])
        evaluer = [c for c in o.appels if os.path.basename(c[0]) == 'spctl'][0]
        self.assertEqual(['-a', '-vv', '-t', 'exec'], evaluer[1:5])

    def test_notarisation_refusee_par_apple_refus(self):
        e = self.env()
        o = FauxOutils(e, notarisation='  id: essai\n  status: Invalid\n')
        with sans_bruit(), self.assertRaises(publication.Refus):
            publication.publier(self.args(), o, e)
        self.assertNotIn('agrafer', o.etapes())

    def test_produits_de_la_publication(self):
        o, sortie = self.publier()
        self.assertEqual(os.path.join(self.depot, 'build', 'publication', '0.6.0'), sortie)
        archive = os.path.join(sortie, 'macstatusd-0.6.0.zip')
        with open(archive, 'rb') as f:
            somme = hashlib.sha256(f.read()).hexdigest()
        with open(os.path.join(sortie, 'SHA256SUMS'), encoding='utf-8') as f:
            self.assertEqual('%s  macstatusd-0.6.0.zip\n' % somme, f.read())
        self.assertEqual(['SHA256SUMS', 'macstatusd-0.6.0.zip', 'travail'], sorted(os.listdir(sortie)))
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


if __name__ == '__main__':
    unittest.main()
