#!/usr/bin/env python3
"""Récepteur HTTP minimal pour le banc du lot 4.

Il sert de faux récepteur de webhook : il répond 200 sans corps à toute requête et
écrit une ligne par requête dans un journal, pour voir ce que le daemon envoie, et
quand. Bibliothèque standard seulement.

    python3 -I diagnostics/recepteur-banc.py --port P --journal FICHIER [--hote [ADRESSE]]

  --port P          port d'écoute (0 : un port libre, affiché au démarrage)
  --journal FICHIER journal en ajout (créé en 600 ; son dossier l'est en 700 s'il manque)
  --hote [ADRESSE]  par défaut, écoute sur 127.0.0.1 seulement. Sans valeur, --hote écoute
                    sur toutes les interfaces (0.0.0.0) ; avec une valeur, sur cette adresse.

Une ligne par requête : heure locale HH:MM:SS.mmm, méthode, chemin avec requête, puis
« corps= » suivi du corps (512 octets au plus). Aucun en-tête n'est journalisé : un jeton
pourrait s'y trouver. Arrêt propre sur SIGINT ou SIGTERM.
"""

import argparse
import os
import signal
import sys
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TAILLE_CORPS_JOURNAL = 512  # octets du corps recopiés dans le journal
LECTURE_MAX = 1 << 20  # on lit (et on jette) au plus 1 Mio de corps par requête
DELAI_CONNEXION = 10  # secondes d'inactivité tolérées sur une connexion

_verrou = threading.Lock()
_journal_fd = -1


def heure_locale():
    maintenant = datetime.now()
    return maintenant.strftime("%H:%M:%S.") + f"{maintenant.microsecond // 1000:03d}"


def assainir(octets):
    """Texte lisible sur une seule ligne : les caractères de contrôle sont échappés."""
    texte = octets.decode("utf-8", errors="replace")
    sortie = []
    for caractere in texte:
        code = ord(caractere)
        if caractere == "\n":
            sortie.append("\\n")
        elif caractere == "\r":
            sortie.append("\\r")
        elif caractere == "\t":
            sortie.append("\\t")
        elif code < 0x20 or code == 0x7F:
            sortie.append(f"\\x{code:02x}")
        else:
            sortie.append(caractere)
    return "".join(sortie)


def ecrire_ligne(ligne):
    """Une ligne dans le journal (une seule écriture, en ajout), et sur la sortie standard."""
    donnees = (ligne + "\n").encode("utf-8", errors="replace")
    with _verrou:
        os.write(_journal_fd, donnees)
        try:
            print(ligne, flush=True)
        except (OSError, ValueError):
            pass  # sortie standard fermée : le journal suffit


class Gestionnaire(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = DELAI_CONNEXION

    def version_string(self):
        return "recepteur-banc"

    def log_message(self, *_arguments):
        """Rien sur la sortie d'erreur : ni adresse du client, ni ligne de requête en double."""

    def _lire_corps_fixe(self):
        try:
            longueur = max(0, int(self.headers.get("Content-Length", "0")))
        except ValueError:
            longueur = 0
        garde, total, restant = b"", 0, min(longueur, LECTURE_MAX)
        while restant > 0:
            bloc = self.rfile.read(min(restant, 65536))
            if not bloc:
                break
            garde += bloc[: max(0, TAILLE_CORPS_JOURNAL - len(garde))]
            total += len(bloc)
            restant -= len(bloc)
        return garde, total

    def _lire_corps_decoupe(self):
        """Corps en Transfer-Encoding: chunked, lu jusqu'au dernier morceau."""
        garde, total = b"", 0
        while total < LECTURE_MAX:
            ligne = self.rfile.readline(1024).strip()
            try:
                taille = int(ligne.split(b";")[0], 16)
            except ValueError:
                break
            if taille == 0:
                while self.rfile.readline(1024).strip():  # lignes de fin (trailers)
                    pass
                break
            reste = taille
            while reste > 0:
                bloc = self.rfile.read(min(reste, 65536))
                if not bloc:
                    return garde, total
                garde += bloc[: max(0, TAILLE_CORPS_JOURNAL - len(garde))]
                total += len(bloc)
                reste -= len(bloc)
            self.rfile.readline(1024)  # fin du morceau
        return garde, total

    def repondre(self):
        try:
            if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
                garde, total = self._lire_corps_decoupe()
            else:
                garde, total = self._lire_corps_fixe()
            corps = assainir(garde)
            if total > TAILLE_CORPS_JOURNAL:
                corps += f" [tronqué : {total} octets au total]"
            # http.server décode la ligne de requête en latin-1 : on remet les octets d'origine.
            chemin = assainir(self.path.encode("latin-1", errors="replace"))
            ecrire_ligne(f"{heure_locale()} {assainir(self.command.encode())} {chemin} corps={corps}")
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
        except OSError:
            self.close_connection = True  # client parti en route ou trop lent : rien à répondre

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = repondre


class Serveur(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, requete, adresse_client):
        # Une ligne courte à la place de la trace complète ; le journal reste réservé aux requêtes.
        sys.stderr.write(f"erreur de connexion ignorée : {sys.exc_info()[0].__name__}\n")


def lire_arguments(arguments=None):
    analyseur = argparse.ArgumentParser(description="Récepteur HTTP du banc : répond 200 et journalise.")
    analyseur.add_argument("--port", type=int, required=True, help="port d'écoute (0 : un port libre)")
    analyseur.add_argument("--journal", required=True, help="fichier journal, ouvert en ajout")
    analyseur.add_argument("--hote", nargs="?", const="0.0.0.0", default="127.0.0.1", metavar="ADRESSE",
                           help="adresse d'écoute ; sans valeur, toutes les interfaces "
                                "(désactivé par défaut : 127.0.0.1 seulement)")
    lues = analyseur.parse_args(arguments)
    if not 0 <= lues.port <= 65535:
        analyseur.error("--port doit être compris entre 0 et 65535")
    return lues


def ouvrir_journal(chemin):
    dossier = os.path.dirname(os.path.abspath(chemin))
    os.makedirs(dossier, mode=0o700, exist_ok=True)
    return os.open(chemin, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)


def arreter(_numero, _cadre):
    raise SystemExit(0)  # interrompt serve_forever() ; le « finally » ferme proprement


def main():
    global _journal_fd
    lues = lire_arguments()
    try:
        _journal_fd = ouvrir_journal(lues.journal)
    except OSError as erreur:
        sys.exit(f"journal inutilisable : {erreur.strerror}")
    try:
        serveur = Serveur((lues.hote, lues.port), Gestionnaire)
    except OSError as erreur:
        sys.exit(f"écoute impossible sur {lues.hote}:{lues.port} : {erreur.strerror}")
    if lues.hote not in ("127.0.0.1", "localhost", "::1"):
        sys.stderr.write(f"ATTENTION : écoute sur {lues.hote} : toute machine qui l'atteint peut écrire "
                         "dans le journal.\n")
    signal.signal(signal.SIGTERM, arreter)
    signal.signal(signal.SIGINT, arreter)
    adresse, port = serveur.server_address[:2]
    print(f"Récepteur du banc : écoute sur {adresse}:{port}, journal {os.path.abspath(lues.journal)}", flush=True)
    try:
        serveur.serve_forever()
    except SystemExit:
        pass
    finally:
        serveur.server_close()
        print("Récepteur du banc : arrêté", flush=True)


if __name__ == "__main__":
    main()
