#!/bin/bash

# Start PostgreSQL in the background
docker-entrypoint.sh postgres -c wal_level=logical -c max_replication_slots=15 -c max_wal_senders=15 &

# Execute your custom script in the background
textile_vaults.sh &

# Wait for the PostgreSQL process to complete
wait
