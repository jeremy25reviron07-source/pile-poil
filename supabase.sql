-- =====================================================================
--  PILE POIL — base Supabase (à coller dans SQL Editor → Run)
-- =====================================================================
create table if not exists public.scores (
  day        date not null,
  name       text not null check (char_length(name) between 2 and 16),
  score      int  not null check (score between 0 and 60000),
  passed     int  not null check (passed between 0 and 5),
  perfects   int  not null default 0 check (perfects between 0 and 5),
  created_at timestamptz not null default now(),
  primary key (day, name)
);
create table if not exists public.duels (
  id          text primary key,
  name        text not null check (char_length(name) between 2 and 16),
  score       int  not null check (score between 0 and 60000),
  passed      int  not null check (passed between 0 and 5),
  perfects    int  not null default 0,
  seed        bigint not null,
  reply_name  text check (reply_name is null or char_length(reply_name) between 2 and 16),
  reply_score int  check (reply_score is null or reply_score between 0 and 60000),
  created_at  timestamptz not null default now()
);

-- Lecture publique, aucune écriture directe : tout passe par les fonctions ci-dessous
alter table public.scores enable row level security;
alter table public.duels  enable row level security;
drop policy if exists "lecture scores" on public.scores;
drop policy if exists "lecture duels"  on public.duels;
create policy "lecture scores" on public.scores for select using (true);
create policy "lecture duels"  on public.duels  for select using (true);

-- Défi du jour : garde le meilleur score par pseudo et renvoie le rang
create or replace function public.submit_score(p_day date, p_name text, p_score int, p_passed int, p_perfects int)
returns json language plpgsql security definer set search_path = public as $$
declare r int; t int; best int;
begin
  if p_day not between current_date - 1 and current_date + 1 then raise exception 'Date invalide'; end if;
  insert into scores(day, name, score, passed, perfects) values (p_day, p_name, p_score, p_passed, p_perfects)
  on conflict (day, name) do update
    set score = excluded.score, passed = excluded.passed, perfects = excluded.perfects, created_at = now()
    where excluded.score > scores.score;
  select score into best from scores where day = p_day and name = p_name;
  select count(*) + 1 into r from scores where day = p_day and score > best;
  select count(*) into t from scores where day = p_day;
  return json_build_object('rank', r, 'total', t);
end $$;

-- Duel différé : création et réponse
create or replace function public.create_duel(p_name text, p_score int, p_passed int, p_perfects int, p_seed bigint)
returns text language plpgsql security definer set search_path = public as $$
declare new_id text := substr(md5(random()::text || clock_timestamp()::text), 1, 10);
begin
  insert into duels(id, name, score, passed, perfects, seed) values (new_id, p_name, p_score, p_passed, p_perfects, p_seed);
  return new_id;
end $$;

create or replace function public.reply_duel(p_id text, p_name text, p_score int, p_passed int, p_perfects int)
returns public.duels language plpgsql security definer set search_path = public as $$
declare d public.duels;
begin
  update duels set reply_name = p_name, reply_score = p_score
   where id = p_id and (reply_score is null or p_score > reply_score);
  select * into d from duels where id = p_id;
  if d.id is null then raise exception 'Duel introuvable'; end if;
  return d;
end $$;

grant execute on function public.submit_score(date, text, int, int, int) to anon;
grant execute on function public.create_duel(text, int, int, int, bigint) to anon;
grant execute on function public.reply_duel(text, text, int, int, int) to anon;

-- ---------- Classement mondial (carrière) ----------
create table if not exists public.career (
  name       text primary key check (char_length(name) between 2 and 16),
  score      int  not null check (score between 0 and 600000),
  level      int  not null check (level between 1 and 50),
  updated_at timestamptz not null default now()
);
alter table public.career enable row level security;
drop policy if exists "lecture career" on public.career;
create policy "lecture career" on public.career for select using (true);
create index if not exists career_score_idx on public.career (score desc);

-- Garde le meilleur score de carrière de chaque pseudo et renvoie le rang mondial
create or replace function public.submit_career(p_name text, p_score int, p_level int)
returns json language plpgsql security definer set search_path = public as $$
declare best int; r int; t int;
begin
  -- anti-triche de base : score impossible pour le niveau atteint
  if p_score > 225 * p_level * (p_level + 1) then raise exception 'Score refusé'; end if;
  insert into career(name, score, level) values (p_name, p_score, p_level)
  on conflict (name) do update
    set score = excluded.score, level = excluded.level, updated_at = now()
    where excluded.score > career.score;
  select score into best from career where name = p_name;
  select count(*) + 1 into r from career where score > best;
  select count(*) into t from career;
  return json_build_object('rank', r, 'total', t, 'best', best);
end $$;
grant execute on function public.submit_career(text, int, int) to anon;

-- Droits de lecture explicites + rechargement de l'API
grant usage on schema public to anon, authenticated;
grant select on public.scores, public.duels, public.career to anon, authenticated;
notify pgrst, 'reload schema';
