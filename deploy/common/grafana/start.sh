#!/bin/sh
# Grafana の起動前に、admin のパスワードを .env の GRAFANA_ADMIN_PASSWORD に合わせてから起動する（3 案共通）。
#
# Grafana は GF_SECURITY_ADMIN_PASSWORD を、データベース（ボリューム grafana-data）を初めて作るときにしか使わない。
# そのままでは、一度起動したあとに .env を変えても（setup-env.sh をやり直しても）ログインできなくなる。
# ここで毎回の起動時に合わせ直すので、.env の値が常に admin のパスワードになる。
# 画面から admin のパスワードを変えても、次の起動で .env の値に戻る（変えるときは .env を変えて再起動する）。
set -eu

db="${GF_PATHS_DATA:-/var/lib/grafana}/grafana.db"

if [ -z "${GF_SECURITY_ADMIN_PASSWORD:-}" ]; then
  echo "start.sh: GF_SECURITY_ADMIN_PASSWORD が空なので、admin のパスワードは合わせません" >&2
elif [ ! -f "$db" ]; then
  # 初回の起動。Grafana がデータベースを作るときに GF_SECURITY_ADMIN_PASSWORD で admin を作る
  echo "start.sh: 初回の起動です。admin は .env の GRAFANA_ADMIN_PASSWORD で作られます" >&2
else
  # パスは公式イメージの /run.sh がサーバーに渡すものと同じにする。
  # パスワードは引数に渡すとプロセス一覧に出るので、標準入力で渡す
  if out=$(printf '%s\n' "$GF_SECURITY_ADMIN_PASSWORD" \
    | grafana cli --homepath "${GF_PATHS_HOME:-/usr/share/grafana}" --config "${GF_PATHS_CONFIG:-/etc/grafana/grafana.ini}" \
        --configOverrides "cfg:default.paths.data=${GF_PATHS_DATA:-/var/lib/grafana}" \
        admin reset-admin-password --password-from-stdin 2>&1); then
    echo "start.sh: admin のパスワードを .env の GRAFANA_ADMIN_PASSWORD に合わせました" >&2
  else
    # 合わせられなくても Grafana は起動する（ダッシュボードが見られなくなるのを避ける）
    echo "start.sh: 警告: admin のパスワードを合わせられませんでした" >&2
    printf '%s\n' "$out" >&2
  fi
fi

# 公式イメージ（Alpine 版・Ubuntu 版とも）の本来の entrypoint
exec /run.sh "$@"
