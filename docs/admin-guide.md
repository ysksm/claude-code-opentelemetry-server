# 管理画面の利用の手引き

収集サーバーを運用する人と、利用状況を見る人（チームリーダー・管理部門）向けの手引きです。
管理画面は Grafana で、3 案（B・D・D′）とも同じ見た目のダッシュボード「Claude Code 利用状況」が入っています。
サーバーの起動手順は [`deploy/README.md`](../deploy/README.md)、利用者側の設定は [`overview.md`](overview.md) を参照してください。

- [1. 開く](#1-開く)
- [2. ダッシュボードの見方](#2-ダッシュボードの見方)
- [3. よくある使い方](#3-よくある使い方)
- [4. 利用者を追加する（オンボーディング）](#4-利用者を追加するオンボーディング)
- [5. 閲覧者のアカウントを作る](#5-閲覧者のアカウントを作る)
- [6. 日々の運用](#6-日々の運用)
- [7. 困ったとき](#7-困ったとき)

## 1. 開く

| 項目 | 値 |
|---|---|
| URL | `https://<SITE_ADDRESS>/`（`.env` の `SITE_ADDRESS`） |
| ユーザー | `admin` |
| パスワード | `.env` の `GRAFANA_ADMIN_PASSWORD` |
| ダッシュボード | 左メニュー「Dashboards」→ フォルダ「Claude Code」→「Claude Code 利用状況（…）」 |

- 証明書が Caddy の内部 CA（`tls internal`）の場合、ブラウザに警告が出ます。サーバーから取り出した `caddy-root.crt` を
  OS の信頼ストアに入れてください（macOS はキーチェーンアクセスで「常に信頼」、Windows は「信頼されたルート証明機関」）。
- `admin` は管理用です。見るだけの人には別のアカウントを作ってください（[5.](#5-閲覧者のアカウントを作る)）。
- 利用者が自分でアカウントを作ることはできません（`GF_USERS_ALLOW_SIGN_UP=false`）。

## 2. ダッシュボードの見方

右上の時間範囲（既定は「Last 7 days」）がすべてのパネルに効きます。表示は 5 分ごとに更新されます。

| 段 | 左 | 右 |
|---|---|---|
| 1 段目（期間合計） | コスト・トークン | セッション数・利用者数 |
| 2 段目（推移） | モデル別コスト | 種類別トークン |
| 3 段目（誰が・どこで） | 利用者別コスト | リポジトリ別コスト |
| 4 段目（何に） | Skill の発動 | ツール実行の結果 |
| 5 段目（確認・監査） | イベント種別ごとの件数 | 拒否されたツール実行（B）／ 実行された Bash コマンド（D・D′） |

| パネル | 何が分かるか | 元のデータ |
|---|---|---|
| コスト（期間合計） | 期間中の API 利用料の概算（USD） | メトリクス `claude_code.cost.usage` |
| トークン（期間合計） | 入力・出力・キャッシュを合わせたトークン数 | メトリクス `claude_code.token.usage` |
| セッション数 | Claude Code を起動した回数 | メトリクス `claude_code.session.count` |
| 利用者数 | 期間中にコストが発生した人数 | `user.email` の数 |
| モデル別コスト | Opus・Sonnet・Haiku などモデルごとの推移 | `model` 属性 |
| 種類別トークン | `input` / `output` / `cacheRead` / `cacheCreation` の推移。キャッシュ読み取りが多いほど安く済んでいる | `type` 属性 |
| 利用者別コスト | 人ごとの合計。上から多い順 | `user.email` |
| リポジトリ別コスト | どのリポジトリでの作業に使ったか | `vcs.repository.name`（`OTEL_METRICS_INCLUDE_REPOSITORY=true` のとき） |
| Skill の発動 | 利用者 × リポジトリ × Skill ごとの回数と起動方法 | イベント `skill_activated` |
| ツール実行の結果 | ツール（Bash・Edit・Read など）ごとの成功・失敗の回数（D・D′ は平均実行時間も） | イベント `tool_result` |
| イベント種別ごとの件数 | 届いているイベントの種類と件数。データが来ているかの確認にも使う | すべてのイベント |
| 拒否されたツール実行（B のみ） | 利用者が許可しなかった操作の記録 | イベント `tool_decision`（`decision=reject`） |
| 実行された Bash コマンド（D・D′ のみ） | 誰がどのリポジトリでどのコマンドを実行したか（監査用） | イベント `tool_result` の `tool_parameters`。利用者側で `OTEL_LOG_TOOL_DETAILS=1` のときだけ入る |

### 数値を読むときの注意

- **コストは概算です。** Claude Code がトークン数から計算した値で、請求額とは一致しません。サブスクリプション（Pro・Max・Team・Enterprise の
  席）で使っている場合も、従量課金に換算した値が出ます。
- **案 B の値は「`anchored`」で数えています。** 外挿しないので、メトリクスのコストとイベント（`api_request` の `cost_usd`）の合計が一致します。
  時間の推移グラフは、表示幅に応じた区間（`$__interval`）ごとの増分です。
- **案 D・D′ の時間の推移は 1 時間ごと**に集計しています。
- **案 D′ は最大 5 分（`CONVERT_INTERVAL_SECONDS`）遅れて**反映されます。直近のデータが出ないときは待ってください。
- 利用者が端末を閉じたまま（スリープ・オフライン）だと、送信されなかった分は出ません。

## 3. よくある使い方

| やりたいこと | 操作 |
|---|---|
| 先月の利用者別コストを出す | 時間範囲で「Previous month」→「利用者別コスト」のパネルメニュー（⋮）→ Inspect → Data →「Download CSV」 |
| 特定のリポジトリだけ見る | 「リポジトリ別コスト」で確認。詳しく見るときは Explore（左メニュー）で `vcs_repository_name`（B）／`LogAttributes['vcs.repository.name']`（D）で絞る |
| 1 つのパネルを大きく見る | パネルにマウスを載せて `v` キー（もう一度で戻る） |
| 期間を拡大する | 時系列グラフ上でドラッグ |
| 画面を共有する | 右上の「Share」→ リンクをコピー（相手にも Grafana のアカウントが必要） |
| SQL で分析する（D・D′） | [`deploy/README.md`](../deploy/README.md) の「分析 SQL の例」 |

ダッシュボードはファイルから読み込んでいるので（`allowUiUpdates: false`）、画面上で変更しても保存できません。
変えたいときは「Save as」で別のダッシュボードとして保存するか、`deploy/<案>/grafana/dashboards/claude-code.json` を
変更してプルリクエストを出してください（3 案のファイルをそろえて変えます）。

## 4. 利用者を追加する（オンボーディング）

利用者の端末で Claude Code がテレメトリを送るように設定します。2 つの方法があります。

### 個人で設定してもらう（〜数十名、試験導入）

1. サーバーで CA 証明書を取り出す（`tls internal` の場合だけ）。

   ```bash
   docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
   ```

2. 利用者に次の 3 つを渡す。トークンはチャットに貼らず、パスワード管理ツールなどで渡してください。
   - [`deploy/common/client/setup-client.sh`](../deploy/common/client/setup-client.sh)
   - `caddy-root.crt`
   - URL（`https://<SITE_ADDRESS>`）とトークン（`.env` の `OTEL_INGEST_TOKEN`）

3. 利用者が実行する。

   ```bash
   OTEL_INGEST_TOKEN=<トークン> ./setup-client.sh \
     --endpoint https://otel.example.internal --ca-cert ./caddy-root.crt \
     --attributes department=eng,team.id=platform   # 部署で集計したい場合
   ```

   スクリプトは接続確認（トークンが正しいか、証明書が通るか）をしてから `~/.claude/settings.json` の `env` に書き足します。
   既存の設定は変えず、書き換え前にバックアップを取ります。止めるときは `--uninstall` です。

4. 利用者が Claude Code を一度使ったあと、ダッシュボードの「利用者別コスト」にそのメールアドレスが出ることを確かめる。

### 組織で一括して配る（数十名〜）

managed settings に書くと、利用者が自分で外すことはできません。

- 端末ごとに root で実行する：`sudo OTEL_INGEST_TOKEN=<トークン> ./setup-client.sh --scope managed --endpoint ... --ca-cert ...`
  （macOS は `/Library/Application Support/ClaudeCode/managed-settings.json`、Linux は `/etc/claude-code/managed-settings.json`）
- MDM（Jamf・Intune など）で配る：`./setup-client.sh --print --endpoint ... --ca-cert ...` で出る内容を managed-settings.json として配り、
  `caddy-root.crt` を出力に書かれた場所に置きます（トークンの部分は `REPLACE_WITH_OTEL_INGEST_TOKEN` になっているので置き換えます）。

### 部署・チームで集計する

`--attributes` で付けた属性は、案 B では Prometheus のラベルになります（使えるキーは
[`prometheus.yml`](../deploy/b-grafana/prometheus/prometheus.yml) の `promote_resource_attributes`：`department`・`team.id`・`cost_center`・`enduser.id`）。
案 D・D′ では `ResourceAttributes` / `resource_attributes` に入るので、SQL でそのまま使えます。
ダッシュボードには部署別のパネルはまだないので、Explore か「Save as」した複製にパネルを足してください。

## 5. 閲覧者のアカウントを作る

1. `admin` でログインし、左メニュー「Administration」→「Users and access」→「Users」→「New user」。
2. 名前・メールアドレス・ユーザー名・初期パスワードを入れて作成する。
3. 作成したユーザーの「Organizations」で役割を選ぶ。

| 役割 | できること | 渡す相手 |
|---|---|---|
| Viewer | ダッシュボードを見る・CSV を落とす | チームリーダー、管理部門 |
| Editor | ダッシュボードを複製・作成、Explore でクエリを書く | 分析する人 |
| Admin | ユーザー管理、データソースの変更 | サーバーの運用者だけ |

利用者別コストや Bash コマンド（D・D′）は個人の作業内容に関わる情報です。誰に見せるかを先に決め、必要な人だけに
アカウントを作ってください。Viewer にも「実行された Bash コマンド」は見えます。

## 6. 日々の運用

### データが届いているかを確かめる

サーバー上で：

```bash
docker compose ps                                 # すべて running / healthy か
docker compose logs --since 10m collector         # 401 やエクスポートの失敗が出ていないか
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/x-protobuf' \
  -H "Authorization: Bearer $(grep ^OTEL_INGEST_TOKEN .env | cut -d= -f2)" \
  --data-binary '' http://127.0.0.1:4318/v1/metrics   # 200 なら Collector は受け付けている
```

ダッシュボードの「イベント種別ごとの件数」が増えていれば、保存先まで届いています。

### トークンを入れ替える

トークンは全利用者で共通です。漏れたとき、または退職者が出たときは入れ替えます。

1. `.env` の `OTEL_INGEST_TOKEN` を新しい値にする（`openssl rand -hex 32`）。
2. `docker compose up -d collector` で Collector を作り直す（案 B は集計の状態がリセットされますが、`increase()` が扱えるので値は崩れません）。
3. 全利用者に新しいトークンで `setup-client.sh` をもう一度実行してもらう（managed なら配り直す）。それまでの間、古いトークンの端末からの送信は 401 で捨てられます。

### 保持期間とディスク

| 案 | 設定（`.env`） | 既定 |
|---|---|---|
| B | `PROMETHEUS_RETENTION`、`LOKI_RETENTION` | 400 日、90 日（2160h） |
| D | `CLICKHOUSE_TTL`（テーブル作成時にだけ反映） | 2 年（17520h） |
| D′ | `RAW_RETENTION_DAYS`（JSONL の原本）、`PARQUET_RETENTION_DAYS`（0 = 消さない） | 400 日、消さない |

変えたら `docker compose up -d` で反映します。ディスクの使用量は `docker system df -v`（D′ は `du -sh data/*`）で確認します。

### バックアップ

| 案 | 対象 |
|---|---|
| B | ボリューム `prometheus-data`、`loki-data`、`grafana-data` |
| D | ボリューム `clickhouse-data`、`grafana-data` |
| D′ | ディレクトリ `data/`（`raw/` が原本。`parquet/` は `raw/` から作り直せる）、ボリューム `grafana-data` |

`caddy-data` には内部 CA の鍵が入っています。失うと証明書が変わり、全利用者に `caddy-root.crt` を配り直すことになるので、これもバックアップしてください。
`.env` もトークンとパスワードが入っているので、リポジトリには入れず別に保管します。

### バージョンを上げる

`.env` のイメージのバージョン（`*_VERSION`）を変えてプルリクエストにし、`docker compose pull && docker compose up -d`（D′ は `docker compose build` も）。

## 7. 困ったとき

| 症状 | 確かめること |
|---|---|
| ある利用者のデータが出ない | 利用者に `setup-client.sh --check` を実行してもらう。OK なら Claude Code を再起動したか（設定は起動時に読まれる）、`.claude/settings.json`（リポジトリ側）に書いていないか（OTel の設定は無視される） |
| `--check` が 401 | トークンが違う。入れ替え後の古いトークンを使っていないか |
| `--check` が「証明書を検証できません」 | `--ca-cert` で `caddy-root.crt` を渡したか。Caddy のボリュームを作り直して CA が変わっていないか |
| `--check` は OK なのにデータが来ない | `--check` は curl で確かめるので、Claude Code 側の証明書の読み込みまでは確かめていない。Claude Code を再起動したか確認し、それでも来なければ `NODE_EXTRA_CA_CERTS=~/.claude/otel/ca.crt` をシェルの環境変数にも設定して試す |
| 「サーバーに接続できません」 | 端末から 443 番に届くか（VPN、ファイアウォール）。`SITE_ADDRESS` の名前を引けるか |
| ブラウザで Grafana が証明書エラー | `caddy-root.crt` を OS の信頼ストアに入れる |
| 全員分のデータが止まった | `docker compose ps` と `docker compose logs collector`。D は ClickHouse、B は Prometheus・Loki が動いているか。ディスクが一杯になっていないか |
| D′ で直近のデータだけ出ない | 変換の間隔（既定 5 分）を待つ。`docker compose logs converter` |
| 「実行された Bash コマンド」が空 | 利用者側で `--tool-details`（`OTEL_LOG_TOOL_DETAILS=1`）を付けていない。付けるかは組織の方針で決める |
| リポジトリ別コストが空欄 | Git リポジトリの外で使っている、または `OTEL_METRICS_INCLUDE_REPOSITORY` が入っていない |
| コストが請求額と合わない | ダッシュボードの値は概算（[2.](#数値を読むときの注意)） |
