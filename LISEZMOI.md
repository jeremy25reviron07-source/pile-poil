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

## 4. Boutique (Stripe)
1. Supabase → SQL Editor → coller `boutique.sql` → Run.
2. Supabase → Edge Functions → Deploy a new function → Via Editor → nom `stripe-webhook` → coller `supabase/functions/stripe-webhook/index.ts` → Deploy. Dans les réglages de la fonction, **désactiver « Verify JWT »** (Stripe n'envoie pas de jeton Supabase).
3. Stripe → Catalogue de produits : 5 produits, paiement unique en EUR : 2,99 / 1,99 / 4,99 / 9,99 / 19,99.
4. Stripe → Liens de paiement : un lien par produit, quantité fixe, codes promo désactivés, après paiement → rediriger vers `https://pile-poil-jeu.netlify.app/?achat=ok`.
5. Stripe → Développeurs → Webhooks → ajouter un endpoint : `https://bcysxilkhnpayvfhlkju.supabase.co/functions/v1/stripe-webhook`, événements `checkout.session.completed` et `checkout.session.async_payment_succeeded`.
6. Supabase → Edge Functions → Secrets : `STRIPE_SECRET_KEY` (sk_…) et `STRIPE_WEBHOOK_SECRET` (whsec_…). Ces deux clés ne doivent JAMAIS aller dans GitHub ni dans config.js.
7. Coller les 5 liens de paiement dans `config.js` (rubrique `shop`).
8. Tester en mode test Stripe avec la carte 4242 4242 4242 4242.

## Mise à jour automatique des joueurs
Avant chaque publication : `python3 maj_version.py` (change `APP_VER` dans index.html et `version.txt`).
Le jeu vérifie `version.txt` à chaque retour au premier plan et toutes les 2 min, et se recharge tout seul quand le joueur est dans un menu (jamais en pleine partie).
