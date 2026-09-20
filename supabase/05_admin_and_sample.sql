-- =====================================================================
-- 管理者の登録と、動作確認用イベントの作成
-- 使うときに中身を書き換えて実行する。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) 管理者を登録する
--    先に Supabase ダッシュボードの Authentication > Users > Add user で
--    メールとパスワードのユーザーを1つ作っておく（Auto Confirm User を ON）。
--    そのうえで、下のメールアドレスを書き換えて実行する。
-- ---------------------------------------------------------------------
insert into public.admin_users (user_id, email)
select id, email from auth.users where email = 'you@example.com'
on conflict (user_id) do nothing;

-- 確認: select * from public.admin_users;

-- ---------------------------------------------------------------------
-- 2) 動作確認用のイベント
--    時刻はすべて日本時間で書いている（'+09' が JST の意味）。
--    下の例は「今すぐ応募受付 → 5分後に締切 → その直後に第1回抽選」。
-- ---------------------------------------------------------------------
insert into public.events (
  slug, name, description,
  entry_open_at, entry_close_at, first_draw_at,
  winners_count, claim_window_minutes, max_rounds,
  ticket_prefix, status
) values (
  'test-2026',
  'テスト抽選販売',
  '動作確認用のイベントです。',
  now(),                        -- 応募開始
  now() + interval '5 minutes', -- 応募締切
  now() + interval '5 minutes', -- 第1回抽選（締切と同時）
  3,                            -- 当選枠 3
  10,                           -- 使用期限 10分
  4,                            -- 第1回＋再抽選3回まで
  'T-',
  'open'
)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- 本番用イベントの例（時刻を明示的に指定する書き方）
-- ---------------------------------------------------------------------
-- insert into public.events (
--   slug, name, description,
--   entry_open_at, entry_close_at, first_draw_at,
--   winners_count, claim_window_minutes, max_rounds,
--   ticket_prefix, status
-- ) values (
--   'autumn-2026',
--   '2026秋 限定モデル 抽選販売',
--   '当選された方は期限までに店頭でお買い上げください。',
--   '2026-10-01 10:00+09',   -- 応募開始
--   '2026-10-07 23:59+09',   -- 応募締切
--   '2026-10-08 12:00+09',   -- 第1回抽選
--   50,                      -- 当選枠
--   2880,                    -- 使用期限 48時間
--   5,                       -- 抽選は最大5回まで
--   'A-',
--   'open'
-- );

-- ---------------------------------------------------------------------
-- 3) 応募をダミーで流し込んで抽選を試す（テスト用）
-- ---------------------------------------------------------------------
-- select public.issue_ticket('test-2026', 'tester' || g || '@example.com')
--   from generate_series(1, 20) g;
--
-- 抽選時刻まで待たずに試すなら:
--   update public.events set first_draw_at = now(), entry_close_at = now()
--    where slug = 'test-2026';
--   select public.tick();
--   select ticket_no, email, status, round_won, expires_at
--     from public.entries e join public.events v on v.id = e.event_id
--    where v.slug = 'test-2026' order by ticket_no;
--
-- 次点抽選の確認（当選者を誰も消し込まないまま期限を過ぎさせる）:
--   update public.entries set expires_at = now()
--    where status = 'won'
--      and event_id = (select id from public.events where slug = 'test-2026');
--   select public.tick();
--
-- 後片付け:
--   delete from public.events where slug = 'test-2026';  -- entries/draws も消える
