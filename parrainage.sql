-- =====================================================================
--  PILE POIL — PARRAINAGE
--  Code de parrainage = code ami (accounts.fcode). Le parrain est payé quand le filleul
--  atteint le niveau 10 (plafond : 20 filleuls payés). Parrain et filleul deviennent amis.
-- =====================================================================
create table if not exists referrals (
  filleul text primary key,                       -- name_lower du filleul
  parrain text not null,                          -- name_lower du parrain
  dev text,                                       -- appareil du filleul (1 appareil = 1 filleul)
  created_at timestamptz not null default now(),
  paid boolean not null default false,
  paid_at timestamptz,
  duo_f boolean not null default false            -- coffre Duo déjà donné au filleul
);
create index if not exists referrals_parrain on referrals (parrain);
create unique index if not exists referrals_dev on referrals (dev) where dev is not null;
alter table referrals enable row level security;

-- niveau atteint d'après la sauvegarde du compte
create or replace function ref_lvl(p_save jsonb) returns int language sql immutable as $$
  select case when coalesce(p_save->>'maxLevel', '') ~ '^[0-9]{1,3}$' then (p_save->>'maxLevel')::int else 1 end
$$;

-- code ami / parrainage (créé s'il n'existe pas encore)
create or replace function ref_ensure_code(p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare u accounts; c text; al text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  select * into u from accounts where name_lower = p_name;
  if u.fcode is not null then return u.fcode; end if;
  loop
    c := upper(left(regexp_replace(translate(u.name_lower, 'àâäéèêëîïôöùûüç', 'aaaeeeeiioouuuc'), '[^a-z0-9]', '', 'g') || 'XXXX', 4)) || '-';
    for i in 1..3 loop c := c || substr(al, 1 + floor(random() * 32)::int, 1); end loop;
    exit when not exists (select 1 from accounts where fcode = c);
  end loop;
  update accounts set fcode = c where name_lower = p_name;
  return c;
end $$;

create or replace function ref_find(p_code text) returns accounts
language sql stable security definer set search_path = public as $$
  select * from accounts where length(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))) = 7
    and replace(fcode, '-', '') = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) limit 1
$$;

-- page du site : qui m'invite ? (pseudo + niveau, rien d'autre)
create or replace function ref_public(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o accounts;
begin
  o := ref_find(p_code);
  if o.name is null then return null; end if;
  return jsonb_build_object('name', o.name, 'lvl', ref_lvl(o.save));
end $$;

-- le filleul s'inscrit avec un code
create or replace function ref_claim(p_token uuid, p_code text, p_dev text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u accounts; o accounts; r referrals; dv text := nullif(left(coalesce(p_dev, ''), 64), '');
begin
  u := fr_auth(p_token);
  select * into r from referrals where filleul = u.name_lower;
  if found then return jsonb_build_object('st', 'deja', 'parrain', (select name from accounts where name_lower = r.parrain)); end if;
  o := ref_find(p_code);
  if o.name is null then raise exception 'Code de parrainage inconnu'; end if;
  if o.name_lower = u.name_lower then raise exception 'Tu ne peux pas être ton propre parrain'; end if;
  if u.created_at < now() - interval '14 days' then raise exception 'Le parrainage est réservé aux nouveaux comptes'; end if;
  if exists (select 1 from referrals where filleul = o.name_lower and parrain = u.name_lower) then raise exception 'Vous ne pouvez pas vous parrainer l''un l''autre'; end if;
  if dv is not null and exists (select 1 from referrals where dev = dv) then raise exception 'Cet appareil a déjà servi à un parrainage'; end if;
  insert into referrals (filleul, parrain, dev) values (u.name_lower, o.name_lower, dv);
  -- parrain et filleul deviennent amis
  delete from friend_req where (src = o.name_lower and dst = u.name_lower) or (src = u.name_lower and dst = o.name_lower);
  delete from friend_block where (src = o.name_lower and dst = u.name_lower) or (src = u.name_lower and dst = o.name_lower);
  insert into friends (a, b) values (least(u.name_lower, o.name_lower), greatest(u.name_lower, o.name_lower)) on conflict do nothing;
  return jsonb_build_object('st', 'ok', 'parrain', o.name);
end $$;

-- écran Parrainage
create or replace function ref_status(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u accounts; r referrals;
begin
  u := fr_auth(p_token);
  select * into r from referrals where filleul = u.name_lower;
  return jsonb_build_object(
    'code', ref_ensure_code(u.name_lower),
    'lvl', ref_lvl(u.save),
    'parrain', (select name from accounts where name_lower = r.parrain),
    'duo_f', coalesce(r.duo_f, false),
    'filleuls', coalesce((select jsonb_agg(jsonb_build_object('name', a.name, 'lvl', ref_lvl(a.save), 'paid', f.paid, 'av', a.save->'av') order by f.created_at desc)
      from (select * from referrals where parrain = u.name_lower order by created_at desc limit 60) f join accounts a on a.name_lower = f.filleul), '[]'::jsonb),
    'actifs', (select count(*) from referrals f join accounts a on a.name_lower = f.filleul where f.parrain = u.name_lower and ref_lvl(a.save) >= 10),
    'payes', (select count(*) from referrals where parrain = u.name_lower and paid)
  );
end $$;

-- le parrain encaisse ses primes (filleuls arrivés au niveau 10) : coffre Duo = 2 caisses par filleul
create or replace function ref_collect(p_token uuid, p_pid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u accounts; deja int; n int := 0;
begin
  u := fr_auth(p_token);
  select count(*) into deja from referrals where parrain = u.name_lower and paid;
  with q as (select f.filleul from referrals f join accounts a on a.name_lower = f.filleul
             where f.parrain = u.name_lower and not f.paid and ref_lvl(a.save) >= 10
             order by f.created_at limit greatest(0, 20 - deja) for update of f)
  update referrals set paid = true, paid_at = now() where filleul in (select filleul from q);
  get diagnostics n = row_count;
  if n > 0 and p_pid is not null and length(p_pid) >= 8 then
    insert into crates (pid) values (p_pid) on conflict (pid) do nothing;
    update crates set extra = least(extra + 2 * n, 40), updated_at = now() where pid = p_pid;
  end if;
  return jsonb_build_object('n', n, 'status', ref_status(p_token));
end $$;

-- le filleul atteint le niveau 10 : son coffre Duo (2 caisses), une seule fois
create or replace function ref_duo(p_token uuid, p_pid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u accounts; r referrals;
begin
  u := fr_auth(p_token);
  select * into r from referrals where filleul = u.name_lower for update;
  if not found or r.duo_f or ref_lvl(u.save) < 10 or p_pid is null or length(p_pid) < 8 then return jsonb_build_object('ok', false); end if;
  update referrals set duo_f = true where filleul = u.name_lower;
  insert into crates (pid) values (p_pid) on conflict (pid) do nothing;
  update crates set extra = least(extra + 2, 40), updated_at = now() where pid = p_pid;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function ref_lvl(jsonb) from public;
revoke all on function ref_ensure_code(text) from public;
revoke all on function ref_find(text) from public;
revoke all on function ref_public(text) from public;
revoke all on function ref_claim(uuid, text, text) from public;
revoke all on function ref_status(uuid) from public;
revoke all on function ref_collect(uuid, text) from public;
revoke all on function ref_duo(uuid, text) from public;
grant execute on function ref_public(text) to anon, authenticated;
grant execute on function ref_claim(uuid, text, text) to anon, authenticated;
grant execute on function ref_status(uuid) to anon, authenticated;
grant execute on function ref_collect(uuid, text) to anon, authenticated;
grant execute on function ref_duo(uuid, text) to anon, authenticated;

-- =====================================================================
--  PRIME DU PERMIS (site) : UNE SEULE FOIS PAR COMPTE, vérifiée par le serveur
--  (quel que soit l'appareil ou le nombre de passages sur le site)
-- =====================================================================
create table if not exists permis_primes (
  name_lower text primary key,
  mention text not null,
  at timestamptz not null default now()
);
alter table permis_primes enable row level security;

-- prime déjà touchée ? (les comptes qui l'ont reçue avant ce système sont repérés dans leur sauvegarde)
create or replace function permis_status(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u accounts; m text;
begin
  u := fr_auth(p_token);
  select mention into m from permis_primes where name_lower = u.name_lower;
  if m is null then m := nullif(u.save->>'permisPrime', ''); end if;
  return jsonb_build_object('pris', m is not null, 'mention', m);
end $$;

-- le jeu réclame la prime : accordée une seule fois, atomiquement
create or replace function permis_claim(p_token uuid, p_mention text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u accounts; n int;
begin
  u := fr_auth(p_token);
  if p_mention not in ('or', 'argent', 'bronze') then raise exception 'Mention inconnue'; end if;
  if nullif(u.save->>'permisPrime', '') is not null then
    insert into permis_primes (name_lower, mention) values (u.name_lower, u.save->>'permisPrime') on conflict do nothing;
    return jsonb_build_object('ok', false);
  end if;
  insert into permis_primes (name_lower, mention) values (u.name_lower, p_mention) on conflict do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n = 1);
end $$;

revoke all on function permis_status(uuid) from public;
revoke all on function permis_claim(uuid, text) from public;
grant execute on function permis_status(uuid) to anon, authenticated;
grant execute on function permis_claim(uuid, text) to anon, authenticated;
