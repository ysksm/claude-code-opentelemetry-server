FROM python:3.13.15-slim

ARG DUCKDB_VERSION=1.5.6
# otlp 拡張はコミュニティ拡張。ビルド時に入れておき、実行時はネットワークに出ない。
RUN pip install --no-cache-dir "duckdb==${DUCKDB_VERSION}" \
 && python -c "import duckdb; duckdb.sql('INSTALL otlp FROM community'); duckdb.sql('LOAD otlp')"

COPY convert.py /app/convert.py
WORKDIR /app
CMD ["python", "-u", "/app/convert.py"]
