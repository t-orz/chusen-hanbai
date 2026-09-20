-- =====================================================================
-- 抽選ロジック / 公開RPC / 管理RPC
-- 01_schema.sql のあとに実行する。
-- =====================================================================

-- ---------------------------------------------------------------------
-- run_draw : 1イベントぶんの抽選を1回進める。
--   1. 期限切れの当選を expired にする
--   2. 有効な当選が1件でも残っていれば何もしない（まだ待つ時間）
--   3. 空き枠 = 当選枠数 - 利用済み数 を求め、未当選者からランダムに埋める
--   4. 枠が埋まりきった / 上限回数に達した / 応募者が尽きたら finished
-- ---------------------------------------------------------------------
create or replace function public.run_draw(p_event_id uuid, p_trigger text default 'cron')
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_ev      public.events;
  v_vacancy int;
  v_picked  int;
  v_cand    int;
  v_round   int;
  v_exp     timestamptz;
begin
  -- イベント行をロックして、同じイベントの抽選が二重に走らないようにする
  select * into v_ev from public.events where id = p_event_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'event_not_found');
  end if;

  -- 1) 期限切れの当選を失効させる
  update public.entries
     set status = 'expired'
   where event_id = v_ev.id and status = 'won' and expires_at <= now();

  if v_ev.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'event_not_open', 'status', v_ev.status);
  end if;
  if now() < v_ev.first_draw_at then
    return jsonb_build_object('ok', false, 'error', 'too_early', 'first_draw_at', v_ev.first_draw_at);
  end if;

  -- 2) まだ使用期限内の当選が残っているなら次点抽選はしない
  if exists (select 1 from public.entries
              where event_id = v_ev.id and status = 'won') then
    return jsonb_build_object('ok', false, 'error', 'winners_pending');
  end if;

  -- 3) 空き枠
  select v_ev.winners_count - count(*) into v_vacancy
    from public.entries where event_id = v_ev.id and status = 'redeemed';

  if v_vacancy <= 0 then
    update public.events set status = 'finished' where id = v_ev.id;
    return jsonb_build_object('ok', true, 'finished', true, 'reason', 'all_redeemed');
  end if;
  if v_ev.rounds_done >= v_ev.max_rounds then
    update public.events set status = 'finished' where id = v_ev.id;
    return jsonb_build_object('ok', true, 'finished', true, 'reason', 'max_rounds',
                              'vacancy', v_vacancy);
  end if;

  select count(*) into v_cand
    from public.entries where event_id = v_ev.id and status = 'entered';
  if v_cand = 0 then
    update public.events set status = 'finished' where id = v_ev.id;
    return jsonb_build_object('ok', true, 'finished', true, 'reason', 'no_candidates',
                              'vacancy', v_vacancy);
  end if;

  v_round := v_ev.rounds_done + 1;
  v_exp   := now() + make_interval(mins => v_ev.claim_window_minutes);

  -- materialized を明示しないと random() が再評価されうる
  with picked as materialized (
    select id from public.entries
     where event_id = v_ev.id and status = 'entered'
     order by random()
     limit v_vacancy
  )
  update public.entries e
     set status = 'won', round_won = v_round, won_at = now(), expires_at = v_exp
    from picked p
   where e.id = p.id;
  get diagnostics v_picked = row_count;

  insert into public.draws (event_id, round_no, slots, picked, candidates, expires_at, triggered_by)
  values (v_ev.id, v_round, v_vacancy, v_picked, v_cand, v_exp, p_trigger);

  update public.events set rounds_done = v_round where id = v_ev.id;

  return jsonb_build_object('ok', true, 'round', v_round, 'slots', v_vacancy,
                            'picked', v_picked, 'candidates', v_cand, 'expires_at', v_exp);
end;
$fn$;

-- ---------------------------------------------------------------------
-- tick : pg_cron から毎分呼ばれる入口。開催中の全イベントを1歩ずつ進める。
-- ---------------------------------------------------------------------
create or replace function public.tick()
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  r     record;
  v_out jsonb := '[]'::jsonb;
begin
  -- 抽選時刻前でも、期限切れの反映だけは全イベントで行う
  update public.entries
     set status = 'expired'
   where status = 'won' and expires_at <= now();

  for r in
    select id, slug from public.events
     where status = 'open' and now() >= first_draw_at
     order by first_draw_at
  loop
    v_out := v_out || jsonb_build_array(
      jsonb_build_object('slug', r.slug, 'result', public.run_draw(r.id, 'cron')));
  end loop;

  return v_out;
end;
$fn$;

-- ---------------------------------------------------------------------
-- 公開RPC : event_public / issue_ticket / lookup_ticket
-- entries テーブルは anon から直接は一切見えない。この3つだけが窓口。
-- ---------------------------------------------------------------------
create or replace function public.event_public(p_slug text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_ev public.events; v_entries int; v_redeemed int; v_won int;
begin
  select * into v_ev from public.events where slug = p_slug and status <> 'draft';
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
    'name', v_ev.name, 'slug', v_ev.slug, 'description', v_ev.description,
    'entry_open_at', v_ev.entry_open_at, 'entry_close_at', v_ev.entry_close_at,
    'first_draw_at', v_ev.first_draw_at, 'winners_count', v_ev.winners_count,
    'claim_window_minutes', v_ev.claim_window_minutes, 'max_rounds', v_ev.max_rounds,
    'rounds_done', v_ev.rounds_done, 'status', v_ev.status,
    'entry_count', v_entries, 'redeemed_count', v_redeemed, 'active_winner_count', v_won,
    'now', now());
end;
$fn$;

create or replace function public.issue_ticket(p_slug text, p_email text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_ev public.events; v_entry public.entries; v_email text; v_seq int; v_no text;
begin
  v_email := lower(btrim(p_email));
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_email');
  end if;

  select * into v_ev from public.events where slug = p_slug for update;
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

  -- 同じメールで2回押しても新しい番号は出さず、既存の番号を返す
  select * into v_entry from public.entries
   where event_id = v_ev.id and lower(email) = v_email;
  if found then
    return jsonb_build_object('ok', true, 'already', true,
                              'ticket_no', v_entry.ticket_no, 'status', v_entry.status);
  end if;

  update public.events set ticket_seq = ticket_seq + 1
   where id = v_ev.id returning ticket_seq into v_seq;
  v_no := v_ev.ticket_prefix || lpad(v_seq::text, 4, '0');

  insert into public.entries (event_id, ticket_no, email)
  values (v_ev.id, v_no, v_email) returning * into v_entry;

  return jsonb_build_object('ok', true, 'already', false,
                            'ticket_no', v_entry.ticket_no, 'status', v_entry.status);
end;
$fn$;

create or replace function public.lookup_ticket(p_slug text, p_ticket_no text, p_email text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_ev public.events; v_entry public.entries; v_status text;
begin
  select * into v_ev from public.events where slug = p_slug and status <> 'draft';
  if not found then return jsonb_build_object('ok', false, 'error', 'event_not_found'); end if;

  -- 番号だけでは引けない。メールとの一致を必須にして総当たりを防ぐ
  select * into v_entry from public.entries
   where event_id = v_ev.id
     and upper(btrim(ticket_no)) = upper(btrim(p_ticket_no))
     and lower(email) = lower(btrim(p_email));
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  -- 表示上は期限を過ぎた当選を失効として見せる（実テーブルは tick が直す）
  v_status := v_entry.status;
  if v_status = 'won' and v_entry.expires_at <= now() then v_status := 'expired'; end if;

  return jsonb_build_object(
    'ok', true, 'ticket_no', v_entry.ticket_no, 'status', v_status,
    'round_won', v_entry.round_won, 'won_at', v_entry.won_at,
    'expires_at', v_entry.expires_at, 'redeemed_at', v_entry.redeemed_at,
    'event_name', v_ev.name, 'event_status', v_ev.status,
    'first_draw_at', v_ev.first_draw_at, 'rounds_done', v_ev.rounds_done,
    'max_rounds', v_ev.max_rounds, 'now', now());
end;
$fn$;

-- ---------------------------------------------------------------------
-- 管理RPC : 消し込み / 手動抽選 / 無効化
-- ---------------------------------------------------------------------
create or replace function public.admin_redeem(p_entry_id uuid, p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_entry public.entries;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select * into v_entry from public.entries where id = p_entry_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_entry.status = 'redeemed' then
    return jsonb_build_object('ok', false, 'error', 'already_redeemed');
  end if;
  if v_entry.status not in ('won', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'not_a_winner', 'status', v_entry.status);
  end if;
  -- 期限切れを消し込むのは管理者が意図した場合だけ
  if not p_force and (v_entry.status = 'expired' or v_entry.expires_at <= now()) then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;

  update public.entries
     set status = 'redeemed', redeemed_at = now(), redeemed_by = auth.uid()
   where id = p_entry_id;

  return jsonb_build_object('ok', true, 'ticket_no', v_entry.ticket_no);
end;
$fn$;

create or replace function public.admin_unredeem(p_entry_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_entry public.entries;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  select * into v_entry from public.entries where id = p_entry_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_entry.status <> 'redeemed' then
    return jsonb_build_object('ok', false, 'error', 'not_redeemed');
  end if;
  -- 消し込みの取り消しは期限内なら当選中、過ぎていれば失効に戻す（枠は空きに戻る）
  update public.entries
     set status = case when v_entry.expires_at > now() then 'won' else 'expired' end,
         redeemed_at = null, redeemed_by = null
   where id = p_entry_id;
  return jsonb_build_object('ok', true, 'ticket_no', v_entry.ticket_no);
end;
$fn$;

create or replace function public.admin_set_void(p_entry_id uuid, p_void boolean)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  update public.entries
     set status = case when p_void then 'void' else 'entered' end,
         round_won = null, won_at = null, expires_at = null
   where id = p_entry_id;
  return jsonb_build_object('ok', found);
end;
$fn$;

create or replace function public.admin_run_draw(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  return public.run_draw(p_event_id, 'manual:' || coalesce(auth.uid()::text, '?'));
end;
$fn$;

-- 期限切れを待たずに現在の当選を強制失効させ、すぐ次点抽選に移す
create or replace function public.admin_force_expire(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_n int;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  update public.entries set status = 'expired', expires_at = now()
   where event_id = p_event_id and status = 'won';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'expired', v_n);
end;
$fn$;
