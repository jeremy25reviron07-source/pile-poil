-- =====================================================================
--  PILE POIL — BOUTIQUE : achats Stripe (à coller dans SQL Editor → Run)
-- =====================================================================
create table if not exists public.purchases (
  session_id text primary key,                 -- identifiant Stripe du paiement (évite les doublons)
  pid        uuid not null,                    -- identifiant secret de l'appareil du joueur
  coins      int  not null check (coins between 0 and 100000),
  item       text,                             -- objet exclusif éventuel (ex : 'chrome')
  amount     int,                              -- montant payé en centimes
  claimed    boolean not null default false,   -- pièces déjà créditées dans le jeu ?
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);
-- aucune lecture ni écriture publique : seul le webhook Stripe (clé serveur) écrit ici
alter table public.purchases enable row level security;
grant select, insert, update on public.purchases to service_role;
create index if not exists purchases_pid_idx on public.purchases (pid) where not claimed;

-- le jeu récupère les pièces achetées sur cet appareil, une seule fois
create or replace function public.claim_purchases(p_pid uuid)
returns json language plpgsql security definer set search_path = public as $$
declare total int; its text[];
begin
  with x as (
    update purchases set claimed = true, claimed_at = now()
     where pid = p_pid and not claimed
    returning coins, item
  )
  select coalesce(sum(coins), 0), coalesce(array_agg(item) filter (where item is not null), '{}')
    into total, its from x;
  return json_build_object('coins', total, 'items', its);
end $$;
revoke all on function public.claim_purchases(uuid) from public;
grant execute on function public.claim_purchases(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
