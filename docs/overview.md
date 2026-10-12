# Claude Code 利用状況の収集について

Claude Code を使う人と、導入を判断する人向けの説明です。何を・なぜ・どこに集めるのか、誰が見るのか、
自分の端末をどう設定するのかをまとめています。
スライド版は [`overview.html`](overview.html) です。
運用者向けの手引きは [`admin-guide.md`](admin-guide.md)、構成案の比較は [`architecture.html`](architecture.html) を参照してください。

## 何のために集めるのか

- **費用を把握する**：誰が・どのリポジトリで・どのモデルにいくら使っているか（概算）を、請求を待たずに日単位で見ます。
- **使い方を知って広げる**：よく使われている Skill やツール、うまくいっていない操作（失敗の多いツール）を見つけ、
  手順書や Skill の整備に生かします。
- **監査に備える**（組織で有効にした場合だけ）：Claude Code が実行した Bash コマンドの記録を残します。

個人の評価に使うことは目的にしていません。運用の方針（誰が見るか、何に使うか）は導入する組織で決め、利用者に知らせてください。

## 仕組み

```
Claude Code ──HTTPS + トークン──▶ Caddy ──▶ Collector ──▶ 保存先 ──▶ Grafana（管理画面）
```

左端の Claude Code があなたの端末、Caddy から右が社内の収集サーバーです。

- Claude Code には OpenTelemetry（OTel）でテレメトリを送る機能が組み込まれています。設定で有効にすると、
  使っている間、数値（メトリクス）は 1 分ごと、出来事（イベント）は数秒ごとにまとめて社内の収集サーバーへ送ります。
- 送り先は社内のサーバーだけです。通信は HTTPS で暗号化され、共通のトークンを持つ端末からしか受け付けません。
- 送信に失敗しても Claude Code の動作は止まりません（その分のデータが欠けるだけです）。

## 何が送られるのか

### 送られるもの

| 種類 | 内容 |
|---|---|
| 利用者 | メールアドレス（`user.email`）、アカウントと組織の ID、セッション ID |
| 環境 | Claude Code のバージョン、OS・端末の種類、作業中の Git リポジトリ名（`vcs.repository.name`） |
| メトリクス（数値） | コスト（概算 USD）、トークン数（入力・出力・キャッシュ）、セッション数、変更した行数、コミット・プルリクエストの数、操作時間など |
| イベント（出来事） | API の呼び出し（モデル・トークン数・コスト・所要時間）、ツールの実行結果（ツール名・成否・所要時間）、ツールの許可・拒否、Skill の起動、エラー、プロンプトを送ったこと（**長さだけ**） |
| 部署など（任意） | 設定で付けた場合だけ：`department`、`team.id`、`cost_center` など |

### 送られないもの（既定）

- **プロンプトの本文**（何を頼んだか）。長さだけが送られます。
- **コードやファイルの中身**、Claude の応答の本文。
- **Bash コマンドの全文などツールの詳細**。

### 組織が有効にした場合だけ送られるもの

| 設定 | 送られるもの | 注意 |
|---|---|---|
| `OTEL_LOG_TOOL_DETAILS=1`（スクリプトの `--tool-details`） | 実行された Bash コマンドの全文、ツールの引数 | コマンドにパスワードやトークンが含まれていると、それも保存されます |

このリポジトリの構成では、プロンプトの本文を送る設定（`OTEL_LOG_USER_PROMPTS`）は使いません。

## 誰が見るのか

- 管理画面（Grafana）はアカウントを作られた人だけが見られます。利用者が自分でアカウントを作ることはできません。
- 見られる内容は、利用者別・リポジトリ別のコスト、ツール・Skill の利用回数など（[管理画面の手引き](admin-guide.md#2-ダッシュボードの見方)）。
- どの役割の人にアカウントを渡すかは、導入する組織が決めて利用者に知らせます。

## どのくらい保存するのか

| 案 | 既定の保存期間 |
|---|---|
| B（Prometheus + Loki） | 数値 400 日、イベント 90 日 |
| D（ClickHouse） | 2 年 |
| D′（DuckDB） | 原本 400 日、分析用（Parquet）は削除しない |

組織の方針に合わせて変えられます（運用者が `.env` で設定）。

## 自分の端末を設定する（macOS / Linux）

サーバーのアドレス（`<SITE_ADDRESS>`、例 `otel.example.internal`）とトークンを管理者から受け取ります。
設定スクリプトと証明書は `https://<SITE_ADDRESS>/client/` から落とせます（資料一覧は `https://<SITE_ADDRESS>/docs/`）。

```bash
curl -fsSkO https://otel.example.internal/client/caddy-root.crt   # 最初の 1 回だけ検証なし
curl -fsSO --cacert caddy-root.crt https://otel.example.internal/client/setup-client.sh
chmod +x setup-client.sh
OTEL_INGEST_TOKEN=<受け取ったトークン> ./setup-client.sh \
  --endpoint https://otel.example.internal --ca-cert ./caddy-root.crt
```

スクリプトがすること：

1. サーバーにつながるか、トークンと証明書が正しいかを確かめる（だめなら何も書き換えずに止まる）。
2. 証明書を `~/.claude/otel/ca.crt` に置く。
3. `~/.claude/settings.json` の `env` に送信の設定を書き足す。ほかの設定は変えず、書き換え前に `settings.json.bak.<日時>` を作る。
   トークンが入るので、ファイルは本人だけが読める権限（600）にする。

設定のあとに起動した Claude Code から送信が始まります。起動中のものは再起動してください。

| やりたいこと | コマンド |
|---|---|
| 設定する内容を確かめる（書き換えない） | `./setup-client.sh --print --endpoint https://...` |
| つながるか確かめる | `./setup-client.sh --check` |
| 送信を止める（設定を消す） | `./setup-client.sh --uninstall` |
| 部署を付ける | `--attributes department=eng,team.id=platform` を足す |

組織が managed settings で配っている場合は、すでに設定されています。その場合、利用者が自分で外すことはできません。

Windows には、いまのところスクリプトがありません。[`settings.json`](../deploy/common/client/settings.json)（`https://<SITE_ADDRESS>/client/settings.json`）の `env` を
`%USERPROFILE%\.claude\settings.json` に手で入れ、`NODE_EXTRA_CA_CERTS` に証明書のパスを足してください。

## よくある質問

**Q. 送信すると Claude Code が遅くなりませんか？**
まとめて非同期に送るので、操作への影響はほとんどありません。

**Q. 社外のネットワークにいるときは？**
収集サーバーに届かない間は送信に失敗し、その分のデータは残りません。Claude Code はそのまま使えます。

**Q. ダッシュボードのコストは請求額ですか？**
いいえ。Claude Code がトークン数から計算した概算です。サブスクリプションで使っている場合も、従量課金に換算した値が出ます。

**Q. 自分のデータを見たいです。**
管理者に依頼してください。閲覧用のアカウントを作るか、該当部分を CSV で渡せます。

**Q. リポジトリの `.claude/settings.json` に書いてもよいですか？**
OTel の設定はリポジトリ側の設定では無効です。個人の `~/.claude/settings.json` か managed settings に入れてください。
