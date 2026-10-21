-- PILE POIL — suivi anonyme des joueurs (à coller dans Supabase → SQL Editor → Run)
create table if not exists public.track (
  id bigserial primary key,
  at timestamptz not null default now(),
  did text not null check (length(did) between 8 and 40),
  src text check (length(src) <= 30),
  ev text not null check (ev in ('open','start','win','fail','worker','shop','buy')),
  reg text check (reg in ('fr','jp','eg','hw')),
  lvl smallint check (lvl between 0 and 999),
  mode text check (length(mode) <= 12)
);
create index if not exists track_at on public.track (at);
create index if not exists track_did on public.track (did);
alter table public.track enable row level security;
-- les joueurs peuvent seulement ajouter des lignes ; personne ne peut les lire depuis le jeu
drop policy if exists track_insert on public.track;
create policy track_insert on public.track for insert to anon, authenticated with check (true);
