// ---------------------------------------------------------------------
// 接続設定
//
// SUPABASE_ANON_KEY に入れているのは publishable key（旧 anon キーの後継）。
// ブラウザに配る前提のキーで、守りは Supabase 側の RLS と RPC 権限が担う。
// そのため、ここに書いて公開リポジトリに上げてよい。
//
// !! secret key / service_role キーは絶対にここに書かない !!
//
// 差し替える場所:
//   https://supabase.com/dashboard/project/kfqlwxmehwzsuhzdtpnc/settings/api-keys
//   「Publishable and secret API keys」タブの Publishable key
// ---------------------------------------------------------------------
window.APP_CONFIG = {
  SUPABASE_URL: 'https://kfqlwxmehwzsuhzdtpnc.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_BgFgORq4meC2WjxhTsGwlw_ocZ9VyUd',

  // ?e= が URL に無いときに開くイベント番号
  DEFAULT_EVENT_NO: '',
};
