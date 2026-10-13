# Claude Code 利用状況収集サーバー（docker compose）

Claude Code が OpenTelemetry（OTLP）で送るメトリクスとイベントを受けて保存し、Grafana で見るための構成です。
構成案の比較と考え方は [`docs/architecture.html`](../docs/architecture.html) を参照してください。

| ディレクトリ | 案 | 保存先 | 向いている場面 |
|---|---|---|---|
| [`b-grafana/`](b-grafana/) | B | Prometheus（メトリクス）＋ Loki（イベント） | リアルタイムのダッシュボードとアラート。〜数十名 |
| [`d-clickhouse/`](d-clickhouse/) | D | ClickHouse（両方） | SQL での分析、組織データとの JOIN、年単位の保管。数十〜数百名 |
| [`d-duckdb/`](d-duckdb/) | D′ | JSONL（原本）→ Parquet（DuckDB で変換） | 常駐 DB なしで SQL 分析と監査ログの原本保管。〜数十名 |

3 案とも次の部分は共通です。

```
Claude Code ──https──▶ caddy:443 ──/v1/*──▶ collector:4318（Bearer 認証）──▶ 各保存先
                                  └─それ以外─▶ grafana:3000
```

- 入口は Caddy 1 つで、1 つのホスト名で OTLP と Grafana を受けます（[`common/Caddyfile`](common/Caddyfile)）。
- 証明書は Caddy の内部 CA が発行します（`tls internal`）。公開 DNS 名で Let's Encrypt を使う場合は `tls internal` の行を消します。
- Collector は `.env` の `OTEL_INGEST_TOKEN` と一致する `Authorization: Bearer` だけを受け付けます。
- 動作確認用に、Collector の 4318 番をホスト自身（127.0.0.1）にだけ TLS なしで開けています。

## 起動手順

```bash
cd deploy
bash setup-env.sh d-clickhouse 192.168.1.10   # 案のディレクトリ名と、入口のホスト名か IP アドレス
cd d-clickhouse
docker compose up -d                          # d-duckdb はビルドがあるので初回は少し時間がかかる
docker compose ps
```

`setup-env.sh` は `.env.example` から `.env` を作り、トークンとパスワードをランダムな値で埋めます（権限は 600）。
もう一度実行しても設定済みの値は変えないので、SITE_ADDRESS だけ変えたいときも同じコマンドで済みます。

`.env` の中身は 3 つに分かれています。

| 区分 | 例 | 未設定のとき |
|---|---|---|
| 必須 | `OTEL_INGEST_TOKEN`、`GRAFANA_ADMIN_PASSWORD`、`CLICKHOUSE_PASSWORD`（案 D） | `docker compose` が「〜が未設定です」と表示して止まる |
| よく変えるもの | `SITE_ADDRESS` | `localhost` |
| 任意 | 保持期間、イメージのバージョンなど（`.env.example` にコメントで既定値） | `compose.yaml` の既定値 |

起動したら、ブラウザで次を開きます（`<SITE_ADDRESS>` は `.env` に書いた値。サーバー上で試すだけなら `SITE_ADDRESS=localhost` にして `https://localhost/...`）。

| URL | 中身 |
|---|---|
| `https://<SITE_ADDRESS>/docs/` | 資料一覧（説明スライド・手引き・端末の設定手順）。**まずここ** |
| `https://<SITE_ADDRESS>/` | Grafana（ユーザー `admin`、パスワードは `.env` の `GRAFANA_ADMIN_PASSWORD`。`grep '^GRAFANA_ADMIN_PASSWORD=' .env` で表示） |
| `https://<SITE_ADDRESS>/client/` | 利用者向けの `setup-client.sh`・`settings.json`・`caddy-root.crt` |

ブラウザにも Caddy のルート証明書（`https://<SITE_ADDRESS>/client/caddy-root.crt`）を信頼させてください。
ダッシュボード「Claude Code」フォルダの「Claude Code 利用状況」が自動で入ります。
Grafana は起動するたびに `admin` のパスワードを `.env` の `GRAFANA_ADMIN_PASSWORD` に合わせ直します（[`common/grafana/start.sh`](common/grafana/start.sh)）。
Grafana 自体はこの値を最初の起動時にしか使わないため、そのままでは `.env` を変えたり `setup-env.sh` をやり直したりした後にログインできなくなるからです。
パスワードを変えるときは `.env` を書き換えて `docker compose up -d --force-recreate grafana` を実行します（画面から変えても次の起動で戻ります）。
パスワードのためにボリュームを消す必要はありません（下の「Grafana を最初からやり直す」は、それでも直らないときだけ使います）。
`/docs/` と `/client/` は認証なしで見られます。置いているのはリポジトリの `docs/` と `common/client/`、CA のルート証明書だけで、トークンやパスワードは含みません。

同じホストで複数の案を同時に動かす場合は、443 番と 4318 番が重なるので `compose.yaml` の `ports` を変えてください。

WSL で Windows 側のディレクトリ（`/mnt/c/...`）から動かす場合、案 D′ は `data/` をバインドマウントして所有者を変えるため、
権限エラーになることがあります。その場合は WSL 側のディレクトリ（`~/...`）に clone してください。

### Grafana を最初からやり直す（Grafana のボリュームだけ消す）

Grafana の設定やユーザーは、コンテナでもイメージでもなく、ボリューム `grafana-data` の中の DB に入っています。
コンテナを作り直しても（`up --force-recreate`、`down` → `up`）、イメージを消しても、DB はそのまま残ります。
Grafana を初期の状態に戻したいときは、Grafana のボリュームだけを消します。

```bash
cd deploy/d-clickhouse                  # 使っている案のディレクトリ
docker compose stop grafana
docker compose rm -f grafana
docker volume ls | grep grafana-data    # 消すボリュームの名前を確かめる
docker volume rm claude-otel-clickhouse_grafana-data
docker compose up -d grafana            # .env の GRAFANA_ADMIN_PASSWORD で admin が作り直される
```

| 案 | ディレクトリ | Grafana のボリューム |
|---|---|---|
| B | `b-grafana` | `claude-otel-grafana_grafana-data` |
| D | `d-clickhouse` | `claude-otel-clickhouse_grafana-data` |
| D′ | `d-duckdb` | `claude-otel-duckdb_grafana-data` |

- 消えるもの：画面で作ったユーザー・チーム・権限、画面で作ったり編集したりしたダッシュボード、サービスアカウントとそのトークン、アラートなど画面で入れた設定。
- 残るもの：収集した利用データ、`.env`、リポジトリから入るダッシュボード「Claude Code 利用状況」とデータソース（起動時に入り直す）。
- D の ClickHouse プラグインは、起動時にもう一度ダウンロードされます（インターネットに出られる必要があります）。

**`docker compose down -v` は使わないでください。** その案のボリュームがすべて消えます。

| 案 | `down -v` で消えるもの |
|---|---|
| B | 収集データ（`prometheus-data`、`loki-data`）、`grafana-data`、`caddy-data` |
| D | 収集データ（`clickhouse-data`）、`grafana-data`、`caddy-data` |
| D′ | `grafana-data`、`caddy-data`（収集データの `data/` はディレクトリなので残る） |

`caddy-data` が消えると内部 CA が作り直されて証明書が変わり、全利用者に `caddy-root.crt` を配り直すことになります。

## クライアント（Claude Code）の設定

利用者の端末は [`common/client/setup-client.sh`](common/client/setup-client.sh) で設定できます（macOS / Linux）。
接続確認をしてから `~/.claude/settings.json` の `env` に書き足し、`--uninstall` で戻せます。使い方は
[`docs/admin-guide.md`](../docs/admin-guide.md#4-利用者を追加するオンボーディング) を参照してください。手で設定する場合は次のとおりです。

[`common/client/settings.json`](common/client/settings.json) の `env` を、利用者の `~/.claude/settings.json`（個人で試す場合）か
managed settings（組織で配る場合。macOS は `/Library/Application Support/ClaudeCode/managed-settings.json`）に入れます。
`OTEL_EXPORTER_OTLP_ENDPOINT` と Bearer トークンを書き換えてください。リポジトリの `.claude/settings.json` に書いた OTel の設定は無視されます。

### Caddy の内部 CA を信頼させる

`tls internal` の証明書は Caddy 独自の CA で署名されるので、Claude Code（Node.js）にそのルート証明書を渡します。

```bash
# 各端末で取る（Caddy が /client/caddy-root.crt で配っている。最初の 1 回だけ検証なし）
curl -fsSkO https://<SITE_ADDRESS>/client/caddy-root.crt
# サーバー上で取り出すこともできる
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

気になる場合は `openssl x509 -in caddy-root.crt -noout -fingerprint -sha256` の値をサーバー上のものと比べてください。
Claude Code を起動する環境で `NODE_EXTRA_CA_CERTS=/path/to/caddy-root.crt` を設定します
（シェルの環境変数か、settings.json の `env`）。

### すぐに試す（サーバー上で、TLS なし）

```bash
CLAUDE_CODE_ENABLE_TELEMETRY=1 OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp \
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <OTEL_INGEST_TOKEN>" \
claude -p "hello"
```

### クライアント設定についての注意（実測で確認したこと）

- **`OTEL_METRICS_INCLUDE_SESSION_ID` は既定（true）のままにします。** false にするとメトリクスだけでなく
  イベントからも `session.id` が消えます（Claude Code v2.1.296 で確認）。Prometheus の系列が増えないよう、
  案 B では Collector がメトリクスからだけ `session.id` を外します。
- **集計方式（temporality）は既定の delta のままにします。** 案 B は Collector の `delta_to_cumulative` で変換し、
  案 D・D′ は delta の値をそのまま合計します。
- Bash コマンドなどの詳細を記録するには `OTEL_LOG_TOOL_DETAILS=1` を足します（ダッシュボードの「実行された Bash コマンド」に出ます）。
  サーバーの閲覧権限とバックアップ先がその機密度に耐えるかを先に決めてください。

## 案ごとの注意

### B：Prometheus + Loki

- Prometheus は 2 つの実験的機能を有効にしています（`--enable-feature=created-timestamp-zero-ingestion,promql-extended-range-selectors`）。
  - 短いセッションはカウンターを 1 回しか送らないので、そのままでは `increase()` が値を返しません。開始時刻に 0 を入れて解決します。
  - `increase()` の外挿で値が膨らむため、ダッシュボードは外挿しない `increase(x[1h] anchored)` を使います。
    実測で、メトリクスのコストとイベントの `cost_usd` の合計が一致しました。
- Collector の `delta_to_cumulative` は状態をメモリに持つため、Collector は 1 台で動かします。再起動するとカウンターが
  リセットされたように見えますが、`increase()` はリセットを扱えます。
- Loki ではイベントの属性が structured metadata になり、LogQL では `event.name` → `event_name` のように `.` が `_` に置き換わります。

### D：ClickHouse

- Collector の clickhouse exporter は、起動時に ClickHouse へ接続できないと Collector ごと終了します。そのため ClickHouse の
  ヘルスチェック完了を待って起動します。
- Grafana の ClickHouse プラグインは初回起動時にダウンロードされます（`GF_PLUGINS_PREINSTALL_SYNC`）。そのときサーバーから
  インターネットに出られる必要があります。D′ の Dockerfile のビルド（DuckDB・otlp 拡張・Grafana プラグインの取得）も同様です。
- テーブル（`otel_logs`、`otel_metrics_sum` など）は exporter が作ります。TTL（`CLICKHOUSE_TTL`）はテーブル作成時にだけ反映されます。
- 分析 SQL の例：

```sql
-- 利用者 × 月のコスト
SELECT toStartOfMonth(Timestamp) AS month, LogAttributes['user.email'] AS user,
       round(sum(toFloat64OrZero(LogAttributes['cost_usd'])), 2) AS cost_usd
FROM otel.otel_logs WHERE LogAttributes['event.name'] = 'api_request'
GROUP BY month, user ORDER BY month, cost_usd DESC;
```

```bash
docker compose exec clickhouse clickhouse-client --user otel --password <CLICKHOUSE_PASSWORD> --database otel
```

### D′：DuckDB

```
collector ──file exporter──▶ data/raw/{logs,metrics}/*.jsonl（原本・監査用、RAW_RETENTION_DAYS で削除）
converter（CONVERT_INTERVAL_SECONDS ごと）──▶ data/parquet/{logs,metrics_sum}/event_date=YYYY-MM-DD/*.parquet
grafana（DuckDB プラグイン）──読み取り専用──▶ data/parquet
```

- ダッシュボードへの反映は変換の間隔（既定 300 秒）だけ遅れます。
- converter は inode と読み終えた位置で進捗を管理し（`data/state/offsets.json`）、書きかけの行は次回に回します。
  途中で落ちて同じ範囲を再処理しても、出力ファイル名が同じなので重複しません。前日以前のパーティションは 1 ファイルにまとめます。
- Parquet のスキーマ：
  - `logs`：`timestamp`、`event_name`、`user_email`、`session_id`、`prompt_id`、`body`、`log_attributes`（MAP）、`resource_attributes`（MAP）など
  - `metrics_sum`：`timestamp`、`metric_name`、`value`（delta）、`metric_attributes`（MAP）など
- Grafana のデータソースでは、テーブルマクロ `otel_logs()` と `otel_metrics_sum()` で Parquet を読みます。
- DuckDB プラグイン（MotherDuck 製）は署名されていないので、`GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS` で許可しています。
  glibc が必要なため、Grafana は Ubuntu 版のイメージを使います。
- ホストからは DuckDB で直接分析できます。

```sql
SELECT user_email, round(sum(TRY_CAST(log_attributes['cost_usd'] AS DOUBLE)), 2) AS cost_usd
FROM read_parquet('deploy/d-duckdb/data/parquet/logs/**/*.parquet', hive_partitioning = true)
WHERE event_name = 'api_request' GROUP BY ALL ORDER BY 2 DESC;
```

## 検証状況

この環境には Docker がないため、**`docker compose up` による起動は試していません**。代わりに、同じバージョンの各コンポーネントを
macOS 上で直接動かし、実際の Claude Code（v2.1.296）のテレメトリで次を確認しました。

| 対象 | 確認したこと |
|---|---|
| compose ファイル | 3 案とも `docker compose config` で構文を確認 |
| Collector 0.162.0 | 3 案の設定を `validate` で確認し、実データを受信。トークンなしの送信は 401 |
| Caddy 2.11.6 | `caddy validate`。内部 CA の HTTPS 経由で Claude Code から送信できた（`NODE_EXTRA_CA_CERTS`）。`/docs/`・`/client/`・`/client/caddy-root.crt`・Grafana への振り分けを macOS 上の Caddy で確認（`/docs/../` のような外への参照は 404）。落とした証明書でそのままサーバーを検証できた。`SITE_ADDRESS` が IP アドレスで、接続を受ける IP と違う（コンテナ内と同じ状況）とき、`default_sni` がないと SNI なしの接続が TLS で失敗し、入れると IP の名前で証明書を検証して 200 になることを確認 |
| B | Prometheus 3.15 と Loki 3.7.8 に実データを入れ、ダッシュボード 12 パネルのクエリを Grafana 13.2.3 経由で実行。2 セッション同時実行でもメトリクスとイベントのコストが一致 |
| D | ClickHouse にテーブルが自動作成され TTL が付くことを確認。12 パネルのクエリを Grafana 経由で実行 |
| D′ | DuckDB 1.5.6 の otlp 拡張で file exporter の出力を読み、converter で Parquet 化。書きかけ行・実際のローテーション（`logs-<時刻>-size.jsonl`）・統合・再実行で件数が一致。12 パネルのクエリを Grafana（DuckDB プラグイン 0.4.5）経由で実行 |
| `setup-client.sh` | macOS（bash 3.2）で、python3 と jq のどちらの経路でも同じ結果になることを確認。Collector 0.162.0 に対して接続確認が 200（正しいトークン）／401（違うトークン）を判定、既存キーの保持・再実行・`--uninstall`・壊れた JSON で止まること・既存の `NODE_EXTRA_CA_CERTS` を壊さないこと。自己署名証明書で TLS にした Collector に対し、スクリプトが書いた settings.json（`env` の `NODE_EXTRA_CA_CERTS`）だけで Claude Code v2.1.296 がメトリクスとイベントを送れた |
| Grafana の `start.sh` | Grafana 13.2.3 を macOS 上で、公式イメージの `/run.sh` と同じパス指定で動かして確認。`start.sh` なしで `.env` の値を変えて再起動すると新しい値でログインできない（401）ことを再現し、`start.sh` 経由では新しい値で入れて古い値は拒否される。初回起動・同じ値での再起動・記号を含む値・合わせ直しに失敗しても Grafana は起動すること・ログにパスワードが出ないこと |

未確認のこと：

- コンテナ固有の部分（ボリュームの権限、イメージ内のヘルスチェックコマンド、D′ の Dockerfile のビルド）
- D の ClickHouse を専用ユーザー（`CLICKHOUSE_USER=otel`）で使う場合。検証は `default` ユーザーで行った
- Grafana へのプラグインのダウンロード（D）
- コンテナ内での `start.sh`（entrypoint の差し替え。D′ の Ubuntu 版イメージを含む）
- `setup-client.sh` の Linux での実行と `--scope managed`（root が必要なため）。Caddy 経由での実行（TLS は Collector 自身で終端して試した）
