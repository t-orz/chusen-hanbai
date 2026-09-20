-- =====================================================================
-- 管理者アカウントの自動登録
--
-- 問題: 管理者にするには auth.users にユーザーが居ることが前提で、
--       ユーザー作成（パスワード設定）はダッシュボードでの手作業になる。
--       そのたびに admin_users への insert を手で流すのは忘れやすい。
--
-- 解決: 許可リストに載っているメールアドレスのユーザーが作られたら、
--       トリガーが自動で admin_users に入れる。
--       運用側は「Authentication > Users でユーザーを作る」だけでよくなる。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) 管理者にしてよいメールアドレスの許可リスト
-- ---------------------------------------------------------------------
create table if not exists public.admin_allowlist (
  email      text primary key,
  note       text not null default '',
  created_at timestamptz not null default now()
);

alter table public.admin_allowlist enable row level security;
-- anon / authenticated 向けのポリシーは作らない = 誰も読めない・書けない。
-- 追加や削除は SQL Editor から行う。

insert into public.admin_allowlist (email, note)
values ('mocco1230@gmail.com', '運営')
on conflict (email) do nothing;

-- ---------------------------------------------------------------------
-- 2) ユーザー作成時に管理者へ昇格させるトリガー
-- ---------------------------------------------------------------------
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql security definer set search_path = public
as $fn$
begin
  if exists (
    select 1 from public.admin_allowlist
     where lower(email) = lower(new.email)
  ) then
    insert into public.admin_users (user_id, email)
    values (new.id, new.email)
    on conflict (user_id) do nothing;
  end if;
  return new;
end;
$fn$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------
-- 3) すでに存在するユーザーの取り込み
--    トリガーは「これから作られるユーザー」にしか効かないので、
--    許可リストに追加したあとはこれを流す。何度実行してもよい。
-- ---------------------------------------------------------------------
insert into public.admin_users (user_id, email)
select u.id, u.email
  from auth.users u
  join public.admin_allowlist a on lower(a.email) = lower(u.email)
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------
-- 使い方
-- ---------------------------------------------------------------------
-- 管理者を増やす:
--   insert into public.admin_allowlist (email, note) values ('someone@example.com', '担当');
--   -- そのうえで Authentication > Users からユーザーを作る。
--   -- すでにユーザーが居る場合は上の 3) の insert を流す。
--
-- 管理者を外す:
--   delete from public.admin_users
--    where user_id = (select id from auth.users where email = 'someone@example.com');
--   delete from public.admin_allowlist where email = 'someone@example.com';
--
-- 確認:
--   select u.email, (a.user_id is not null) as is_admin
--     from auth.users u
--     left join public.admin_users a on a.user_id = u.id
--    order by u.created_at;
