ch() {
  clickhouse-client --host "$CH_HOST" --user migrate --password "$CH_PASSWORD" \
    --distributed_ddl_output_mode=none --query "$1"
}
