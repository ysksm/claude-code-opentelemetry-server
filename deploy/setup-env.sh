#!/usr/bin/env bash
# 各案の .env を作る。
#   ./setup-env.sh <b-grafana|d-clickhouse|d-duckdb> [SITE_ADDRESS]
#
# - .env が無ければ .env.example をコピーする。
# - 空か change-me の秘密情報（*_TOKEN / *_PASSWORD）をランダムな値で埋める。すでに値がある行は変えない。
# - SITE_ADDRESS を引数で渡すと書き換える。
# 何度実行しても、設定済みの値は上書きしない。
set -euo pipefail

usage() {
  echo "usage: $0 <b-grafana|d-clickhouse|d-duckdb> [SITE_ADDRESS]" >&2
  exit 1
}

[ $# -ge 1 ] || usage
cd "$(dirname "$0")"
dir=${1%/}
site=${2:-}
[ -f "$dir/.env.example" ] || { echo "$dir/.env.example がありません" >&2; usage; }

env_file="$dir/.env"
if [ ! -f "$env_file" ]; then
  cp "$dir/.env.example" "$env_file"
  echo "作成しました: $env_file"
fi
chmod 600 "$env_file"

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# KEY= の行（値が空か、旧版の example の change-me）を埋める。KEY= の行が無ければ末尾に足す。
set_if_empty() {
  local key=$1 value=$2
  if grep "^${key}=..*" "$env_file" | grep -qv "^${key}=change-me$"; then
    return 1
  fi
  local tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    $0 == k "=" || $0 == k "=change-me" { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$env_file" > "$tmp"
  cat "$tmp" > "$env_file"
  rm -f "$tmp"
}

# 値を書き換える（SITE_ADDRESS 用）
set_value() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$env_file" > "$tmp"
  cat "$tmp" > "$env_file"
  rm -f "$tmp"
}

for key in $(grep -oE '^[A-Z_]+_(TOKEN|PASSWORD)=' "$dir/.env.example" | tr -d '='); do
  if set_if_empty "$key" "$(random_secret)"; then
    echo "生成しました: $key"
  fi
done

if [ -n "$site" ]; then
  set_value SITE_ADDRESS "$site"
  echo "設定しました: SITE_ADDRESS=$site"
fi

get() { grep "^$1=" "$env_file" | tail -1 | cut -d= -f2-; }

cat <<EOF

次のコマンドで起動します:
  cd $dir && docker compose up -d

Grafana:          https://$(get SITE_ADDRESS)/  （admin / .env の GRAFANA_ADMIN_PASSWORD）
Claude Code 用:   OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer \$(grep ^OTEL_INGEST_TOKEN= $env_file | cut -d= -f2-)"
EOF
