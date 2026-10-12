# syntax=docker/dockerfile:1
# DuckDB プラグインは glibc 必須なので Ubuntu 版の Grafana を使う（既定の Alpine 版では動かない）。
ARG GRAFANA_VERSION=13.2.3
FROM python:3.13.15-slim AS plugin
ARG DUCKDB_PLUGIN_VERSION=0.4.5
RUN python - <<PY
import io, os, stat, urllib.request, zipfile
v = "${DUCKDB_PLUGIN_VERSION}"
url = f"https://github.com/motherduckdb/grafana-duckdb-datasource/releases/download/v{v}/motherduck-duckdb-datasource-{v}.zip"
zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(url).read())).extractall("/plugins")
d = "/plugins/motherduck-duckdb-datasource"
for f in os.listdir(d):
    if f.startswith("gpx_"):
        os.chmod(os.path.join(d, f), 0o755)
PY

FROM grafana/grafana:${GRAFANA_VERSION}-ubuntu
# プラグインは /var/lib/grafana（ボリューム）の外に置き、イメージ更新で入れ替わるようにする
ENV GF_PATHS_PLUGINS=/opt/grafana-plugins \
    GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=motherduck-duckdb-datasource
COPY --from=plugin --chown=472:0 /plugins /opt/grafana-plugins
