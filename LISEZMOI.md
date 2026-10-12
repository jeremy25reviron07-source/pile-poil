# PILE POIL — version en ligne (Netlify + Supabase)

Le jeu est un site statique hébergé sur **Netlify**. Tout le multijoueur passe par un serveur unique : **Supabase**.
- Défi du jour + classement → table `scores`
- Duel différé → table `duels`
- Duel en direct → Supabase Realtime (salons à code, présence des joueurs)

Sans clés Supabase, le jeu fonctionne en **mode démo** : scores sur l'appareil, et duel en direct possible entre deux onglets du même navigateur (pratique pour tester).

## 1. Créer le serveur Supabase (5 min, gratuit)
1. https://supabase.com → « Start your project » → « New project ».
   Nom : `pile-poil` · Région : **Europe (Paris ou Francfort)** · note le mot de passe.
2. Menu **SQL Editor** → « New query » → colle tout le fichier `supabase.sql` → **Run**.
3. Menu **Project Settings → API** : copie
   - **Project URL** (https://xxxx.supabase.co)
   - **anon public key** (longue clé qui commence par `eyJ`)
4. Ouvre `public/config.js` et colle les deux valeurs entre les guillemets.
5. Menu **Realtime → Settings** : vérifie que « Allow public access » est activé (c'est le réglage par défaut).

La clé « anon » est faite pour être publique : la base n'accepte que les lectures et les trois fonctions du fichier SQL.

## 2. Mettre le jeu en ligne sur Netlify
1. https://app.netlify.com → **Add new site → Deploy manually**.
2. Glisse le dossier **`public`** dans la zone de dépôt. C'est en ligne.
3. « Site configuration → Change site name » pour une adresse du type `pile-poil.netlify.app`.
(Variante : passer par GitHub pour que chaque mise à jour se déploie toute seule.)

## 3. Tester
- **Duel en direct** : « DUEL EN DIRECT » → pseudo → « Créer un salon » → « Copier le lien » → envoie-le. Ton ami ouvre le lien, met son pseudo, « Rejoindre » : compte à rebours, puis vous jouez les mêmes 5 chantiers en même temps. Tu vois sa grue en miniature, son score et ses vies en direct. À la fin : victoire/défaite et « REVANCHE ».
- **Duel différé** : « DUEL DIFFÉRÉ » → joue → envoie le lien → ton ami joue plus tard les mêmes chantiers.
- **Défi du jour** : même tirage pour tout le monde, classement du jour.

## Limites connues
- Pseudo par appareil, pas de comptes (Supabase Auth pourra s'ajouter).
- Anti-triche de base : limites en base, mais un joueur qui modifie son navigateur peut tricher. À renforcer avant une grosse diffusion.
- Offre gratuite Supabase : 200 joueurs connectés en même temps en temps réel. Largement suffisant pour démarrer.
