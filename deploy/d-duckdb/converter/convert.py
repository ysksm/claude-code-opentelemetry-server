"""Collector の file exporter が書いた OTLP JSONL を、DuckDB で日付パーティションの Parquet に変換する。

- 生ファイルは消さない（監査用の原本。削除は Collector のローテーション設定 max_days に任せる）。
- 進捗は inode と読み終えたバイト位置で管理する。ローテーションでファイル名が変わっても inode は変わらない。
- 書き込み途中の行を読まないよう、最後の改行までだけを処理する。
- 出力ファイル名は (inode, 開始位置, 終了位置) で決まるので、途中で落ちて同じ範囲を再処理しても重複しない。
- Parquet は staging に書いてから rename で配置する（Grafana が書きかけのファイルを読まない）。
- 前日以前のパーティションは 1 ファイルにまとめる（小さいファイルが増えすぎないように）。
"""

import datetime as dt
import glob
import json
import logging
import os
import shutil
import signal
import time

import duckdb

RAW_DIR = os.environ.get("RAW_DIR", "/data/raw")
PARQUET_DIR = os.environ.get("PARQUET_DIR", "/data/parquet")
STATE_DIR = os.environ.get("STATE_DIR", "/data/state")
INTERVAL = int(os.environ.get("CONVERT_INTERVAL_SECONDS", "300"))
PARQUET_RETENTION_DAYS = int(os.environ.get("PARQUET_RETENTION_DAYS", "0"))  # 0 = 削除しない

STATE_FILE = os.path.join(STATE_DIR, "offsets.json")
STAGING_DIR = os.path.join(STATE_DIR, "staging")

# 出力テーブル名 → (生ファイルのディレクトリ, 変換 SQL)。{src} に読み込むファイルが入る。
TABLES = {
    "logs": (
        "logs",
        """
        WITH src AS (
            SELECT *,
                   CAST(CAST(log_attributes AS JSON) AS MAP(VARCHAR, VARCHAR)) AS attrs,
                   CAST(CAST(resource_attributes AS JSON) AS MAP(VARCHAR, VARCHAR)) AS res
            FROM read_otlp_logs('{src}')
        )
        SELECT CAST(time_unix_nano AS TIMESTAMP)          AS timestamp,
               CAST(observed_time_unix_nano AS TIMESTAMP) AS observed_timestamp,
               service_name,
               body,
               coalesce(attrs['event.name'], event_name)  AS event_name,
               attrs['user.email']                        AS user_email,
               attrs['session.id']                        AS session_id,
               attrs['prompt.id']                         AS prompt_id,
               severity_text,
               trace_id,
               span_id,
               scope_name,
               scope_version,
               attrs                                      AS log_attributes,
               res                                        AS resource_attributes,
               CAST(time_unix_nano AS DATE)               AS event_date
        FROM src
        """,
    ),
    "metrics_sum": (
        "metrics",
        """
        SELECT CAST(time_unix_nano AS TIMESTAMP)        AS timestamp,
               CAST(start_time_unix_nano AS TIMESTAMP)  AS start_timestamp,
               service_name,
               name                                     AS metric_name,
               unit,
               coalesce(double_value, CAST(int_value AS DOUBLE)) AS value,
               aggregation_temporality,
               is_monotonic,
               CAST(CAST(metric_attributes AS JSON) AS MAP(VARCHAR, VARCHAR))   AS metric_attributes,
               CAST(CAST(resource_attributes AS JSON) AS MAP(VARCHAR, VARCHAR)) AS resource_attributes,
               CAST(time_unix_nano AS DATE)             AS event_date
        FROM read_otlp_metrics_sum('{src}')
        """,
    ),
}

log = logging.getLogger("converter")
stopping = False


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)


def publish(staged_root, table):
    """staging に書いた Parquet を rename で本番ディレクトリに移す（同じファイルシステム内なので不可分）。"""
    for path in glob.glob(os.path.join(staged_root, "**", "*.parquet"), recursive=True):
        rel = os.path.relpath(path, staged_root)
        dest = os.path.join(PARQUET_DIR, table, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        os.replace(path, dest)
    shutil.rmtree(staged_root, ignore_errors=True)


def convert_chunk(con, table, sql, chunk_path, name):
    staged = os.path.join(STAGING_DIR, table, name)
    shutil.rmtree(staged, ignore_errors=True)
    os.makedirs(os.path.dirname(staged), exist_ok=True)
    con.execute(
        f"COPY ({sql.format(src=chunk_path)}) TO '{staged}' "
        f"(FORMAT parquet, COMPRESSION zstd, PARTITION_BY (event_date), FILENAME_PATTERN '{name}_{{i}}')"
    )
    publish(staged, table)


def process_table(con, state, table):
    subdir, sql = TABLES[table]
    files = sorted(glob.glob(os.path.join(RAW_DIR, subdir, "*.jsonl")))
    seen = set()
    for path in files:
        try:
            st = os.stat(path)
        except FileNotFoundError:
            continue  # ローテーションで消えた
        key = f"{table}:{st.st_ino}"
        seen.add(key)
        offset = state.get(key, 0)
        if st.st_size < offset:  # inode が再利用された
            offset = 0
        if st.st_size == offset:
            continue
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read(st.st_size - offset)
        end = data.rfind(b"\n")
        if end < 0:
            continue  # まだ 1 行も書き終わっていない
        data = data[: end + 1]
        name = f"{st.st_ino}_{offset}_{offset + len(data)}"
        chunk = os.path.join(STAGING_DIR, f"{table}_{name}.jsonl")
        with open(chunk, "wb") as f:
            f.write(data)
        try:
            convert_chunk(con, table, sql, chunk, name)
        finally:
            os.remove(chunk)
        state[key] = offset + len(data)
        save_state(state)
        log.info("%s: %s bytes %d-%d -> parquet", table, os.path.basename(path), offset, offset + len(data))
    # 消えたファイルの進捗は捨てる
    for key in [k for k in state if k.startswith(f"{table}:") and k not in seen]:
        del state[key]
    save_state(state)


def compact_and_expire(con, table):
    """前日以前のパーティションを 1 ファイルにまとめ、保持期間を過ぎたパーティションを消す。"""
    today = dt.datetime.now(dt.timezone.utc).date()
    for part in sorted(glob.glob(os.path.join(PARQUET_DIR, table, "event_date=*"))):
        day = dt.date.fromisoformat(part.rsplit("=", 1)[1])
        if PARQUET_RETENTION_DAYS and (today - day).days > PARQUET_RETENTION_DAYS:
            shutil.rmtree(part)
            log.info("%s: expired %s", table, day)
            continue
        files = sorted(glob.glob(os.path.join(part, "*.parquet")))
        if day >= today or len(files) <= 1:
            continue
        staged = os.path.join(STAGING_DIR, f"{table}_compact_{day}.parquet")
        file_list = ", ".join(f"'{p}'" for p in files)
        con.execute(
            f"COPY (SELECT * FROM read_parquet([{file_list}], union_by_name = true) ORDER BY timestamp) "
            f"TO '{staged}' (FORMAT parquet, COMPRESSION zstd)"
        )
        target = os.path.join(part, f"compacted_{day}.parquet")
        os.replace(staged, target)
        for p in files:
            if p != target:
                os.remove(p)
        log.info("%s: compacted %s (%d files)", table, day, len(files))


def run_once(con):
    state = load_state()
    for table in TABLES:
        process_table(con, state, table)
        compact_and_expire(con, table)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    os.umask(0o022)  # Grafana（別ユーザー）が読めるように
    for d in (STAGING_DIR, PARQUET_DIR):
        os.makedirs(d, exist_ok=True)

    def stop(*_):
        global stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    con = duckdb.connect()
    con.execute("LOAD otlp")
    once = os.environ.get("CONVERT_ONCE") == "1"
    while not stopping:
        try:
            run_once(con)
        except Exception:
            log.exception("conversion failed; will retry")
        if once:
            break
        for _ in range(INTERVAL):
            if stopping:
                break
            time.sleep(1)


if __name__ == "__main__":
    main()
