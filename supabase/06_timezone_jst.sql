-- =====================================================================
-- 時刻を日本時間（JST）で扱うための設定
-- 01〜05 のあとに実行する。何度実行してもよい。
--
-- 前提: テーブルの日時はすべて timestamptz（絶対時刻）で持っている。
--       保存されている値そのものは変わらない。変わるのは
--       「表示のしかた」と「オフセット無しで書いた文字列の解釈」だけ。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) このデータベースの既定タイムゾーンを JST にする
--
--    これ以降に張られた接続では、
--      ・SQL Editor の結果が +09 で表示される
--      ・'2026-10-01 10:00' のようにオフセットを書かない文字列が JST と解釈される
--    となる。既存の接続には効かないので、SQL Editor は一度リロードする。
-- ---------------------------------------------------------------------
alter database postgres set timezone to 'Asia/Tokyo';

-- PostgREST（REST API）が使うロールにも同じ既定を入れておく。
-- これで API が返す日時も +09:00 付きになる。値の意味は変わらない。
alter role authenticator set timezone to 'Asia/Tokyo';

-- ---------------------------------------------------------------------
-- 2) SQL で確認するとき用の表示ヘルパ
-- ---------------------------------------------------------------------
create or replace function public.jst(ts timestamptz)
returns text
language sql immutable
as $fn$
  select to_char(ts at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI:SS');
$fn$;

-- 応募一覧を JST で読むためのビュー（SQL Editor から使う想定）
create or replace view public.entries_jst as
  select v.slug        as event_slug,
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

-- 抽選履歴を JST で読むビュー
create or replace view public.draws_jst as
  select v.slug as event_slug,
         d.round_no,
         public.jst(d.executed_at) as executed_at_jst,
         d.candidates, d.slots, d.picked,
         public.jst(d.expires_at)  as expires_at_jst,
         d.triggered_by
    from public.draws d
    join public.events v on v.id = d.event_id;

-- ビューは管理用。anon からは触らせない。
revoke all on public.entries_jst from public, anon, authenticated;
revoke all on public.draws_jst   from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) 確認
-- ---------------------------------------------------------------------
-- 一度 SQL Editor をリロードしてから:
--   show timezone;                        -- Asia/Tokyo と出る
--   select now();                         -- +09 付きで出る
--   select * from public.entries_jst where event_slug = 'test-2026' order by ticket_no;
--   select * from public.draws_jst   where event_slug = 'test-2026' order by round_no;

-- ---------------------------------------------------------------------
-- 補足
-- ---------------------------------------------------------------------
-- ・抽選ロジック（run_draw / tick）は now() と timestamptz しか使っていないので、
--   この設定を入れても入れなくても動作は同じ。時刻の比較は絶対時刻で行われる。
-- ・pg_cron のスケジュールは '* * * * *'（毎分）なので、
--   cron 側がどのタイムゾーンで時刻を解釈しても影響を受けない。
--   もし '0 12 * * *' のような時刻指定に変える場合は、
--   cron.schedule が UTC で解釈する点に注意すること（JST 12:00 なら '0 3 * * *'）。
