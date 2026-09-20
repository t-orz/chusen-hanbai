-- =====================================================================
-- slug を廃止し、イベント番号（event_no）をキーに一本化する
-- 01〜09 のあとに実行する。
--
-- slug は利用者の目に触れておらず、「イベントを特定するキー」としてしか
-- 使われていなかった。event_no がその役割を全部果たせるので落とす。
--
-- 01〜09 の中には slug を使う記述が残っているが、順番に流す限り問題ない。
-- slug はこのファイルの最後で消える。
--
-- 公開 URL は次の形になる:
--   https://t-orz.github.io/chusen-hanbai/?e=000001-000001-4F2A
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) イベント番号の正規化
--    人が手で打つ場合を考えて、大文字小文字とハイフンの有無を吸収する。
--      '000001-000001-4f2a' -> '000001-000001-4F2A'
--      '00000100000 14F2A'  -> '000001-000001-4F2A'
--    16桁の16進数にならないものは null を返す（＝見つからない扱い）。
-- ---------------------------------------------------------------------
create or replace function public.normalize_event_no(p text)
returns text
language sql immutable
as $fn$
  select case when length(h) = 16
              then upper(substr(h, 1, 6) || '-' || substr(h, 7, 6) || '-' || substr(h, 13, 4))
              else null end
    from (select regexp_replace(coalesce(p, ''), '[^0-9A-Fa-f]', '', 'g') as h) t;
$fn$;

-- ---------------------------------------------------------------------
-- 2) slug に依存しているビューを一旦落とす
-- ---------------------------------------------------------------------
drop view if exists public.entries_jst;
drop view if exists public.draws_jst;

-- ---------------------------------------------------------------------
-- 3) 公開RPC を作り直す
--    引数名を p_slug から p_event_no に変える。
--    Postgres は create or replace で引数名を変えられないので、一度落とす。
-- ---------------------------------------------------------------------
drop function if exists public.event_public(text);
drop function if exists public.issue_ticket(text, text, uuid);
drop function if exists public.lookup_ticket(text, text, text);
drop function if exists public.claim_store_pass(text, text);

-- --- イベント概要 -----------------------------------------------------
create function public.event_public(p_event_no text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_ev public.events; v_entries int; v_redeemed int; v_won int;
begin
  select * into v_ev from public.events
   where event_no = public.normalize_event_no(p_event_no) and status <> 'draft';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'event_not_found');
  end if;

  select count(*) filter (where status <> 'void'),
         count(*) filter (where status = 'redeemed'),
         count(*) filter (where status = 'won' and expires_at > now())
    into v_entries, v_redeemed, v_won
    from public.entries where event_id = v_ev.id;

  return jsonb_build_object(
    'ok', true,
    'event_no', v_ev.event_no,
    'name', v_ev.name, 'description', v_ev.description,
    'entry_open_at', v_ev.entry_open_at, 'entry_close_at', v_ev.entry_close_at,
    'first_draw_at', v_ev.first_draw_at, 'winners_count', v_ev.winners_count,
    'claim_window_minutes', v_ev.claim_window_minutes, 'max_rounds', v_ev.max_rounds,
    'rounds_done', v_ev.rounds_done, 'status', v_ev.status,
    'entry_count', v_entries, 'redeemed_count', v_redeemed, 'active_winner_count', v_won,
    'require_entry_code', v_ev.require_entry_code,
    'pass_window_minutes', v_ev.pass_window_minutes,
    'now', now());
end;
$fn$;

-- --- 入店パスの発行 ---------------------------------------------------
create function public.claim_store_pass(p_event_no text, p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_ev public.events; v_code public.entry_codes; v_pass public.store_passes;
begin
  select * into v_ev from public.events
   where event_no = public.normalize_event_no(p_event_no) and status <> 'draft';
  if not found then return jsonb_build_object('ok', false, 'error', 'event_not_found'); end if;
  if v_ev.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'event_not_open', 'status', v_ev.status);
  end if;
  if now() < v_ev.entry_open_at then
    return jsonb_build_object('ok', false, 'error', 'entry_not_started',
                              'entry_open_at', v_ev.entry_open_at);
  end if;
  if now() > v_ev.entry_close_at then
    return jsonb_build_object('ok', false, 'error', 'entry_closed');
  end if;

  select * into v_code from public.entry_codes
   where code = btrim(p_code) and event_id = v_ev.id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_code'); end if;
  if not v_code.active then
    return jsonb_build_object('ok', false, 'error', 'code_disabled');
  end if;
  if v_code.max_uses is not null and v_code.uses >= v_code.max_uses then
    return jsonb_build_object('ok', false, 'error', 'code_exhausted');
  end if;

  insert into public.store_passes (event_id, code_id, expires_at)
  values (v_ev.id, v_code.id, now() + make_interval(mins => v_ev.pass_window_minutes))
  returning * into v_pass;

  return jsonb_build_object('ok', true, 'pass_id', v_pass.id,
                            'expires_at', v_pass.expires_at,
                            'window_minutes', v_ev.pass_window_minutes);
end;
$fn$;

-- --- 整理番号の発行 ---------------------------------------------------
create function public.issue_ticket(
  p_event_no text, p_email text, p_pass_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_ev    public.events;
  v_entry public.entries;
  v_pass  public.store_passes;
  v_email text;
  v_seq   int;
  v_no    text;
begin
  v_email := lower(btrim(p_email));
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_email');
  end if;

  select * into v_ev from public.events
   where event_no = public.normalize_event_no(p_event_no) for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'event_not_found'); end if;
  if v_ev.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'event_not_open', 'status', v_ev.status);
  end if;
  if now() < v_ev.entry_open_at then
    return jsonb_build_object('ok', false, 'error', 'entry_not_started',
                              'entry_open_at', v_ev.entry_open_at);
  end if;
  if now() > v_ev.entry_close_at then
    return jsonb_build_object('ok', false, 'error', 'entry_closed');
  end if;

  -- 既に発行済みなら、パスを消費せずに同じ番号を返す
  select * into v_entry from public.entries
   where event_id = v_ev.id and lower(email) = v_email;
  if found then
    return jsonb_build_object('ok', true, 'already', true,
                              'ticket_no', v_entry.ticket_no, 'status', v_entry.status);
  end if;

  if v_ev.require_entry_code then
    if p_pass_id is null then
      return jsonb_build_object('ok', false, 'error', 'pass_required');
    end if;
    select * into v_pass from public.store_passes where id = p_pass_id for update;
    if not found or v_pass.event_id <> v_ev.id then
      return jsonb_build_object('ok', false, 'error', 'pass_invalid');
    end if;
    if v_pass.consumed_at is not null then
      return jsonb_build_object('ok', false, 'error', 'pass_used');
    end if;
    if v_pass.expires_at <= now() then
      return jsonb_build_object('ok', false, 'error', 'pass_expired');
    end if;
  end if;

  update public.events set ticket_seq = ticket_seq + 1
   where id = v_ev.id returning ticket_seq into v_seq;
  v_no := v_ev.ticket_prefix || lpad(v_seq::text, 4, '0');

  insert into public.entries (event_id, ticket_no, email, entry_code_id)
  values (v_ev.id, v_no, v_email,
          case when v_ev.require_entry_code then v_pass.code_id else null end)
  returning * into v_entry;

  if v_ev.require_entry_code then
    update public.store_passes
       set consumed_at = now(), entry_id = v_entry.id
     where id = v_pass.id;
    update public.entry_codes set uses = uses + 1 where id = v_pass.code_id;
  end if;

  return jsonb_build_object('ok', true, 'already', false,
                            'ticket_no', v_entry.ticket_no, 'status', v_entry.status);
end;
$fn$;

-- --- 当落照会 ---------------------------------------------------------
create function public.lookup_ticket(p_event_no text, p_ticket_no text, p_email text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_ev public.events; v_entry public.entries; v_status text;
begin
  select * into v_ev from public.events
   where event_no = public.normalize_event_no(p_event_no) and status <> 'draft';
  if not found then return jsonb_build_object('ok', false, 'error', 'event_not_found'); end if;

  select * into v_entry from public.entries
   where event_id = v_ev.id
     and upper(btrim(ticket_no)) = upper(btrim(p_ticket_no))
     and lower(email) = lower(btrim(p_email));
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  v_status := v_entry.status;
  if v_status = 'won' and v_entry.expires_at <= now() then v_status := 'expired'; end if;

  return jsonb_build_object(
    'ok', true, 'ticket_no', v_entry.ticket_no, 'status', v_status,
    'round_won', v_entry.round_won, 'won_at', v_entry.won_at,
    'expires_at', v_entry.expires_at, 'redeemed_at', v_entry.redeemed_at,
    'event_no', v_ev.event_no,
    'event_name', v_ev.name, 'event_status', v_ev.status,
    'first_draw_at', v_ev.first_draw_at, 'rounds_done', v_ev.rounds_done,
    'max_rounds', v_ev.max_rounds, 'now', now());
end;
$fn$;

-- ---------------------------------------------------------------------
-- 4) slug を落とす
-- ---------------------------------------------------------------------
alter table public.events alter column event_no set not null;
alter table public.events drop column if exists slug;

-- ---------------------------------------------------------------------
-- 5) JST 表示ビューを作り直す
-- ---------------------------------------------------------------------
create view public.entries_jst as
  select v.event_no,
         v.name as event_name,
         e.ticket_no,
         e.email,
         e.status,
         e.round_won,
         public.jst(e.won_at)      as won_at_jst,
         public.jst(e.expires_at)  as expires_at_jst,
         public.jst(e.redeemed_at) as redeemed_at_jst,
         public.jst(e.created_at)  as created_at_jst
    from public.entries e
    join public.events  v on v.id = e.event_id;

create view public.draws_jst as
  select v.event_no,
         v.name as event_name,
         d.round_no,
         public.jst(d.executed_at) as executed_at_jst,
         d.candidates, d.slots, d.picked,
         public.jst(d.expires_at)  as expires_at_jst,
         d.triggered_by
    from public.draws d
    join public.events v on v.id = d.event_id;

revoke all on public.entries_jst from public, anon, authenticated;
revoke all on public.draws_jst   from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6) 実行権限を配り直す
-- ---------------------------------------------------------------------
do $do$
declare f text;
begin
  foreach f in array array[
    'public.normalize_event_no(text)',
    'public.event_public(text)',
    'public.claim_store_pass(text, text)',
    'public.issue_ticket(text, text, uuid)',
    'public.lookup_ticket(text, text, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end
$do$;

grant execute on function public.normalize_event_no(text)        to anon, authenticated;
grant execute on function public.event_public(text)              to anon, authenticated;
grant execute on function public.claim_store_pass(text, text)    to anon, authenticated;
grant execute on function public.issue_ticket(text, text, uuid)  to anon, authenticated;
grant execute on function public.lookup_ticket(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 確認
-- ---------------------------------------------------------------------
-- select event_no, name, status from public.events order by created_at;
-- select public.normalize_event_no('000001-000001-4f2a');   -- 000001-000001-4F2A
-- select public.normalize_event_no('0000010000014F2A');     -- 000001-000001-4F2A
-- select public.normalize_event_no('autumn-2026');          -- null
