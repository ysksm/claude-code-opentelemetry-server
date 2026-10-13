#!/usr/bin/env bash
# サーバーへの接続を、内側から 1 段ずつ確かめる（切り分け用）。サーバー（docker compose を動かしているマシン）で実行する。
#   ./check.sh <b-grafana|d-clickhouse|d-duckdb>
#
#   1. Docker      コンテナがすべて動いているか
#   2. Collector   TLS なしの 127.0.0.1:4318 にトークン付きで送れるか（Caddy を通さない）
#   3. Caddy       サーバー自身から HTTPS で /docs/ を開けるか（証明書も検証する）
#   4. 送り先      HTTPS の /v1/metrics にトークン付きで送れるか（Claude Code と同じ経路）
#   5. Grafana     admin / .env の GRAFANA_ADMIN_PASSWORD でログインできるか
#   6. アドレス    SITE_ADDRESS で実際にこのサーバーに届くか（WSL・ファイアウォール）
# 1〜5 は NG になったところで止まる（その先は前の段が動いていないと確かめられない）。
# 最後に、ほかの端末から確かめる手順を表示する。
set -uo pipefail

usage() {
  echo "usage: $0 <b-grafana|d-clickhouse|d-duckdb>" >&2
  exit 2
}

[ $# -ge 1 ] || usage
cd "$(dirname "$0")"
dir=${1%/}
[ -f "$dir/compose.yaml" ] || { echo "$dir/compose.yaml がありません" >&2; usage; }
env_file="$dir/.env"
[ -f "$env_file" ] || { echo "$env_file がありません。先に ./setup-env.sh $dir を実行してください" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl が必要です" >&2; exit 2; }

get() { grep "^$1=" "$env_file" | tail -1 | cut -d= -f2- | tr -d '\r'; }
site=$(get SITE_ADDRESS); site=${site:-localhost}
token=$(get OTEL_INGEST_TOKEN)
grafana_password=$(get GRAFANA_ADMIN_PASSWORD)

is_wsl=0
grep -qi microsoft /proc/version 2>/dev/null && is_wsl=1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok() { printf '  \033[32mOK\033[0m  %s\n' "$1"; }
ng() {
  printf '  \033[31mNG\033[0m  %s\n' "$1"
  shift
  for line in "$@"; do printf '      → %s\n' "$line"; done
}
step() { printf '\n[%s] %s\n' "$1" "$2"; }
stop() {
  printf '\nここで止めます。上の → を直してから、もう一度 ./check.sh %s を実行してください。\n' "$dir"
  exit 1
}

# curl の終了コードを、分かる言葉にする
curl_reason() {
  case $1 in
    6) echo "名前を引けない（${site}）" ;;
    7) echo "つながらない（ポートが開いていない／コンテナが動いていない）" ;;
    28) echo "時間切れ（ファイアウォールなどで止められている）" ;;
    35) echo "TLS のやりとりに失敗（証明書を出せていない）" ;;
    51 | 60) echo "証明書を検証できない（名前が違う／CA が違う）" ;;
    *) echo "curl の終了コード $1" ;;
  esac
}

# 空の OTLP を送る。HTTP コードを出力し、curl の終了コードを返す
post_otlp() {
  local url=$1
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
    -H 'Content-Type: application/x-protobuf' --data-binary '' "$@" "$url"
}

compose() { (cd "$dir" && docker compose "$@"); }

echo "案: $dir / SITE_ADDRESS: $site$([ $is_wsl = 1 ] && echo ' / WSL 上で実行')"

# ---- 1. Docker ----
step 1/6 "Docker：コンテナが動いているか"
if ! command -v docker >/dev/null 2>&1; then
  ng "docker コマンドがありません" "Docker をインストールする（WSL なら Docker Desktop の WSL 連携を有効にする）"
  stop
fi
if ! ps_out=$(compose ps --all --format '{{.Service}}	{{.State}}	{{.Status}}' 2>"$tmp/err"); then
  ng "docker compose ps が失敗しました: $(head -1 "$tmp/err")" \
    "Docker が起動しているか（WSL なら Docker Desktop が起動しているか）" \
    "このユーザーで docker を使えるか（docker ps を試す）"
  stop
fi
services=$(compose config --services 2>/dev/null)
bad=0
for s in $services; do
  line=$(printf '%s\n' "$ps_out" | awk -F'\t' -v s="$s" '$1 == s')
  state=$(printf '%s' "$line" | cut -f2)
  status=$(printf '%s' "$line" | cut -f3)
  if [ -z "$line" ]; then
    ng "$s: コンテナがありません" "cd $dir && docker compose up -d"
    bad=1
  elif [ "$state" = exited ] && printf '%s' "$status" | grep -q '^Exited (0)'; then
    ok "$s: 完了（起動時に 1 回だけ動くもの）"
  elif [ "$state" != running ]; then
    ng "$s: $status" "docker compose logs $s で止まった理由を見る" "直したら cd $dir && docker compose up -d"
    bad=1
  elif printf '%s' "$status" | grep -q unhealthy; then
    ng "$s: $status" "docker compose logs $s で理由を見る"
    bad=1
  elif printf '%s' "$status" | grep -q 'health: starting'; then
    ng "$s: 起動中（${status}）" "1〜2 分待ってから、もう一度実行する"
    bad=1
  else
    ok "$s: $status"
  fi
done
[ $bad = 0 ] || stop

# ---- 2. Collector（Caddy を通さない） ----
step 2/6 "Collector：127.0.0.1:4318 に TLS なしで送れるか（Caddy を通さない）"
code=$(post_otlp http://127.0.0.1:4318/v1/metrics -H "Authorization: Bearer $token"); rc=$?
if [ $rc != 0 ]; then
  ng "送れません：$(curl_reason $rc)" "docker compose logs collector を見る" "compose.yaml の collector に 127.0.0.1:4318:4318 があるか"
  stop
elif [ "$code" = 401 ]; then
  ng "401（トークンが違う）" ".env の OTEL_INGEST_TOKEN を変えたあと、collector を作り直していない → cd $dir && docker compose up -d --force-recreate collector"
  stop
elif [ "$code" != 200 ]; then
  ng "HTTP $code" "docker compose logs collector を見る"
  stop
fi
ok "200（Collector とトークンは正常）"

# ---- 3. Caddy（サーバー自身から HTTPS） ----
step 3/6 "Caddy：サーバー自身から HTTPS で開けるか"
port=$(compose port caddy 443 2>/dev/null | tail -1 | sed 's/.*://')
port=${port:-443}
if ! compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt >"$tmp/ca.crt" 2>/dev/null || [ ! -s "$tmp/ca.crt" ]; then
  ng "Caddy のルート証明書を取り出せません" "docker compose logs caddy を見る（証明書を作れていない）"
  stop
fi
url_base="https://$site$([ "$port" = 443 ] || echo ":$port")"
# 接続先だけ 127.0.0.1 に向け、名前は SITE_ADDRESS のまま（ほかの端末と同じ条件で証明書を検証する）
resolve=(--resolve "$site:$port:127.0.0.1")
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$tmp/ca.crt" "${resolve[@]}" "$url_base/docs/"); rc=$?
if [ $rc != 0 ]; then
  case $rc in
    7) ng "つながりません（127.0.0.1:${port}）" "docker compose logs caddy を見る" "compose.yaml の caddy の ports（443:443）がほかのソフトとぶつかっていないか" ;;
    35) ng "TLS のやりとりに失敗しました" "Caddyfile に default_sni があるか（SITE_ADDRESS が IP アドレスのときに必要）。git pull して docker compose up -d --force-recreate caddy" "docker compose logs caddy を見る" ;;
    51 | 60) ng "証明書を検証できません" "SITE_ADDRESS を変えたあと caddy を作り直していない → docker compose up -d --force-recreate caddy" ;;
    *) ng "開けません：$(curl_reason $rc)" "docker compose logs caddy を見る" ;;
  esac
  stop
elif [ "$code" != 200 ]; then
  ng "/docs/ が HTTP $code" "docker compose logs caddy を見る"
  stop
fi
ok "$url_base/docs/ が 200（Caddy と証明書は正常）"

# ---- 4. 送り先（Caddy 経由の OTLP） ----
step 4/6 "送り先：HTTPS の /v1/metrics に送れるか（Claude Code と同じ経路）"
code=$(post_otlp "$url_base/v1/metrics" --cacert "$tmp/ca.crt" "${resolve[@]}" -H "Authorization: Bearer $token"); rc=$?
if [ $rc != 0 ] || [ "$code" != 200 ]; then
  ng "HTTP $code$([ $rc != 0 ] && echo "（$(curl_reason $rc)）")" "Caddyfile の /v1/* の振り分けと docker compose logs caddy を見る"
  stop
fi
ok "200"

# ---- 5. Grafana ----
step 5/6 "Grafana：admin でログインできるか"
# 何度も失敗するとロックされるので 1 回だけ試す
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$tmp/ca.crt" "${resolve[@]}" \
  -u "admin:$grafana_password" "$url_base/api/org"); rc=$?
if [ $rc != 0 ]; then
  ng "開けません：$(curl_reason $rc)" "docker compose logs grafana を見る"
  stop
elif [ "$code" = 401 ]; then
  ng "401（パスワードが合わない）" \
    "docker compose logs grafana | grep start.sh に「合わせました」が出ているか" \
    "出ていなければ git pull して docker compose up -d --force-recreate grafana" \
    "それでもだめなら README の「Grafana を最初からやり直す」"
  stop
elif [ "$code" = 502 ] || [ "$code" = 503 ]; then
  ng "HTTP ${code}（Grafana が応答しない）" "docker compose logs grafana を見る。起動直後なら 1〜2 分待つ"
  stop
elif [ "$code" != 200 ]; then
  ng "HTTP $code" "docker compose logs grafana を見る"
  stop
fi
ok "200（ユーザー admin、パスワードは .env の GRAFANA_ADMIN_PASSWORD）"

# ---- 6. 実際のアドレス ----
step 6/6 "アドレス：$site で、このサーバーに届くか"
if [ "$site" = localhost ]; then
  ok "SITE_ADDRESS が localhost なので、このマシンからだけ使えます"
  cat <<EOF

ほかの端末から使うには、SITE_ADDRESS をこのサーバーの IP アドレスかホスト名にして caddy を作り直し、
もう一度確かめてください:
  ./setup-env.sh ${dir} <IP アドレス>
  (cd ${dir} && docker compose up -d --force-recreate caddy)
  ./check.sh ${dir}
EOF
  exit 0
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$tmp/ca.crt" "$url_base/docs/"); rc=$?
  if [ $rc = 0 ] && [ "$code" = 200 ]; then
    ok "$url_base/docs/ が 200"
    reach=ok
  else
    ng "$url_base/docs/ に届きません：$(curl_reason $rc)" \
      "$site がこのサーバー（WSL なら Windows）の IP アドレスか（ip addr、Windows なら ipconfig）"
    [ $is_wsl = 1 ] && printf '      → %s\n' \
      "WSL では、Windows の ${port} 番を WSL に転送する設定が要ることがあります（下の手順 A）"
    reach=ng
  fi
fi

# ---- ほかの端末から ----
cat <<EOF

────────────────────────────────────────
サーバー側はここまで確かめました。続けて、ほかの端末から確かめます。
EOF
if [ $is_wsl = 1 ]; then
  cat <<EOF

手順 A（WSL のとき。Windows 側で）
  1. Windows のブラウザで https://localhost$([ "$port" = 443 ] || echo ":$port")/docs/ を開く
     → 開けない：Docker と WSL の間の問題。Docker Desktop の WSL 連携を確かめる
  2. ほかの PC の PowerShell で:  Test-NetConnection $site -Port $port
     → TcpTestSucceeded が False：Windows で ${port} 番を通していない。管理者の PowerShell で
         New-NetFirewallRule -DisplayName "claude-otel https" -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow
       WSL の中に直接 Docker を入れている（Docker Desktop でない）場合は、転送も要ります:
         netsh interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 connectport=$port connectaddress=<WSL の IP（wsl hostname -I）>
EOF
fi
wsl_hint=
[ $is_wsl = 1 ] && wsl_hint='、上の手順 A'
cat <<EOF

手順 B（ほかの端末で）
  1. ブラウザで $url_base/docs/ を開く
     → 証明書の警告が出る：つながってはいる。$url_base/client/caddy-root.crt を OS の信頼ストアに入れる
     → つながらない：ネットワークの問題（VPN、ファイアウォール${wsl_hint}）
  2. ブラウザで $url_base/ を開き、admin / .env の GRAFANA_ADMIN_PASSWORD でログイン
     （表示：grep '^GRAFANA_ADMIN_PASSWORD=' ${env_file}）
  3. Claude Code を使う端末で、資料一覧（/docs/）の「端末を設定する」の手順に従い setup-client.sh を実行する
     （最後に接続確認をする。単独なら ./setup-client.sh --check）
EOF
[ "${reach:-}" = ng ] && exit 1
exit 0
