CREATE TABLE IF NOT EXISTS checkout_orders (
  id bigserial PRIMARY KEY,
  trace_id text NOT NULL,
  w_id int NOT NULL,
  i_id int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
SELECT 'DROP INDEX CONCURRENTLY checkout_ol_item'
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
WHERE c.relname = 'checkout_ol_item' AND NOT i.indisvalid
\gexec
