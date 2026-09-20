-- =====================================================================
-- 抽選販売 整理番号アプリ / スキーマ
-- Supabase ダッシュボードの SQL Editor にそのまま貼って実行する。
-- 何度実行しても同じ結果になるように書いてある（冪等）。
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- events : 抽選イベント1件ぶんの設定
-- ---------------------------------------------------------------------
create table if not exists public.events (
  id                    uuid primary key default gen_random_uuid(),
  slug                  text not null unique,              -- URL に使う識別子 (?e=xxx)
  name                  text not null,
  description           text not null default '',
  entry_open_at         timestamptz not null,              -- 整理番号の配布開始
  entry_close_at        timestamptz not null,              -- 整理番号の配布終了
  first_draw_at         timestamptz not null,              -- 第1回抽選の実行時刻
  winners_count         int  not null check (winners_count > 0),        -- 当選させる数（＝販売枠）
  claim_window_minutes  int  not null default 1440 check (claim_window_minutes > 0), -- 当選の使用期限(分)
  max_rounds            int  not null default 3 check (max_rounds >= 1), -- 第1回を含む抽選の最大回数
  ticket_prefix         text not null default '',          -- 整理番号の接頭辞 例: 'A-'
  ticket_seq            int  not null default 0,           -- 発番カウンタ（内部用）
  rounds_done           int  not null default 0,           -- 実行済みの抽選回数
  status                text not null default 'draft'
                        check (status in ('draft','open','finished','cancelled')),
  created_at            timestamptz not null default now(),
  constraint events_period_ck check (entry_close_at > entry_open_at),
  constraint events_draw_ck   check (first_draw_at >= entry_close_at)
);

-- ---------------------------------------------------------------------
-- entries : 発行した整理番号 = 応募1件
-- ---------------------------------------------------------------------
create table if not exists public.entries (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.events(id) on delete cascade,
  ticket_no     text not null,
  email         text not null,
  status        text not null default 'entered'
                check (status in ('entered','won','redeemed','expired','void')),
  round_won     int,                    -- 何回目の抽選で当たったか
  won_at        timestamptz,
  expires_at    timestamptz,            -- この時刻までに利用されなければ失効
  redeemed_at   timestamptz,
  redeemed_by   uuid,                   -- 消し込みをした管理者
  note          text not null default '',
  created_at    timestamptz not null default now(),
  unique (event_id, ticket_no)
);

create unique index if not exists entries_event_email_uniq
  on public.entries (event_id, lower(email));
create index if not exists entries_event_status_idx
  on public.entries (event_id, status);
create index if not exists entries_expiry_idx
  on public.entries (expires_at) where status = 'won';

-- ---------------------------------------------------------------------
-- draws : 抽選の実行ログ（第1回・再抽選すべて1行ずつ）
-- ---------------------------------------------------------------------
create table if not exists public.draws (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.events(id) on delete cascade,
  round_no      int  not null,
  executed_at   timestamptz not null default now(),
  slots         int  not null,   -- この回で埋めようとした空き枠数
  picked        int  not null,   -- 実際に当選させた数
  candidates    int  not null,   -- 抽選母数（未当選の応募数）
  expires_at    timestamptz,     -- この回の当選の使用期限
  triggered_by  text not null default 'cron',
  unique (event_id, round_no)
);

-- ---------------------------------------------------------------------
-- admin_users : 管理画面にログインできる Supabase Auth ユーザー
-- ---------------------------------------------------------------------
create table if not exists public.admin_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.admin_users where user_id = auth.uid());
$$;
