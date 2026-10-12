# claude-code-opentelemetry-server

Claude Code の利用状況（コスト・トークン・ツール実行・Skill の利用など）を OpenTelemetry で集めるサーバーの構成です。

- [`docs/architecture.html`](docs/architecture.html)：構成案の検討資料（HTML スライド）
- [`docs/overview.md`](docs/overview.md)：利用者・導入判断者向けの説明（何を集め、誰が見るのか）
- [`docs/admin-guide.md`](docs/admin-guide.md)：管理画面（Grafana）の利用の手引きと運用
- [`docs/guide.html`](docs/guide.html)：上の 2 つをまとめた説明スライド（HTML）
- [`deploy/`](deploy/)：docker compose 一式
  - [`deploy/b-grafana/`](deploy/b-grafana/)：案 B（Prometheus + Loki + Grafana）
  - [`deploy/d-clickhouse/`](deploy/d-clickhouse/)：案 D（ClickHouse + Grafana）
  - [`deploy/d-duckdb/`](deploy/d-duckdb/)：案 D′（JSONL → DuckDB → Parquet + Grafana）
  - [`deploy/common/client/setup-client.sh`](deploy/common/client/setup-client.sh)：利用者の端末を設定するスクリプト（macOS / Linux）

起動手順とクライアント設定は [`deploy/README.md`](deploy/README.md) を参照してください。
