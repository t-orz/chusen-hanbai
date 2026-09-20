-- =====================================================================
-- 来店者限定の応募（店内掲示 QR コード方式）
-- 01〜07 のあとに実行する。
--
-- 仕組み:
--   1. イベントごとに秘密のコードを発行し、それを埋めた URL を QR にして店内に掲示
--   2. 来店者が QR を読むと claim_store_pass() が「入店パス」を1枚発行する
--      （有効 30 分・1回限り・パス ID は推測不能な uuid）
--   3. issue_ticket() は有効なパスが無いと整理番号を出さない
--
-- 正直に書いておく限界:
--   印刷した QR の URL は、撮影して転送されれば店外からでも使える。
--   これは静的 QR である以上どうやっても消えない。
--   そのため「上限人数」と「コードの無効化・再発行」を用意してある。
--   管理画面で使用数を見て、異常に増えたら差し替えること。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) イベント側の設定を追加
-- ---------------------------------------------------------------------
alter table public.events
  add column if not exists require_entry_code boolean not null default false;

alter table public.events
  add column if not exists pass_window_minutes int not null default 30;

alter table public.events
  drop constraint if exists events_pass_window_ck;
alter table public.events
  add constraint events_pass_window_ck check (pass_window_minutes > 0);

-- ---------------------------------------------------------------------
-- 2) 店内掲示コード
--    code は insert 時に自動生成される。手で決めない。
-- ---------------------------------------------------------------------
create table if not exists public.entry_codes (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events(id) on delete cascade,
  code       text not null unique default encode(gen_random_bytes(12), 'hex'),
  label      text not null default '',     -- '本店入口' など、掲示場所のメモ
  active     boolean not null default true,
  max_uses   int,                          -- null なら無制限。整理番号の発行数で数える
  uses       int not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists entry_codes_event_idx on public.entry_codes (event_id);

-- ---------------------------------------------------------------------
-- 3) 入店パス
--    QR を1回読むごとに1枚。使うと consumed_at が入り、二度は使えない。
-- ---------------------------------------------------------------------
create table if not exists public.store_passes (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  code_id     uuid not null references public.entry_codes(id) on delete cascade,
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  consumed_at timestamptz,
  entry_id    uuid references public.entries(id) on delete set null
);

create index if not exists store_passes_event_idx   on public.store_passes (event_id);
create index if not exists store_passes_expiry_idx  on public.store_passes (expires_at)
  where consumed_at is null;

-- どの掲示物から来た応募かを記録しておく（集計用）
alter table public.entries
  add column if not exists entry_code_id uuid references public.entry_codes(id) on delete set null;

-- ---------------------------------------------------------------------
-- 4) 公開RPC: QR を読んだときに入店パスを受け取る
-- ---------------------------------------------------------------------
create or replace function public.claim_store_pass(p_slug text, p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_ev public.events; v_code public.entry_codes; v_pass public.store_passes;
begin
  select * into v_ev from public.events where slug = p_slug and status <> 'draft';
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

-- ---------------------------------------------------------------------
-- 5) issue_ticket を差し替え
--    2引数版を落として、パス ID を受け取る3引数版にする。
--    require_entry_code が false のイベントでは、パス無しでも従来どおり通る。
-- ---------------------------------------------------------------------
drop function if exists public.issue_ticket(text, text);

create or replace function public.issue_ticket(
  p_slug text, p_email text, p_pass_id uuid default null)
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

  -- 既に発行済みなら、パスを消費せずに同じ番号を返す。
  -- （2回スキャンした人が無駄にパスを1枚失わないようにする）
  select * into v_entry from public.entries
   where event_id = v_ev.id and lower(email) = v_email;
  if found then
    return jsonb_build_object('ok', true, 'already', true,
                              'ticket_no', v_entry.ticket_no, 'status', v_entry.status);
  end if;

  -- 来店者限定のイベントは、ここで入店パスを検証して消費する
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
    -- 上限は「実際に整理番号が出た数」で数える。
    -- パスを発行しただけでは減らないので、空スキャンで枠を潰されない。
    update public.entry_codes set uses = uses + 1 where id = v_pass.code_id;
  end if;

  return jsonb_build_object('ok', true, 'already', false,
                            'ticket_no', v_entry.ticket_no, 'status', v_entry.status);
end;
$fn$;

-- ---------------------------------------------------------------------
-- 6) event_public に「コードが要るかどうか」を足す
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
    'require_entry_code', v_ev.require_entry_code,
    'pass_window_minutes', v_ev.pass_window_minutes,
    'now', now());
end;
$fn$;

-- ---------------------------------------------------------------------
-- 7) 期限切れパスの掃除（tick から呼ばれる）
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

  -- 使われずに期限切れになった入店パスを片付ける（1日以上前のもの）
  delete from public.store_passes
   where consumed_at is null and expires_at < now() - interval '1 day';

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
-- 8) RLS と権限
-- ---------------------------------------------------------------------
alter table public.entry_codes  enable row level security;
alter table public.store_passes enable row level security;

-- コードもパスも anon 向けポリシーは作らない = 直接は読めない・書けない。
-- 窓口は claim_store_pass / issue_ticket だけ。
drop policy if exists entry_codes_admin_all on public.entry_codes;
create policy entry_codes_admin_all on public.entry_codes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists store_passes_admin_all on public.store_passes;
create policy store_passes_admin_all on public.store_passes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

do $do$
declare f text;
begin
  foreach f in array array[
    'public.claim_store_pass(text, text)',
    'public.issue_ticket(text, text, uuid)',
    'public.event_public(text)',
    'public.tick()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end
$do$;

grant execute on function public.claim_store_pass(text, text)       to anon, authenticated;
grant execute on function public.issue_ticket(text, text, uuid)     to anon, authenticated;
grant execute on function public.event_public(text)                 to anon, authenticated;
grant execute on function public.tick()                             to service_role;

-- ---------------------------------------------------------------------
-- 使い方
-- ---------------------------------------------------------------------
-- 来店者限定にする:
--   update public.events
--      set require_entry_code = true, pass_window_minutes = 30
--    where slug = 'autumn-2026';
--
-- 掲示コードを発行する（code は自動生成される）:
--   insert into public.entry_codes (event_id, label, max_uses)
--   select id, '本店入口', 500 from public.events where slug = 'autumn-2026'
--   returning code;
--
-- 掲示する URL は次の形。これを QR にする:
--   https://t-orz.github.io/chusen-hanbai/?e=autumn-2026&k=<code>
--
-- 使用状況を見る:
--   select c.label, c.code, c.active, c.uses, c.max_uses,
--          (select count(*) from public.store_passes p where p.code_id = c.id) as passes_issued
--     from public.entry_codes c
--     join public.events v on v.id = c.event_id
--    where v.slug = 'autumn-2026';
--
-- 拡散されたので差し替える:
--   update public.entry_codes set active = false where code = '<古いコード>';
--   insert into public.entry_codes (event_id, label, max_uses)
--   select id, '本店入口(2枚目)', 500 from public.events where slug = 'autumn-2026'
--   returning code;
--   -- 新しい code でポスターを刷り直す。
