# claude-code-opentelemetry-server

Claude Code の利用状況（コスト・トークン・ツール実行・Skill の利用など）を OpenTelemetry で集めるサーバーの構成です。

- [`docs/architecture.html`](docs/architecture.html)：構成案の検討資料（HTML スライド）
- [`deploy/`](deploy/)：docker compose 一式
  - [`deploy/b-grafana/`](deploy/b-grafana/)：案 B（Prometheus + Loki + Grafana）
  - [`deploy/d-clickhouse/`](deploy/d-clickhouse/)：案 D（ClickHouse + Grafana）
  - [`deploy/d-duckdb/`](deploy/d-duckdb/)：案 D′（JSONL → DuckDB → Parquet + Grafana）

起動手順とクライアント設定は [`deploy/README.md`](deploy/README.md) を参照してください。
