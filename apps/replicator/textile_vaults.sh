#!/bin/bash

sleep 10 # Wait 10 seconds for initialization
echo "TEXTILE: vaults is starting..."

# Define the list of Farcaster Postgres tables
tables=(
  "casts"
  "chain_events"
  "fids"
  "fnames"
  "links"
  "messages"
  "reactions"
  "signers"
  "storage_allocations"
  "user_data"
  "username_proofs"
  "verifications"
)

# Function to check if a table exists in the database
table_exists() {
  local table_name="$1"
  exists=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -p 5432 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '${table_name}');" -tA)
  if [ "$exists" = "t" ]; then
    return 0  # Table exists
  else
    return 1  # Table does not exist
  fi
}

# Check table existence to ensure we wait to create vaults
echo "TEXTILE: checking if all tables exist..."
while true; do
  all_tables_exist=true

  for table in "${tables[@]}"; do
    if ! table_exists $table; then
      all_tables_exist=false
      break  # Exit if a table doesn't exist
    fi
  done

  if $all_tables_exist; then
    echo "TEXTILE: all required tables exist...proceeding with vault creation"
    break  # Exit if all tables exist
  else
    echo "TEXTILE: waiting for tables to be created..."
    sleep 10 # Wait 10 seconds before checking again
  fi
done

# Create a temporary file for the private key
# A file is needed by the `vaults account address` command
private_key_file=$(mktemp)
echo "${TEXTILE_PRIVATE_KEY}" > "${private_key_file}"

# Function to create vaults for each table, synchronously
create_vaults() {
  local private_key_file="$1"
  local table="$2"

  # Create a vault, passing the public key as the account with a 10080 minute
  # (7 day) cache and a 1800 second (30 minute) window size for the vault's WAL
  # files to trigger uploads to the Textile network
  if ! vaults create --account "$(vaults account address "${private_key_file}")" --cache 10080 --dburi "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}" --window-size 1800 "${TEXTILE_VAULT_NAMESPACE}.${table}" > /dev/null 2>&1; then
      echo "TEXTILE: error creating vault for table: '${table}'"
  fi
}

# Function to stream vaults for a table, asynchronously
stream_vaults() {
  local private_key_file="$1"
  local table="$2"

  vaults stream --private-key "${TEXTILE_PRIVATE_KEY}" "${TEXTILE_VAULT_NAMESPACE}.${table}" &
}

# Once all tables exist, proceed with creating vaults for each table,
# synchronously
echo "TEXTILE: creating vaults..."
for table in "${tables[@]}"; do
  create_vaults $private_key_file $table
done

# Once all vaults are created, proceed with starting streams, asynchronously
echo "TEXTILE: streaming to vaults..."
for table in "${tables[@]}"; do
  echo "TEXTILE: streaming '${TEXTILE_VAULT_NAMESPACE}.${table}'"
  stream_vaults $private_key_file $table &
done

# Cleanup the private key file securely after use
wait
rm "${private_key_file}"