-- =====================================================================
-- 掲示物（PDF）に印刷する項目をイベント設定に追加する
-- 01〜10 のあとに実行する。
--
-- 掲示物には「システムが知っている情報」と「運営しか知らない情報」がある。
-- 日程や当選枠は前者なので自動で埋まるが、主催者名・問い合わせ先・注意事項は
-- 後者なので、イベントごとに入力してもらう。
-- =====================================================================

alter table public.events add column if not exists organizer    text not null default '';
alter table public.events add column if not exists contact_info  text not null default '';
alter table public.events add column if not exists notice        text not null default '';
alter table public.events add column if not exists privacy_note  text not null default
  'ご入力いただいたメールアドレスは、本抽選の実施と当落のご確認のためにのみ使用し、'
  '本イベントの終了後に削除します。第三者への提供はいたしません。';

-- ---------------------------------------------------------------------
-- event_public に載せる
--   掲示物だけでなく利用者ページにも出す。
--   紙を見ずにページだけ開いた人にも、同じ条件が伝わるようにするため。
-- ---------------------------------------------------------------------
create or replace function public.event_public(p_event_no text)
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
    'organizer', v_ev.organizer, 'contact_info', v_ev.contact_info,
    'notice', v_ev.notice, 'privacy_note', v_ev.privacy_note,
    'ticket_prefix', v_ev.ticket_prefix,
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

revoke all on function public.event_public(text) from public, anon, authenticated;
grant execute on function public.event_public(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 確認
-- ---------------------------------------------------------------------
-- select event_no, name, organizer, contact_info, notice from public.events;
