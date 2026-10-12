#!/usr/bin/env bash
# Claude Code の利用状況を収集サーバーへ送るよう、利用者の端末を設定する（macOS / Linux）。
#
# settings.json の "env" に OTel の設定を書き足す（ほかのキーは変えない。書き換え前にバックアップを取る）。
# 内容は同じディレクトリの settings.json と同じで、エンドポイント・トークン・CA 証明書を埋める。
#
# 使い方:
#   OTEL_INGEST_TOKEN=<トークン> ./setup-client.sh --endpoint https://otel.example.internal --ca-cert ./caddy-root.crt
#   ./setup-client.sh --endpoint https://otel.example.internal          # トークンは対話で入力
#   ./setup-client.sh --check                                          # 接続確認だけ（設定済みの値を使う）
#   ./setup-client.sh --uninstall                                      # このスクリプトが書いたキーを消す
#   sudo ./setup-client.sh --scope managed ...                         # 組織配布（managed settings）に書く
#
# トークンはシェルの履歴に残らないよう、引数ではなく環境変数 OTEL_INGEST_TOKEN か対話入力で渡す。
set -euo pipefail

ENDPOINT="${OTEL_ENDPOINT:-}"
TOKEN="${OTEL_INGEST_TOKEN:-}"
CA_CERT=""
SCOPE="user"
TOOL_DETAILS=0
ATTRIBUTES=""
MODE="install"   # install | print | check | uninstall
SKIP_CHECK=0

# このスクリプトが管理するキー。設定し直すときは一度消してから入れ直し、--uninstall ではこれらだけを消す。
# NODE_EXTRA_CA_CERTS は社内プロキシなどで利用者が使っていることがあるので、ここには入れず、
# このスクリプトが置いた証明書を指しているときだけ消す。
MANAGED_KEYS=(
  CLAUDE_CODE_ENABLE_TELEMETRY OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER
  OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS
  OTEL_METRICS_INCLUDE_VERSION OTEL_METRICS_INCLUDE_REPOSITORY OTEL_LOG_TOOL_DETAILS
  OTEL_RESOURCE_ATTRIBUTES
)

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

オプション:
  --endpoint URL     収集サーバーの URL（例 https://otel.example.internal）。末尾に /v1/... は付けない
  --ca-cert PATH     サーバーの Caddy 内部 CA のルート証明書（caddy-root.crt）。公的な証明書なら不要
  --scope SCOPE      user（~/.claude/settings.json、既定）か managed（組織配布、root 権限が必要）
  --attributes K=V,...  部署などの属性を足す（OTEL_RESOURCE_ATTRIBUTES）。例 department=eng,team.id=platform
                     案 B で集計に使えるキーは department / team.id / cost_center / enduser.id（prometheus.yml）
  --tool-details     Bash コマンドなどツールの詳細も送る（OTEL_LOG_TOOL_DETAILS=1）。組織の方針を確認してから
  --print            書き込まずに、できあがる env を表示する（MDM で配る場合など）
  --check            接続確認だけ行う
  --no-check         設定後の接続確認を省く
  --uninstall        このスクリプトが書いたキーを settings.json から消す
  -h, --help         この説明
EOF
}

die() { echo "エラー: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT="${2:?--endpoint に値がありません}"; shift 2 ;;
    --ca-cert) CA_CERT="${2:?--ca-cert に値がありません}"; shift 2 ;;
    --scope) SCOPE="${2:?--scope に値がありません}"; shift 2 ;;
    --tool-details) TOOL_DETAILS=1; shift ;;
    --attributes) ATTRIBUTES="${2:?--attributes に値がありません}"; shift 2 ;;
    --print) MODE="print"; shift ;;
    --check) MODE="check"; shift ;;
    --no-check) SKIP_CHECK=1; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "不明なオプション: $1（--help を参照）" ;;
  esac
done

# --- 書き込み先 -------------------------------------------------------------
case "$SCOPE" in
  user)
    SETTINGS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    CA_DEST="$SETTINGS_DIR/otel/ca.crt"
    ;;
  managed)
    case "$(uname -s)" in
      Darwin) SETTINGS_DIR="/Library/Application Support/ClaudeCode" ;;
      Linux) SETTINGS_DIR="/etc/claude-code" ;;
      *) die "managed は macOS と Linux だけに対応しています" ;;
    esac
    SETTINGS_FILE="$SETTINGS_DIR/managed-settings.json"
    CA_DEST="$SETTINGS_DIR/otel-ca.crt"
    if [[ "$MODE" == "install" || "$MODE" == "uninstall" ]] && [[ $EUID -ne 0 ]]; then
      die "--scope managed は root 権限が必要です（sudo で実行してください）"
    fi
    ;;
  *) die "--scope は user か managed です" ;;
esac
CA_PREV="$CA_DEST.previous-path"

# --- JSON の読み書き（python3、なければ jq） -------------------------------
if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  JSON_TOOL="python3"
elif command -v jq >/dev/null 2>&1; then
  JSON_TOOL="jq"
else
  JSON_TOOL=""
fi

# 既存ファイルの env.<key> を取り出す（なければ空）
read_env() {
  local key="$1"
  [[ -f "$SETTINGS_FILE" ]] || return 0
  case "$JSON_TOOL" in
    python3) python3 - "$SETTINGS_FILE" "$key" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("env", {}).get(sys.argv[2], ""))
except Exception:
    pass
PY
    ;;
    jq) jq -r --arg k "$key" '.env[$k] // empty' "$SETTINGS_FILE" 2>/dev/null || true ;;
  esac
}

# write_settings merge '<JSON オブジェクト>' KEY...  … env から KEY... を消してから JSON をマージして書く
# write_settings remove KEY...             … env からそれらのキーを消す
write_settings() {
  local action="$1"; shift
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-settings.XXXXXX")"
  case "$JSON_TOOL" in
    python3) python3 - "$SETTINGS_FILE" "$tmp" "$action" "$@" <<'PY'
import json, os, sys
src, dst, action, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
data = {}
if os.path.exists(src) and os.path.getsize(src) > 0:
    with open(src) as f:
        data = json.load(f)  # 壊れた JSON なら止める（上書きしない）
if not isinstance(data, dict):
    sys.exit("settings.json の最上位がオブジェクトではありません")
env = data.get("env") or {}
add = json.loads(args.pop(0)) if action == "merge" else {}
for k in args:
    env.pop(k, None)
env.update(add)
if env:
    data["env"] = env
else:
    data.pop("env", None)
with open(dst, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    ;;
    jq)
      local base='{}'
      [[ -s "$SETTINGS_FILE" ]] && base="$(cat "$SETTINGS_FILE")"
      local add='{}'
      if [[ "$action" == "merge" ]]; then add="$1"; shift; fi
      jq --argjson add "$add" --args 'if type == "object" then . else error("not an object") end
        | .env = ((.env // {}) | with_entries(select(.key as $k | $ARGS.positional | index($k) | not))) + $add
        | if .env == {} then del(.env) else . end' "$@" <<<"$base" >"$tmp"
      ;;
  esac || { rm -f "$tmp"; die "$SETTINGS_FILE を更新できませんでした（JSON が壊れていないか確認してください）"; }

  mkdir -p "$SETTINGS_DIR"
  if [[ -f "$SETTINGS_FILE" ]]; then
    local backup
    backup="$SETTINGS_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$SETTINGS_FILE" "$backup"
    info "バックアップ: $backup"
  fi
  # トークンを含むので、本人（managed では root）以外が読めないようにする
  if [[ "$SCOPE" == "user" ]]; then chmod 600 "$tmp"; else chmod 644 "$tmp"; fi
  mv "$tmp" "$SETTINGS_FILE"
}

# --- 接続確認 ---------------------------------------------------------------
# 空の OTLP リクエストを送る。Collector はトークンが合えば 200、違えば 401 を返す。
check_connection() {
  local endpoint="$1" token="$2" ca="$3"
  command -v curl >/dev/null 2>&1 || { echo "  curl がないので接続確認を省きます"; return 0; }
  local args=(-sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST
    -H 'Content-Type: application/x-protobuf' --data-binary '' )
  [[ -n "$ca" ]] && args+=(--cacert "$ca")
  local code err errf
  errf="$(mktemp "${TMPDIR:-/tmp}/claude-otel-check.XXXXXX")"
  code="$(curl "${args[@]}" -H "Authorization: Bearer $token" "${endpoint%/}/v1/metrics" 2>"$errf")" || true
  err="$(head -n 1 "$errf")"; rm -f "$errf"
  case "$code" in
    200) info "接続確認 OK（${endpoint%/}/v1/metrics が 200 を返しました）" ;;
    401) die "トークンが違います（401）。管理者に OTEL_INGEST_TOKEN を確認してください" ;;
    000)
      case "$err" in
        *SSL*|*certificate*) die "証明書を検証できません: ${err}
  --ca-cert で caddy-root.crt を指定してください" ;;
        *) die "サーバーに接続できません: ${err}
  URL とネットワーク（443 番に届くか）を確認してください" ;;
      esac ;;
    *) die "想定外の応答です（HTTP ${code}）。URL が収集サーバーを指しているか確認してください" ;;
  esac
}

# --- 各モード ---------------------------------------------------------------
if [[ "$MODE" == "uninstall" ]]; then
  [[ -f "$SETTINGS_FILE" ]] || { info "$SETTINGS_FILE がないので何もしません"; exit 0; }
  [[ -n "$JSON_TOOL" ]] || die "python3 か jq が必要です"
  remove=("${MANAGED_KEYS[@]}")
  if [[ "$(read_env NODE_EXTRA_CA_CERTS)" == "$CA_DEST" ]]; then
    if [[ -s "$CA_PREV" ]]; then
      # 設定前に利用者が使っていた証明書に戻す
      write_settings merge "{\"NODE_EXTRA_CA_CERTS\": \"$(<"$CA_PREV")\"}" "${remove[@]}"
      info "NODE_EXTRA_CA_CERTS を元の $(<"$CA_PREV") に戻しました"
    else
      write_settings remove "${remove[@]}" NODE_EXTRA_CA_CERTS
    fi
  else
    write_settings remove "${remove[@]}"
  fi
  rm -f "$CA_PREV"
  [[ -f "$CA_DEST" ]] && rm -f "$CA_DEST" && info "削除: $CA_DEST"
  info "$SETTINGS_FILE から OTel の設定を消しました。次に起動する Claude Code から送信が止まります"
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  [[ -n "$JSON_TOOL" ]] || die "python3 か jq が必要です"
  ENDPOINT="${ENDPOINT:-$(read_env OTEL_EXPORTER_OTLP_ENDPOINT)}"
  [[ -n "$ENDPOINT" ]] || die "エンドポイントが分かりません（--endpoint で指定してください）"
  header="$(read_env OTEL_EXPORTER_OTLP_HEADERS)"
  TOKEN="${TOKEN:-${header#Authorization=Bearer }}"
  [[ -n "$TOKEN" ]] || die "トークンが分かりません（環境変数 OTEL_INGEST_TOKEN で渡してください）"
  CA_CERT="${CA_CERT:-$(read_env NODE_EXTRA_CA_CERTS)}"
  check_connection "$ENDPOINT" "$TOKEN" "$CA_CERT"
  exit 0
fi

# install / print
if [[ -z "$ENDPOINT" ]]; then
  [[ -t 0 ]] || die "--endpoint を指定してください"
  read -r -p "収集サーバーの URL（例 https://otel.example.internal）: " ENDPOINT
fi
ENDPOINT="${ENDPOINT%/}"
[[ "$ENDPOINT" =~ ^https?://[^/]+$ ]] || die "URL は https://ホスト名[:ポート] の形で、パスは付けません: $ENDPOINT"
[[ "$ENDPOINT" == http://* ]] && echo "注意: http:// ではトークンと内容が暗号化されずに送られます" >&2

if [[ -z "$TOKEN" && "$MODE" == "install" ]]; then
  [[ -t 0 ]] || die "環境変数 OTEL_INGEST_TOKEN でトークンを渡してください"
  read -r -s -p "トークン（OTEL_INGEST_TOKEN、入力は表示されません）: " TOKEN; echo
fi
[[ "$MODE" == "print" ]] || [[ -n "$TOKEN" && "$TOKEN" != *[[:space:]]* ]] || die "トークンが空か、空白を含んでいます"

CA_VALUE=""
if [[ -n "$CA_CERT" ]]; then
  [[ -f "$CA_CERT" ]] || die "証明書が見つかりません: $CA_CERT"
  grep -q 'BEGIN CERTIFICATE' "$CA_CERT" || die "PEM 形式の証明書ではありません: $CA_CERT"
  CA_VALUE="$CA_DEST"
  if [[ "$MODE" == "install" && -n "$JSON_TOOL" ]]; then
    current_ca="$(read_env NODE_EXTRA_CA_CERTS)"
    # つなげた証明書（元の証明書を含む）が渡されたときは先へ進む
    if [[ -n "$current_ca" && "$current_ca" != "$CA_DEST" ]] \
      && ! { [[ -s "$current_ca" ]] && [[ "$(cat "$CA_CERT")" == *"$(cat "$current_ca")"* ]]; }; then
      die "settings.json の NODE_EXTRA_CA_CERTS はすでに $current_ca を指しています。
  上書きするとそちらの用途（社内プロキシなど）が使えなくなるので止めました。
  2 つの証明書を 1 つのファイルにつなげ（cat $current_ca $CA_CERT > 新しいファイル）、それを --ca-cert に指定してください"
    fi
  fi
fi

if [[ -n "$ATTRIBUTES" ]]; then
  [[ "$ATTRIBUTES" =~ ^[A-Za-z0-9_.-]+=[^,=[:space:]]+(,[A-Za-z0-9_.-]+=[^,=[:space:]]+)*$ ]] \
    || die "--attributes は key=value をカンマでつなぎ、空白を含めない形です: $ATTRIBUTES"
fi

if [[ $TOOL_DETAILS -eq 1 ]]; then
  cat >&2 <<'EOF'
注意: --tool-details を付けると、実行した Bash コマンドの全文などがサーバーに保存されます。
      コマンドに秘密情報（パスワード・トークン）が含まれることがあります。組織の方針に沿っているか確認してください。
EOF
fi

# 入れる env。deploy/common/client/settings.json と同じ（session.id と temporality は既定のまま。deploy/README.md 参照）
env_json() {
  local pairs=(
    CLAUDE_CODE_ENABLE_TELEMETRY 1
    OTEL_METRICS_EXPORTER otlp
    OTEL_LOGS_EXPORTER otlp
    OTEL_EXPORTER_OTLP_PROTOCOL http/protobuf
    OTEL_EXPORTER_OTLP_ENDPOINT "$ENDPOINT"
    OTEL_EXPORTER_OTLP_HEADERS "Authorization=Bearer $1"
    OTEL_METRICS_INCLUDE_VERSION true
    OTEL_METRICS_INCLUDE_REPOSITORY true
  )
  [[ $TOOL_DETAILS -eq 1 ]] && pairs+=(OTEL_LOG_TOOL_DETAILS 1)
  [[ -n "$ATTRIBUTES" ]] && pairs+=(OTEL_RESOURCE_ATTRIBUTES "$ATTRIBUTES")
  [[ -n "$CA_VALUE" ]] && pairs+=(NODE_EXTRA_CA_CERTS "$CA_VALUE")
  local out="{" sep="" i v
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    v="${pairs[i+1]//\\/\\\\}"; v="${v//\"/\\\"}"
    out+="$sep"$'\n'"  \"${pairs[i]}\": \"$v\""; sep=","
  done
  echo "$out"$'\n'"}"
}

if [[ "$MODE" == "print" ]]; then
  # 画面に出すのでトークンは伏せる
  echo "{ \"env\": $(env_json "REPLACE_WITH_OTEL_INGEST_TOKEN") }"
  [[ -n "$CA_VALUE" ]] && echo "（証明書 $CA_CERT を $CA_VALUE に置いてください）" >&2
  exit 0
fi

[[ -n "$JSON_TOOL" ]] || die "python3 か jq が必要です（--print で表示した内容を手で settings.json に入れることもできます）"

if [[ $SKIP_CHECK -eq 0 ]]; then
  check_connection "$ENDPOINT" "$TOKEN" "$CA_CERT"
fi

if [[ -n "$CA_VALUE" ]]; then
  mkdir -p "$(dirname "$CA_DEST")"
  # 利用者がもともと別の証明書を指定していたら、--uninstall で戻せるよう控えておく
  if [[ -n "${current_ca:-}" && "$current_ca" != "$CA_DEST" ]]; then
    printf '%s' "$current_ca" >"$CA_PREV"
  fi
  cp "$CA_CERT" "$CA_DEST"
  chmod 644 "$CA_DEST"
  info "証明書を配置: $CA_DEST"
fi

write_settings merge "$(env_json "$TOKEN")" "${MANAGED_KEYS[@]}"
info "書き込み: $SETTINGS_FILE"
cat <<EOF

設定しました。次に起動する Claude Code から送信が始まります（起動中のものは再起動してください）。
  - 送られる内容: コスト・トークン数・セッション数・ツール実行の結果・Skill の利用など
  - 送られない内容: プロンプトの本文、コードやファイルの中身$([[ $TOOL_DETAILS -eq 1 ]] || echo "、Bash コマンドの全文")
  - 止めるとき: $0 --uninstall
EOF
if [[ "$SCOPE" == "user" ]]; then
  echo "  - 確認: 管理者に Grafana の「利用者別コスト」に自分のメールアドレスが出たか見てもらう（D′ は最大 5 分遅れます）"
fi
