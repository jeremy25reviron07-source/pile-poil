-- =====================================================================
--  PILE POIL — CLASSEMENT SURVIE : même protection des pseudos que les autres classements
--  Un pseudo qui appartient à un compte ne peut être utilisé que par ce compte.
-- =====================================================================

-- nouvelle version (jeu à jour) : le jeton du compte est envoyé, refus clair sinon
create or replace function survie_submit2(p_pid text, p_name text, p_n integer, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not name_allowed(left(coalesce(nullif(trim(p_name), ''), 'Grutier'), 16), p_token) then
    raise exception 'Ce pseudo appartient à un compte : connecte-toi pour l''utiliser';
  end if;
  perform set_config('pp.survie_ok', '1', true);   -- pseudo déjà vérifié avec le jeton
  return survie_submit(p_pid, p_name, p_n);
end $$;

-- ancienne version (jeu pas encore rechargé) : un pseudo de compte est remplacé par « Grutier »
create or replace function survie_submit(p_pid text, p_name text, p_n integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b int; n text := left(coalesce(nullif(trim(p_name), ''), 'Grutier'), 16); rk int; tot int;
begin
  if p_pid is null or length(p_pid) < 8 then raise exception 'Joueur inconnu'; end if;
  if p_n < 0 or p_n > 500 then raise exception 'Score invalide'; end if;
  if current_setting('pp.survie_ok', true) is distinct from '1' and not name_allowed(n, null) then n := 'Grutier'; end if;
  insert into survie (pid, name, best, runs) values (p_pid, n, p_n, 1)
  on conflict (pid) do update set best = greatest(survie.best, excluded.best), runs = survie.runs + 1, name = excluded.name, updated_at = now();
  select best into b from survie where pid = p_pid;
  select count(*) + 1 into rk from survie where best > b;
  select count(*) into tot from survie where best > 0;
  return jsonb_build_object('best', b, 'rank', rk, 'total', tot);
end $$;

revoke all on function survie_submit2(text, text, integer, uuid) from public;
grant execute on function survie_submit2(text, text, integer, uuid) to anon, authenticated;
