-- =====================================================================
-- 毎分 tick() を呼ぶスケジュール登録
-- 03_rls_grants.sql のあとに、SQL Editor で1回だけ実行する。
--
-- pg_cron は Supabase の Database > Extensions からも有効化できる。
-- ここで create extension しているので、通常はこのファイルだけでよい。
-- =====================================================================

create extension if not exists pg_cron with schema cron;

-- 二重登録を避けるため、同名のジョブがあれば消してから入れ直す
select cron.unschedule(jobid) from cron.job where jobname = 'chusen-tick';

select cron.schedule(
  'chusen-tick',
  '* * * * *',              -- 毎分
  $$ select public.tick(); $$
);

-- 確認用:
--   select jobid, jobname, schedule, active from cron.job where jobname = 'chusen-tick';
--   select * from cron.job_run_details order by start_time desc limit 20;
--
-- 毎分が過剰なら '*/5 * * * *' などに落としてよい。
-- ただし抽選は「指定時刻ちょうど」ではなく「次の tick」で走るので、
-- 刻みを粗くするとその分だけ抽選が遅れる。
