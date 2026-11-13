dbset db pg
dbset bm TPC-C
diset connection pg_host $::env(PGHOST)
diset connection pg_port $::env(PGPORT)
diset tpcc pg_superuser $::env(PGUSER)
diset tpcc pg_superuserpass $::env(PGPASSWORD)
diset tpcc pg_defaultdbase $::env(PGDATABASE)
diset tpcc pg_user $::env(PGUSER)
diset tpcc pg_pass $::env(PGPASSWORD)
diset tpcc pg_dbase $::env(PGDATABASE)
diset tpcc pg_count_ware $::env(WAREHOUSES)
diset tpcc pg_num_vu $::env(WAREHOUSES)
diset tpcc pg_storedprocs false
buildschema
