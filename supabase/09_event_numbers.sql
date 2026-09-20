-- =====================================================================
-- ユーザー番号とイベント番号
-- 01〜08 のあとに実行する。
--
-- イベント番号の構成（16進数・大文字）:
--
--     0000 01 - 000 00A - 4F2A
--     └ユーザー番号┘ └作成順┘ └乱数┘
--       6桁          6桁      4桁
--
--   ・ユーザー番号 : 運営アカウントごとの通し番号。1 から。0 は予約。
--   ・作成順       : そのユーザーが作った何件目か。ユーザーごとに 1 から。
--   ・乱数         : 0000〜FFFF。番号の推測を防ぐためだけの飾り。
--
-- ユーザー番号と作成順の組は重複しないので、乱数が被っても
-- イベント番号が衝突することはない。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) 運営アカウントにユーザー番号を振る
--    0 は「SQL Editor から作られたイベント」用に空けておくので 1 から。
-- ---------------------------------------------------------------------
create sequence if not exists public.admin_user_no_seq start 1;
create sequence if not exists public.system_event_seq start 1;

alter table public.admin_users add column if not exists user_no   int;
alter table public.admin_users add column if not exists event_seq int not null default 0;

-- 既にいる管理者に番号を振る（作成順）
update public.admin_users
   set user_no = nextval('public.admin_user_no_seq')
 where user_no is null;

alter table public.admin_users
  alter column user_no set default nextval('public.admin_user_no_seq');
alter table public.admin_users
  alter column user_no set not null;

create unique index if not exists admin_users_user_no_uniq
  on public.admin_users (user_no);

-- 6桁の16進数に収まる範囲に制限する
alter table public.admin_users drop constraint if exists admin_users_user_no_range_ck;
alter table public.admin_users
  add constraint admin_users_user_no_range_ck
  check (user_no between 0 and 16777215);

alter table public.admin_users drop constraint if exists admin_users_event_seq_range_ck;
alter table public.admin_users
  add constraint admin_users_event_seq_range_ck
  check (event_seq between 0 and 16777215);

-- ---------------------------------------------------------------------
-- 2) イベント側の列
-- ---------------------------------------------------------------------
alter table public.events add column if not exists event_no        text;
alter table public.events add column if not exists created_by      uuid
  references auth.users(id) on delete set null;
alter table public.events add column if not exists creator_user_no int;
alter table public.events add column if not exists creator_seq     int;

create unique index if not exists events_event_no_uniq on public.events (event_no);

-- ---------------------------------------------------------------------
-- 3) 採番トリガー
--    イベントを insert すると event_no が自動で入る。
--    明示的に event_no を指定した場合はそれを尊重する（移行用）。
-- ---------------------------------------------------------------------
create or replace function public.assign_event_no()
returns trigger
language plpgsql security definer set search_path = public
as $fn$
declare v_user_no int; v_seq int;
begin
  if new.event_no is not null and btrim(new.event_no) <> '' then
    return new;
  end if;

  -- 作成者の作成順カウンタを1つ進める。UPDATE が行ロックも兼ねる。
  update public.admin_users
     set event_seq = event_seq + 1
   where user_id = auth.uid()
   returning user_no, event_seq into v_user_no, v_seq;

  if not found then
    -- auth.uid() が無い＝SQL Editor や service_role からの作成。
    -- ユーザー番号 0 と、専用の通し番号を使う。
    v_user_no := 0;
    v_seq     := nextval('public.system_event_seq');
  end if;

  new.created_by      := auth.uid();
  new.creator_user_no := v_user_no;
  new.creator_seq     := v_seq;
  new.event_no := upper(
    lpad(to_hex(v_user_no), 6, '0') || '-' ||
    lpad(to_hex(v_seq),     6, '0') || '-' ||
    lpad(to_hex((random() * 65535)::int), 4, '0'));

  return new;
end;
$fn$;

drop trigger if exists events_assign_no on public.events;
create trigger events_assign_no
  before insert on public.events
  for each row execute function public.assign_event_no();

-- 既存のイベントに番号を振る（今は0件だが、流し直しても安全）
update public.events e
   set creator_user_no = 0,
       creator_seq     = s.seq,
       event_no        = upper(
         '000000-' ||
         lpad(to_hex(s.seq), 6, '0') || '-' ||
         lpad(to_hex((random() * 65535)::int), 4, '0'))
  from (
    select id, nextval('public.system_event_seq')::int as seq
      from public.events where event_no is null
     order by created_at
  ) s
 where e.id = s.id;

-- ---------------------------------------------------------------------
-- 4) event_public にイベント番号を足す
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
    'event_no', v_ev.event_no,
    'name', v_ev.name, 'slug', v_ev.slug, 'description', v_ev.description,
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

-- ---------------------------------------------------------------------
-- 5) 当落照会にもイベント番号を出す（問い合わせ対応用）
-- ---------------------------------------------------------------------
create or replace function public.lookup_ticket(p_slug text, p_ticket_no text, p_email text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_ev public.events; v_entry public.entries; v_status text;
begin
  select * into v_ev from public.events where slug = p_slug and status <> 'draft';
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

do $do$
begin
  execute 'revoke all on function public.event_public(text) from public, anon, authenticated';
  execute 'revoke all on function public.lookup_ticket(text, text, text) from public, anon, authenticated';
end
$do$;

grant execute on function public.event_public(text)              to anon, authenticated;
grant execute on function public.lookup_ticket(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6) 自分のユーザー番号を知るための RPC（管理画面のヘッダ表示用）
-- ---------------------------------------------------------------------
create or replace function public.my_admin_profile()
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v public.admin_users;
begin
  select * into v from public.admin_users where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', 'not_admin'); end if;
  return jsonb_build_object(
    'ok', true,
    'user_no', v.user_no,
    'user_no_hex', upper(lpad(to_hex(v.user_no), 6, '0')),
    'email', v.email,
    'events_created', v.event_seq);
end;
$fn$;

revoke all on function public.my_admin_profile() from public, anon, authenticated;
grant execute on function public.my_admin_profile() to authenticated;

-- ---------------------------------------------------------------------
-- 確認
-- ---------------------------------------------------------------------
-- select user_no, upper(lpad(to_hex(user_no),6,'0')) as user_no_hex, email, event_seq
--   from public.admin_users order by user_no;
--
-- select event_no, slug, name, creator_user_no, creator_seq, created_at
--   from public.events order by created_at;
