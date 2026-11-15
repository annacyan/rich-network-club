/* Supabase 連線設定（anon key 是公開金鑰，可以放在網頁裡；資料安全靠資料庫權限規則保護） */
window.RICH_CONFIG = {
  url: '',        /* 例：https://xxxx.supabase.co */
  anonKey: '',    /* Supabase → Project Settings → API → anon public */
  google: true    /* Google 登入設定好之前可改成 false 隱藏按鈕 */
};
