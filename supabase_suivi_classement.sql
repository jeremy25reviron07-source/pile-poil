-- PILE POIL — à coller dans Supabase → SQL Editor → New query → Run (une seule fois)

-- 1. Suivi anonyme des joueurs
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
drop policy if exists track_insert on public.track;
create policy track_insert on public.track for insert to anon, authenticated with check (true);

-- 2. Classement : niveau le plus haut atteint dans le pays (51 = Master réussi)
alter table public.career_reg add column if not exists prog smallint not null default 0;
create or replace function public.set_progress(p_name text, p_token uuid, p_region text, p_prog int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(p_region, '') not in ('fr', 'jp', 'eg') then return 0; end if;
  if not name_allowed(p_name, p_token) then return 0; end if;
  update career_reg set prog = greatest(prog, least(greatest(p_prog, 0), 51))
   where name = p_name and region = p_region;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.set_progress(text, uuid, text, int) to anon, authenticated;
