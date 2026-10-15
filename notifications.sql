-- =====================================================================
--  PILE POIL — NOTIFICATIONS (1 par jour maximum, jamais la nuit, s'arrêtent si le joueur part)
--  Les clés de sécurité sont créées et gardées par Supabase lui-même : elles ne sortent jamais.
-- =====================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- abonnements des joueurs qui ont dit « oui »
create table if not exists push_subs (
  pid text primary key,                     -- identifiant de l'appareil (save.pid)
  name_lower text,                          -- compte connecté (pour le parrainage)
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  prefs jsonb not null default '{"caisse": true, "duel": true, "parrain": true, "news": false}',
  duels uuid[] not null default '{}',       -- jetons des duels « chacun son tour » de l'appareil
  last_play date,                           -- dernier jour joué (heure de Paris)
  last_sent date,                           -- dernier jour où une notification est partie
  state jsonb not null default '{}',        -- ce qui a déjà été annoncé (duel, primes, rappels)
  sent int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table push_subs enable row level security;

-- clés privées : aucune lecture possible depuis le jeu ou le site
create table if not exists push_keys (id int primary key default 1 check (id = 1), public_key text, private_key text, cron_key text not null default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));
alter table push_keys enable row level security;
insert into push_keys (id) values (1) on conflict do nothing;

create or replace function push_today() returns date language sql stable as $$ select (now() at time zone 'Europe/Paris')::date $$;

-- clé publique (nécessaire au jeu pour s'abonner)
create or replace function push_public_key() returns text language sql stable security definer set search_path = public as $$
  select public_key from push_keys where id = 1
$$;

-- le joueur accepte : on enregistre son abonnement et ses choix
create or replace function push_save(p_pid text, p_sub jsonb, p_prefs jsonb, p_token uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ep text := p_sub->>'endpoint'; k1 text := p_sub->'keys'->>'p256dh'; k2 text := p_sub->'keys'->>'auth'; nm text;
begin
  if p_pid is null or length(p_pid) < 8 or ep is null or ep !~ '^https://' or k1 is null or k2 is null or length(ep) > 1000 then raise exception 'Abonnement invalide'; end if;
  if p_token is not null then select name_lower into nm from accounts where token = p_token; end if;
  delete from push_subs where endpoint = ep and pid <> p_pid;
  insert into push_subs (pid, name_lower, endpoint, p256dh, auth, prefs, last_play)
  values (p_pid, nm, ep, k1, k2, coalesce(p_prefs, '{"caisse": true, "duel": true, "parrain": true, "news": false}'), push_today())
  on conflict (pid) do update set endpoint = excluded.endpoint, p256dh = excluded.p256dh, auth = excluded.auth,
    prefs = coalesce(p_prefs, push_subs.prefs), name_lower = coalesce(nm, push_subs.name_lower), updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- changement des interrupteurs dans Réglages
create or replace function push_prefs(p_pid text, p_prefs jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update push_subs set prefs = jsonb_build_object(
      'caisse', coalesce((p_prefs->>'caisse')::boolean, true), 'duel', coalesce((p_prefs->>'duel')::boolean, true),
      'parrain', coalesce((p_prefs->>'parrain')::boolean, true), 'news', coalesce((p_prefs->>'news')::boolean, false)),
    updated_at = now() where pid = p_pid;
  return jsonb_build_object('ok', found);
end $$;

-- « Tout couper »
create or replace function push_off(p_pid text) returns void language sql security definer set search_path = public as $$
  delete from push_subs where pid = p_pid
$$;

-- le joueur a joué aujourd'hui (et ses duels en cours)
create or replace function push_seen(p_pid text, p_duels uuid[] default null, p_token uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  if p_token is not null then select name_lower into nm from accounts where token = p_token; end if;
  update push_subs set last_play = push_today(), duels = coalesce(p_duels[1:30], duels), name_lower = coalesce(nm, name_lower),
    state = state - 'rappel', updated_at = now()
  where pid = p_pid;
end $$;

-- ce qu'il faut envoyer maintenant (appelé par le programme d'envoi, jamais par le jeu)
create or replace function push_due(p_hour int) returns setof jsonb
language plpgsql security definer set search_path = public as $$
declare s push_subs; d date := push_today(); inactif int; msg jsonb; du td_duels; adv text; n int; f text; cr crates;
begin
  if p_hour < 9 or p_hour >= 21 then return; end if;                       -- jamais la nuit
  for s in select * from push_subs where last_sent is distinct from d loop     -- 1 par jour maximum
    msg := null; inactif := coalesce(d - s.last_play, 0);
    if inactif > 30 then continue; end if;
    -- 1. duel : c'est son tour (une seule fois par coup joué)
    if coalesce((s.prefs->>'duel')::boolean, true) and cardinality(s.duels) > 0 then
      select * into du from td_duels t where t.status = 'play'
        and ((t.p1_token = any(s.duels) and t.turn = 1) or (t.p2_token = any(s.duels) and t.turn = 2))
        and t.updated_at > coalesce((s.state->>'duel_at')::timestamptz, '-infinity') and t.updated_at > now() - interval '3 days'
      order by t.updated_at desc limit 1;
      if found then
        adv := case when du.p1_token = any(s.duels) then du.p2_name else du.p1_name end;
        msg := jsonb_build_object('kind', 'duel', 'title', '⚔️ ' || coalesce(adv, 'Ton adversaire') || ' a joué, à toi !', 'body', 'C''est ton tour dans votre duel. Tu fais mieux ?',
          'url', '/?tour=' || du.code, 'tag', 'duel', 'state', jsonb_build_object('duel_at', du.updated_at));
      end if;
    end if;
    -- 2. parrainage : une prime attend (seulement quand il y en a une nouvelle)
    if msg is null and coalesce((s.prefs->>'parrain')::boolean, true) and s.name_lower is not null then
      select count(*), max(a.name) into n, f from referrals r join accounts a on a.name_lower = r.filleul
        where r.parrain = s.name_lower and not r.paid and ref_lvl(a.save) >= 10;
      if n > coalesce((s.state->>'parr_n')::int, 0) then
        msg := jsonb_build_object('kind', 'parrain', 'title', '💰 Prime de parrain : +' || (250 * n) || ' pièces',
          'body', case when n > 1 then n || ' filleuls ont atteint le niveau 10. Viens encaisser !' else f || ' vient d''atteindre le niveau 10. Viens encaisser !' end,
          'url', '/', 'tag', 'parrain', 'state', jsonb_build_object('parr_n', n));
      end if;
    end if;
    -- 3. caisse du jour : vers 18 h, s'il n'a pas joué aujourd'hui ; joueur parti : rappel à 2, 5 et 12 jours, puis plus rien
    if msg is null and p_hour = 18 and coalesce((s.prefs->>'caisse')::boolean, true) and inactif >= 1 and (inactif = 1 or inactif in (2, 5, 12)) then
      select * into cr from crates where pid = s.pid;
      if not found or cr.last_day is null or cr.last_day < d then
        msg := jsonb_build_object('kind', 'caisse', 'title', 'Ta caisse du jour t''attend 🎁',
          'body', case when found and cr.last_day = d - 1 and cr.streak > 1 then 'Série de ' || cr.streak || ' jours : ne la casse pas !'
                       when inactif >= 5 then 'Ton chantier t''attend, grutier. Une caisse gratuite est prête.'
                       else 'Une caisse gratuite t''attend sur l''accueil.' end,
          'url', '/', 'tag', 'caisse', 'state', '{}'::jsonb);
      end if;
    end if;
    if msg is not null then
      return next msg || jsonb_build_object('pid', s.pid, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth);
    end if;
  end loop;
end $$;

-- après l'envoi : on note la journée (et on retire les abonnements morts)
create or replace function push_mark(p_pid text, p_ok boolean, p_state jsonb, p_gone boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_gone then delete from push_subs where pid = p_pid; return; end if;
  if p_ok then update push_subs set last_sent = push_today(), sent = sent + 1, state = state || coalesce(p_state, '{}'), updated_at = now() where pid = p_pid; end if;
end $$;

-- le programme d'envoi lit/écrit ses clés ici (jamais accessible depuis le jeu)
create or replace function push_keys_get() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('public_key', public_key, 'private_key', private_key, 'cron_key', cron_key) from push_keys where id = 1
$$;
create or replace function push_keys_set(p_public text, p_private text) returns void language sql security definer set search_path = public as $$
  update push_keys set public_key = p_public, private_key = p_private where id = 1 and public_key is null
$$;

revoke all on function push_public_key() from public;
revoke all on function push_save(text, jsonb, jsonb, uuid) from public;
revoke all on function push_prefs(text, jsonb) from public;
revoke all on function push_off(text) from public;
revoke all on function push_seen(text, uuid[], uuid) from public;
revoke all on function push_due(int) from public;
revoke all on function push_mark(text, boolean, jsonb, boolean) from public;
revoke all on function push_keys_get() from public;
revoke all on function push_keys_set(text, text) from public;
grant execute on function push_public_key() to anon, authenticated;
grant execute on function push_save(text, jsonb, jsonb, uuid) to anon, authenticated;
grant execute on function push_prefs(text, jsonb) to anon, authenticated;
grant execute on function push_off(text) to anon, authenticated;
grant execute on function push_seen(text, uuid[], uuid) to anon, authenticated;
grant execute on function push_due(int) to service_role;
grant execute on function push_mark(text, boolean, jsonb, boolean) to service_role;
grant execute on function push_keys_get() to service_role;
grant execute on function push_keys_set(text, text) to service_role;

-- envoi automatique : toutes les heures à la minute 2 (le programme ne fait rien la nuit)
select cron.unschedule(jobid) from cron.job where jobname = 'pilepoil-notifs';
select cron.schedule('pilepoil-notifs', '2 * * * *', $cron$
  select net.http_post(
    url := 'https://bcysxilkhnpayvfhlkju.supabase.co/functions/v1/notifs',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', (select cron_key from public.push_keys where id = 1)),
    body := '{}'::jsonb, timeout_milliseconds := 30000)
$cron$);
