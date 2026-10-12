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
- Collector は `OTEL_INGEST_TOKEN` と一致する `Authorization: Bearer` だけを受け付けます。
- 動作確認用に、Collector の 4318 番をホスト自身（127.0.0.1）にだけ TLS なしで開けています。

## 起動手順

```bash
cd deploy/b-grafana          # または d-clickhouse / d-duckdb
cp .env.example .env
# .env を編集：SITE_ADDRESS、OTEL_INGEST_TOKEN（openssl rand -hex 32）、各パスワード
docker compose up -d         # d-duckdb はビルドがあるので初回は少し時間がかかる
docker compose ps
```

Grafana は `https://<SITE_ADDRESS>/` で開きます（ユーザー `admin`、パスワードは `GRAFANA_ADMIN_PASSWORD`）。
ブラウザにも Caddy のルート証明書（下記 `caddy-root.crt`）を信頼させてください。
ダッシュボード「Claude Code」フォルダの「Claude Code 利用状況」が自動で入ります。

同じホストで複数の案を同時に動かす場合は、443 番と 4318 番が重なるので `compose.yaml` の `ports` を変えてください。

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
# サーバーで取り出す
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

各端末に配り、Claude Code を起動する環境で `NODE_EXTRA_CA_CERTS=/path/to/caddy-root.crt` を設定します
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
| Caddy 2.11.6 | `caddy validate`。内部 CA の HTTPS 経由で Claude Code から送信できた（`NODE_EXTRA_CA_CERTS`） |
| B | Prometheus 3.15 と Loki 3.7.8 に実データを入れ、ダッシュボード 12 パネルのクエリを Grafana 13.2.3 経由で実行。2 セッション同時実行でもメトリクスとイベントのコストが一致 |
| D | ClickHouse にテーブルが自動作成され TTL が付くことを確認。12 パネルのクエリを Grafana 経由で実行 |
| D′ | DuckDB 1.5.6 の otlp 拡張で file exporter の出力を読み、converter で Parquet 化。書きかけ行・実際のローテーション（`logs-<時刻>-size.jsonl`）・統合・再実行で件数が一致。12 パネルのクエリを Grafana（DuckDB プラグイン 0.4.5）経由で実行 |
| `setup-client.sh` | macOS（bash 3.2）で、python3 と jq のどちらの経路でも同じ結果になることを確認。Collector 0.162.0 に対して接続確認が 200（正しいトークン）／401（違うトークン）を判定、既存キーの保持・再実行・`--uninstall`・壊れた JSON で止まること・既存の `NODE_EXTRA_CA_CERTS` を壊さないこと。自己署名証明書で TLS にした Collector に対し、スクリプトが書いた settings.json（`env` の `NODE_EXTRA_CA_CERTS`）だけで Claude Code v2.1.296 がメトリクスとイベントを送れた |

未確認のこと：

- コンテナ固有の部分（ボリュームの権限、イメージ内のヘルスチェックコマンド、D′ の Dockerfile のビルド）
- D の ClickHouse を専用ユーザー（`CLICKHOUSE_USER=otel`）で使う場合。検証は `default` ユーザーで行った
- Grafana へのプラグインのダウンロード（D）
- `setup-client.sh` の Linux での実行と `--scope managed`（root が必要なため）。Caddy 経由での実行（TLS は Collector 自身で終端して試した）
