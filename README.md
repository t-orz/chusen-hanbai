# 抽選販売 整理番号アプリ

Web で整理番号を配り、指定時刻に設定数だけランダムに当選させ、
当選が使用期限までに利用されなければ空き枠ぶんだけ次点をランダムに再抽選する。
これを上限回数まで、または全枠が消化されるまで繰り返す。

- バックエンド: Supabase (PostgreSQL + RLS + pg_cron)
- フロント: 静的 HTML + supabase-js (CDN)。ビルド不要、Node.js 不要
- 配信: GitHub Pages

Supabase プロジェクト: `kfqlwxmehwzsuhzdtpnc`

---

## 仕組み

抽選そのものは PostgreSQL の関数 `run_draw()` が行う。
`pg_cron` が毎分 `tick()` を呼び、開催中のイベントを1歩ずつ進める。

`run_draw()` の1回ぶん:

1. 使用期限を過ぎた当選（`won`）を `expired` にする
2. 期限内の当選が1件でも残っていれば何もしない（まだ待つ時間）
3. 空き枠 = 当選枠数 − 利用済み数 を数える
4. 未当選の応募者から、空き枠ぶんだけ `order by random()` で選び `won` にする
5. 使用期限 = 当選時刻 + `claim_window_minutes` を全員に付ける
6. 次のいずれかで `finished`: 全枠が利用済み / 抽選回数が `max_rounds` に到達 / 未当選者が尽きた

第1回も再抽選も同じ関数が処理する。回ごとの記録は `draws` に1行ずつ残る。

イベント行を `for update` でロックしてから進めるので、cron と管理画面の手動実行が
同時に走っても二重抽選にはならない。

### 状態遷移

```
entered ──抽選で当選──> won ──期限までに利用──> redeemed
                          │
                          └──期限切れ──> expired   （枠が空き、次回の再抽選へ）
```

---

## セットアップ

### 1. SQL を流す

[SQL Editor](https://supabase.com/dashboard/project/kfqlwxmehwzsuhzdtpnc/sql/new)
で `supabase/` のファイルを **番号順に** 貼り付けて実行する。

| ファイル | 内容 |
| --- | --- |
| `01_schema.sql` | テーブル4つ |
| `02_logic.sql` | 抽選ロジックと RPC |
| `03_rls_grants.sql` | RLS と実行権限 |
| `04_cron.sql` | 毎分の自動処理を登録 |
| `05_admin_and_sample.sql` | 管理者登録とテスト用イベント（中身を書き換えてから） |
| `06_timezone_jst.sql` | 日本時間で読み書きするための設定と確認用ビュー |
| `07_admin_bootstrap.sql` | 許可リストに載ったメールを自動で管理者にする |
| `08_store_entry_codes.sql` | 来店者限定の応募（店内掲示 QR コード） |

`04_cron.sql` が `extension "pg_cron" is not available` で落ちる場合は、
Database > Extensions で `pg_cron` を有効化してから再実行する。

### 2. 管理者アカウントを作る

`07_admin_bootstrap.sql` を流してあれば、許可リストに載っているメールアドレスの
ユーザーを作るだけで自動的に管理者になる。

1. `admin_allowlist` にメールアドレスを入れる
   ```sql
   insert into public.admin_allowlist (email, note) values ('you@example.com', '運営');
   ```
2. Authentication > Users > **Add user** > **Create new user** で同じアドレスの
   ユーザーを作る（**Auto Confirm User** を ON にする）

`admin_users` に行が入っていないアカウントは管理画面に入れない。
先にユーザーを作ってしまった場合は `07_admin_bootstrap.sql` の末尾の insert を流す。

### 3. 公開キー（設定済み）

`config.js` には publishable key（旧 anon キーの後継）を入れてある。

```js
SUPABASE_ANON_KEY: 'sb_publishable_...',
```

ブラウザに配る前提のキーなので、公開リポジトリに入れて構わない。
守りは Supabase 側の RLS と RPC 権限が担っている。
**secret key / service_role キーは絶対にここへ書かない。**

差し替えが必要になったら
[Settings > API Keys](https://supabase.com/dashboard/project/kfqlwxmehwzsuhzdtpnc/settings/api-keys)
の「Publishable and secret API keys」タブから取る。

同じ画面の「Legacy anon, service_role API keys」タブに旧 anon キーも残っているが、
Supabase は publishable key の利用を推奨しており、旧キーは将来無効化できる扱いになっている。

### 4. 動作を確認する

`index.html` をブラウザで直接開けば、そのまま動く（サーバー不要）。

`05_admin_and_sample.sql` のコメント内にテスト手順がある。
ダミー応募20件を入れ、抽選時刻を `now()` に書き換えて `select public.tick();` を叩き、
次に当選者の `expires_at` を `now()` にしてもう一度 `tick()` を叩くと、
次点抽選まで一通り確認できる。

### 5. GitHub Pages に上げる

HTML はリポジトリ直下に置いてある（Pages のブランチ配信はルートか `/docs` しか
選べないため）。

```bash
cd ~/Documents/chusen-app
git add -A && git commit -m "抽選販売アプリ"
gh repo create <リポジトリ名> --public --source=. --push
gh api -X POST repos/t-orz/<リポジトリ名>/pages -f 'source[branch]=main' -f 'source[path]=/'
```

公開URL（`t-orz` の場合）:

| 画面 | URL |
| --- | --- |
| 利用者用 | `https://t-orz.github.io/<リポジトリ名>/?e=<slug>` |
| 運営ログイン | `https://t-orz.github.io/<リポジトリ名>/login.html` |
| 運営用 | `https://t-orz.github.io/<リポジトリ名>/admin.html` |

`admin.html` は誰でも URL を開けるが、セッションが無ければ `login.html` に
送り返されるだけで中身は何も出ない。データ側は RLS と `is_admin()` で守られている。

### 6. Supabase に公開URLを登録する

Authentication > URL Configuration の **Site URL** に Pages の URL を入れておく。
（メール系の機能を後から足すときに必要になる。パスワードログインだけなら未設定でも動く）

---

## イベントの設定項目

管理画面から作成・編集できる。

| 項目 | 説明 |
| --- | --- |
| slug | 公開URL の `?e=` に入る文字列。作成後は変えられない |
| 応募開始 / 応募締切 | この間だけ整理番号を発行する |
| 第1回抽選 | 応募締切以降であること |
| 当選枠 | 何人当選させるか |
| 使用期限（分） | 当選から何分以内に利用する必要があるか。1440 = 24時間 |
| 抽選の最大回数 | 第1回を含む。3 なら再抽選は2回まで |
| 整理番号の接頭辞 | `A-` とすると `A-0001` から連番で発行される |
| 状態 | `draft` は非公開。`open` で稼働。`finished` / `cancelled` で停止 |

---

## 運用

### 消し込み

管理画面の応募一覧で状態を「当選中」に絞り、番号を確認して **消し込み** を押す。
期限を過ぎたものを消し込むときは確認ダイアログが出る（枠は戻らず利用済みになる）。

**取消** を押すと消し込みが取り消され、枠は空きに戻る。

### 手動で抽選を進める

「いま抽選を1回進める」は `run_draw()` を即座に呼ぶ。
ただし期限内の当選者が残っているうちは `winners_pending` で何もしない。

期限を待たずに次点へ回したい場合は「当選中を全部いま失効させる」を実行してから
もう一度「いま抽選を1回進める」を押す。

### 抽選のタイミングの精度

抽選は「指定時刻ちょうど」ではなく「指定時刻を過ぎた最初の tick」で走る。
毎分の cron なので、実際の実行は指定時刻から最大1分遅れる。

---

## 来店者限定の応募（店内掲示 QR）

イベント設定で「来店者限定」にすると、店内に掲示した QR コードを読み取った人しか
整理番号を受け取れなくなる。

### 流れ

```
店内のポスター     ?e=<slug>&k=<秘密コード> を QR にしたもの
      │ 読み取る
      ▼
claim_store_pass()  入店パスを1枚発行（30分有効・1回限り・ID は推測不能な uuid）
      │             URL から k を消して、アドレスバーに残らないようにする
      ▼
issue_ticket()      有効なパスが無ければ拒否。使うとパスは消費済みになる
      ▼
整理番号
```

### 運用

1. イベント設定で「応募できる人」を**来店者限定**にする
2. 「店内掲示コード」でコードを発行する（掲示場所ごとに複数可、上限人数も設定可）
3. 「QR を印刷」で掲示物を出して店内に貼る

管理画面では各コードの **発行数**（実際に整理番号が出た数）と **読み取り**（QR を読んだ数）
が並んで見える。読み取りだけが伸びて発行数が伸びない場合は、離脱か不正の兆候。

### この方式の限界

**印刷した QR の URL は、撮影して転送されれば店外からでも使える。**
静的な QR である以上これは消せない。そのため次を用意してある。

| 手段 | 効果 |
| --- | --- |
| 上限人数 | そのコードから出せる整理番号の総数を頭打ちにする |
| 読み取り数の可視化 | 拡散されると読み取り数が跳ねるので気づける |
| コードの停止と再発行 | 拡散されたら停止し、新しいコードで刷り直す |
| 30分の有効期限 | 転送された URL がいつまでも使えるわけではない |
| sessionStorage 保存 | タブを閉じるとパスが消える |

上限は「実際に整理番号が出た数」で数えている。QR を読んだだけでは減らないので、
悪意のある人が空スキャンを繰り返して枠を潰すことはできない。

転載を実質的に防ぎたい場合は、印刷ではなく店内のモニターに
数十秒ごとに変わる QR を出す方式が要る。今の実装には入っていない。

---

## 時刻の扱い

**このアプリの日時はすべて日本時間（JST）で考える。**

保存は `timestamptz`（絶対時刻）なので、内部的には UTC で持っている。
そのうえで、人が見る側と書く側を JST に固定している。

| 場所 | どうしているか |
| --- | --- |
| DB の保存値 | `timestamptz`。絶対時刻なので比較は常に正しい |
| SQL Editor | `06_timezone_jst.sql` で `Asia/Tokyo` を既定にしている |
| REST API の戻り値 | 同ファイルで `authenticator` ロールも JST にしてある（`+09:00` 付きで返る） |
| 画面の表示 | `toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' })` で JST 固定 |
| 管理画面の日時入力 | `+09:00` を明示して JST として解釈する |

日時入力を端末のタイムゾーンに任せていない点が要点。
海外から開いたり PC の時計設定がずれていたりしても、
入力した「10:00」は常に JST の 10:00 になる。

SQL で中身を確認するときは JST 表示のビューを使う。

```sql
select * from public.entries_jst where event_slug = 'autumn-2026' order by ticket_no;
select * from public.draws_jst   where event_slug = 'autumn-2026' order by round_no;
```

### pg_cron だけは注意

`cron.schedule` の時刻指定は **UTC で解釈される**。
今の設定は `'* * * * *'`（毎分）なのでタイムゾーンの影響を受けないが、
`'0 12 * * *'` のような時刻指定に変える場合は JST から9時間引くこと
（JST 12:00 なら `'0 3 * * *'`）。

---

## セキュリティ

- `entries`（メールアドレスを持つ表）は anon から直接は一切読めない。
  RLS を有効にし、anon 向けのポリシーを1つも作っていない。
- 応募と照会は `SECURITY DEFINER` の RPC 3本（`event_public` / `issue_ticket` /
  `lookup_ticket`）だけが窓口。
- 照会には整理番号とメールアドレスの両方が要る。番号だけの総当たりはできない。
- 管理RPCは `is_admin()` を関数の中で再チェックしている。
  RLS ポリシーだけに頼っていない。
- 抽選を回す `run_draw` / `tick` は `service_role` にしか実行権限がない。
  ブラウザからは呼べない。

### 残っている弱点

- メールアドレスの到達確認はしていない。存在しないアドレスでも整理番号は取れる。
  厳密にやるならワンタイムコード認証を足す。
- 同一人物が複数アドレスで応募することは防げない。

---

## ファイル構成

```
index.html                利用者用画面（整理番号の発行・当落照会）
login.html                運営用ログインページ
admin.html                運営用画面（未ログインなら login.html へ転送）
qr.html                   掲示用 QR の印刷ページ（管理者のみ）
config.js                 接続設定（anon キーをここに入れる）
style.css                 共通スタイル
.nojekyll                 Pages に Jekyll 処理をさせない印
supabase/
  01_schema.sql           テーブル定義
  02_logic.sql            run_draw / tick / 公開RPC / 管理RPC
  03_rls_grants.sql       RLS ポリシーと実行権限
  04_cron.sql             pg_cron への登録
  05_admin_and_sample.sql 管理者登録・テスト用イベント・確認手順
  06_timezone_jst.sql     日本時間の設定と JST 表示ビュー
  07_admin_bootstrap.sql  許可リストによる管理者の自動登録
  08_store_entry_codes.sql 来店者限定の応募（店内掲示 QR）
```

画面のつながり:

```
index.html   利用者   … 整理番号をもらう / 当落を照会する（ログイン不要）

login.html   運営     … メール + パスワード
     │                  admin_users に居るか確認
     ▼
admin.html   運営     … イベント設定 / 抽選操作 / 応募一覧 / 消し込み
     │
     └─ セッション切れ・ログアウト → login.html へ戻る
```
