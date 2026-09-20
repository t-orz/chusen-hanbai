-- =====================================================================
-- RLS と権限
-- 02_logic.sql のあとに実行する。
--
-- 方針:
--   entries（メールアドレスを持つ表）は anon から直接は一切触れない。
--   応募と照会は SECURITY DEFINER の RPC 3本だけを窓口にする。
--   管理画面は Supabase Auth でログインし、admin_users に居る人だけ通す。
-- =====================================================================

alter table public.events      enable row level security;
alter table public.entries     enable row level security;
alter table public.draws       enable row level security;
alter table public.admin_users enable row level security;

-- events : 下書き以外は誰でも読める。書けるのは管理者だけ。
drop policy if exists events_public_read on public.events;
create policy events_public_read on public.events
  for select to anon, authenticated using (status <> 'draft');

drop policy if exists events_admin_all on public.events;
create policy events_admin_all on public.events
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- entries : 管理者のみ。anon にはポリシーを1つも作らない＝全拒否。
drop policy if exists entries_admin_all on public.entries;
create policy entries_admin_all on public.entries
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- draws : 抽選履歴は公開（透明性のため）。書き込みは管理者のみ。
drop policy if exists draws_public_read on public.draws;
create policy draws_public_read on public.draws
  for select to anon, authenticated using (true);

drop policy if exists draws_admin_all on public.draws;
create policy draws_admin_all on public.draws
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- admin_users : 自分の行だけ読める（管理画面のログイン判定用）
drop policy if exists admin_users_self_read on public.admin_users;
create policy admin_users_self_read on public.admin_users
  for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- 関数の実行権限
-- ---------------------------------------------------------------------
-- 既定の実行権限をいったん全部剥がしてから、必要なものだけ配り直す。
-- Supabase は anon / authenticated にも既定で execute を配るので、
-- PUBLIC から剥がすだけでは足りない。3つとも明示的に revoke する。
do $do$
declare f text;
begin
  foreach f in array array[
    'public.run_draw(uuid, text)',
    'public.tick()',
    'public.event_public(text)',
    'public.issue_ticket(text, text)',
    'public.lookup_ticket(text, text, text)',
    'public.admin_redeem(uuid, boolean)',
    'public.admin_unredeem(uuid)',
    'public.admin_set_void(uuid, boolean)',
    'public.admin_run_draw(uuid)',
    'public.admin_force_expire(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end
$do$;

-- 一般公開ページが叩く3本
grant execute on function public.event_public(text)              to anon, authenticated;
grant execute on function public.issue_ticket(text, text)        to anon, authenticated;
grant execute on function public.lookup_ticket(text, text, text) to anon, authenticated;

-- 管理画面が叩くもの（関数の中でも is_admin() を再チェックしている）
grant execute on function public.admin_redeem(uuid, boolean)   to authenticated;
grant execute on function public.admin_unredeem(uuid)          to authenticated;
grant execute on function public.admin_set_void(uuid, boolean) to authenticated;
grant execute on function public.admin_run_draw(uuid)          to authenticated;
grant execute on function public.admin_force_expire(uuid)      to authenticated;

-- 抽選そのものはサーバー側（cron / service_role）だけが呼べる
grant execute on function public.run_draw(uuid, text) to service_role;
grant execute on function public.tick()               to service_role;
