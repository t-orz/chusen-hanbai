// ---------------------------------------------------------------------
// 接続設定
//
// SUPABASE_ANON_KEY は公開して構わないキー（ブラウザに配る前提のもの）。
// RLS と RPC の権限で守る設計なので、ここに書いて GitHub に上げてよい。
//
// !! service_role キーは絶対にここに書かない !!
//
// 取得場所:
//   https://supabase.com/dashboard/project/kfqlwxmehwzsuhzdtpnc/settings/api
//   Project API keys の "anon / public" をコピーする。
// ---------------------------------------------------------------------
window.APP_CONFIG = {
  SUPABASE_URL: 'https://kfqlwxmehwzsuhzdtpnc.supabase.co',
  SUPABASE_ANON_KEY: 'ここに anon public キーを貼る',

  // ?e=slug が URL に無いときに使うイベント
  DEFAULT_EVENT_SLUG: 'test-2026',
};
