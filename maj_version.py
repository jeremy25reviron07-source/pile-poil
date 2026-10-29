# Lancer avant chaque publication : python3 maj_version.py
# Change le numéro de version : les joueurs reçoivent la mise à jour automatiquement, sans réinstaller le jeu.
import re, time
v = time.strftime('%Y%m%d%H%M'); f = 'index.html'; s = open(f).read()
s, n = re.subn(r"const APP_VER = '\d+';", f"const APP_VER = '{v}';", s); assert n == 1
open(f, 'w').write(s); open('version.txt', 'w').write(v + '\n'); print('version', v)
