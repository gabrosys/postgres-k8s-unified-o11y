dbset db pg
dbset bm TPC-C
diset connection pg_host $::env(PGHOST)
diset connection pg_port $::env(PGPORT)
diset tpcc pg_user $::env(PGUSER)
diset tpcc pg_pass $::env(PGPASSWORD)
diset tpcc pg_dbase $::env(PGDATABASE)
diset tpcc pg_storedprocs false
diset tpcc pg_driver timed
diset tpcc pg_rampup 0
diset tpcc pg_duration 1440
# Without keying and think time 25 virtual users issue thousands of statements a second.
diset tpcc pg_keyandthink true
loadscript
vuset vu $::env(VIRTUAL_USERS)
vuset logtotemp 0
vucreate
vurun
