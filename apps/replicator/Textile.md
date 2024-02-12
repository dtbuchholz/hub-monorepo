# Textile Vaults Replication

> Persist replicated data from Farcaster Hubs to Postgres with Textile & Filecoin

## Table of Contents

- [Table of Contents](#table-of-contents)
- [Background](#background)
  - [Project structure](#project-structure)
- [Install](#install)
  - [Set up environment variables](#set-up-environment-variables)
- [Usage](#usage)
  - [Replication process \& Docker](#replication-process--docker)
  - [Textile vaults \& streaming](#textile-vaults--streaming)
  - [Farcaster data \& Textile  events](#farcaster-data--textile--events)
  - [Retrieving \& querying vault events](#retrieving--querying-vault-events)
  - [Example logs](#example-logs)
  - [Next steps](#next-steps)
- [Development](#development)

## Background

The Farcaster replicator app takes data from Hubs and stores it in a Postgres database, which lets developers query Farcaster data and easily build applications on top of the network's data. You can check out the Farcaster [docs for more information](https://docs.farcaster.xyz/developers/guides/apps/replicate) on the existing functionality, but make sure you have *at least* 2GB of memory and 4GB of free disk space to run the replicator app. (Farcaster's estimates are outdated, and you'll definitely need more memory/space to run the replicator app...there's been a lot of Farcaster activity lately that increased the storage/CPU requirements!).

The [Textile team](https://textile.io/) made a slight adjustment to the replicator app that makes the data available via the Textile Network's novel caching layer and cold storage adapter (to Filecoin). The [`vaults` CLI](https://github.com/tablelandnetwork/basin-cli) made this process easy to implement. It lets you create vaults and stream data from a Postgres database to decentralized storage, retrievable by "event" [CIDs](https://docs.ipfs.tech/concepts/content-addressing/). Thus, anyone can extract openly replicated data from a vault and load it into their own applications instead of running the replicator app themselves.

### Project structure

The Textile replication process is handled using shell scripts and a custom Docker image. In order to use the `vaults` CLI tool, the `wal2json` Postgres extension must be installed/configured, and the `vaults` binary must also be installed. You can check out the [`dtbuchholz/textile-vaults-farcaster`](https://hub.docker.com/repository/docker/dtbuchholz/textile-vaults-farcaster/general) for the published Docker image, which supports the `linux/arm64` architecture.

Since the replicator app already uses Docker Compose, the original source code is, largely, untouched. The `docker-compose.yml` file has been updated to include the new Docker image as well as the necessary environment variables for the `vaults` CLI (`TEXTILE_PRIVATE_KEY` & `TEXTILE_VAULT_NAMESPACE`).

Then, a couple of custom scripts were added:
- `custom-entrypoint.sh`: Entrypoint for the Docker image, which sets up Postgres to use logical replication & increases the max replication slots & senders to account for 12 total Farcaster tables via `postgres -c wal_level=logical -c max_replication_slots=15 -c max_wal_senders=15`. Then, it then runs the `vaults` commands defined in `textile_vaults.sh`.
- `textile_vaults.sh`: Polls for the Farcaster tables to be created after the replicator app's migration process, and then starts replicating the data to Textile as it gets inserted into the Postgres database/tables.

## Install

Start by cloning this forked repository, navigating to the root directory, installing/building, and navigating to the `apps/replicator` directory. Note that one of the apps is `@farcaster/hubble`, which requires [`cargo` to be installed](https://doc.rust-lang.org/cargo/getting-started/installation.html) on your machine but isn't used in the replicator app.

```sh
git clone https://github.com/dtbuchholz/hub-monorepo
cd hub-monorepo
yarn install
yarn build
cd apps/replicator
```

### Set up environment variables

Once you install & build, you need to copy the `.env.example` file (in `apps/replicator`) to a new `.env` file and fill in the necessary environment variables. All of the Farcaster-related ones are pre-configured for you. For context, *most* of these come from the `.env` file that gets created if you were to run the official replicator bootstrapping process, described [here](https://docs.farcaster.xyz/developers/guides/apps/replicate#installation). The only change is that `nemes.farcaster.xyz:2283` is used as the `FARCASTER_HUB_URL`, which lets us skip the setup step for Hubble and use a public Hubble API, provided by the [Farcaster team](https://docs.farcaster.xyz/hubble/hubble#public-instances). 

The `TEXTILE_PRIVATE_KEY` and `TEXTILE_VAULT_NAMESPACE` environment variables are the only new ones you need to add. You can use an existing Ethereum-style (secp256k1) private key for `TEXTILE_PRIVATE_KEY` (note: *do not* hex-prefix the string in the `.env` file). Or, you can run the following command to generate a new one...just make sure the [`vaults` CLI is installed](https://github.com/tablelandnetwork/basin-cli?tab=readme-ov-file#install) if you run this on your machine!:

```sh
vaults account create .wallet
```

This will create a private key and store it on your machine in a file called `.wallet` (or whatever file name you choose). The `TEXTILE_VAULT_NAMESPACE` can be any string you want to use to namespace your vaults—the example below uses `demo_farcaster_2`. When a vault is created, it will be prefixed with this string, and each table that gets replicated will exist under this namespace. 

For example, the `casts` table would be replicated to a vault called `my_namespace.casts`. The following defines all of the tables that get replicated:
- casts
- chain_events
- fids
- fnames
- links
- messages
- reactions
- signers
- storage_allocations
- user_data
- username_proofs
- verifications

## Usage

### Replication process & Docker

To run the replicator app, you'll need to make sure you have [Docker installed](https://docs.docker.com/engine/install/) and running. Then, you can start the replicator app by running the following command from the `apps/replicator` directory:

```sh
docker compose up
```

This will kick off a process that does the following:
- Spins up 5 total Docker containers: one for the core replicator app, Redis (caching), statsd (for stats aggregation), Grafana (to view stats), and the Postgres database (altered with Textile functionality).
- Fetches the latest Farcaster data from the Nemes Hub and runs through a migration process that writes backfilled data to the Postgres database.
- Streams Postgres changes to Textile via the `vaults` CLI, which creates vaults for each table and replicates the data to Textile's decentralized storage.
- The replicated data goes to both a caching layer and cold storage layer, so it can be retrieved ~immediately for a pre-configured TTL (time-to-live) and ~indefinitely from Filecoin—all using the `vaults retrieve <cid>` command.

> Note: The Textile script is designed naively to run only on startup, so if you exit the Docker process and restart it, the script will start from the beginning and try to create new vaults for each table.

### Textile vaults & streaming

If you review the [`textile_vaults.sh`](./textile_vaults.sh) script, there are two important steps that occur. First, new vaults are created for every Farcaster table with the `vaults create` command:

```sh
vaults create \
--account "$(vaults account address "${private_key_file}")" \
--cache 10080 \
--dburi "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}" \
--window-size 1800 \
"${TEXTILE_VAULT_NAMESPACE}.${table}"
```

- `--account`: Sets the account address to use for the vault, which is the public key of the private key you set in the `.env` file (provided by the `vaults account address` command).
- `--cache`: Sets the TTL in minutes, so `10080` is equivalent to 7 days of cached data storage & retrieval.
- `--dburi`: Defines the Postgres database to stream data from.
- `--window-size`: Sets the window size in seconds, which is the time period to batch changes before sending them to Textile—in this example, every 30 minutes.
- Lastly, the `${TEXTILE_VAULT_NAMESPACE}.${table}` part of the script defines the vault name. This is the the environment variable you set in the `.env` file and the name of the table in Postgres that's being replicated, separated by a period (`.`).

Then, the script starts replicating the data to Textile with the `vaults stream` command:

```sh
vaults stream \
--private-key "${TEXTILE_PRIVATE_KEY}" \
"${TEXTILE_VAULT_NAMESPACE}.${table}"
```

- `--private-key`: The private key you set in the `.env` file is used to sign all data that gets sent to Textile, which ensures data integrity and authenticity.
- `${TEXTILE_VAULT_NAMESPACE}.${table}`: The name of the vault (formatted as `namespace.table_name`) to stream data to, which gets created in the preceding `vaults create` command.

### Farcaster data & Textile  events

Because Textile makes the data publicly available, you can work with data that's already been backfilled in an existing vault. First, you'll want to make sure the `vaults` CLI is installed on your machine (note: [make sure Go is installed](https://go.dev/doc/install) on your machine first):

```sh
go install github.com/tablelandnetwork/basin-cli/cmd/vaults@latest
```

For the sake of this demonstration, we've created a vault with the namespace `demo_farcaster_2` (ignore `demo_farcaster` as this was a test). The owner of this vault is at the account `0x5e50Bb5A0fA30c4b9B6a809687CDB90A776D8bB7`. You can start by checking out all of the vaults owned by this account:

```sh
vaults list --account 0x5e50Bb5A0fA30c4b9B6a809687CDB90A776D8bB7
```

> Note: Due to some demo script issues and constraints when running Docker, the following tables did not get replicated to the `demo_farcaster_2` namespace: `fids`, `fnames`, `casts`, `signers`, and `messages`. If you run the `vaults events` command, nothing will be listed for any of these. Additionally, after about 6 hours, the Docker image maxed out on memory and caused Redis to fail, which then caused the replication process to halt. In total, the database reached 2.867 GB at the time the processes were (manually) killed.

This will list out each of those described above, such as `demo_farcaster_2.user_data`, `demo_farcaster_2.reactions`, etc. You can then retrieve the data from any of these vaults by running the following command to see each event CID (the example shows data from the table `user_data`). An event gets created anytime new data is written to the vault and the window size is reached.

```sh
vaults events --vault demo_farcaster_2.user_data --format json
```

Which will log out a list of CIDs that you can use to retrieve the data from the vault:

```json
[
  {
    "cid": "bafkreietgpbkfvdjyqlpwph75eajcp2pix3uw5dajjrfxvzvxv6gti7duy",
    "timestamp": 1707970383,
    "is_archived": false,
    "cache_expiry": "2024-02-22T04:13:08.355842"
  }
]
```

### Retrieving & querying vault events

If the Textile cache feature is enabled—and the TTL has not expired—the data will be available immediately. If not, it will be routed from IPFS/Filecoin and retrieved from cold storage.

```sh
vaults retrieve bafkreietgpbkfvdjyqlpwph75eajcp2pix3uw5dajjrfxvzvxv6gti7duy
```

Once you download this data, you can then load it into your own application. The file gets downloaded with a filename in the format `<cid>-<timestamp>.db.parquet`, so you can use any Parquet reader to load the data into your application—for example, [DuckDB](https://duckdb.org/#quickinstall).

First, make sure the DuckDB CLI installed on your machine, such as using Homebrew:

```sh
brew install duckdb
```

Then, you can load the data within a DuckDB in-memory database using the `read_parquet` function:

```sql
> duckdb
SELECT
  *
FROM
  read_parquet(
    'bafkreietgpbkfvdjyqlpwph75eajcp2pix3uw5dajjrfxvzvxv6gti7duy-1707948730199375716.db.parquet'
  )
LIMIT
  5;
```

Note that DuckDB also lets you load multiple files at once or even remote URLs by passing an array instead of a single string. This is useful if a vault has multiple events and you want to load all of the data at once:

```sql
SELECT
  *
FROM
  read_parquet([
    'bafy123...',
    'bafy456...',
    'bafy789...'
  ])
LIMIT
  5;
```

Once you execute the query, it logs the data from that specific table's updates and the Textile event created in the Hubble -> Postgres -> Textile replication process. For example, the `user_data` table's first 5 rows of the Parquet file look like this:

```sh
│          id          │      created_at      │      updated_at      │      timestamp       │      deleted_at       │  fid  │ type  │                   hash                   │                           value                            │
│         uuid         │ timestamp with tim…  │ timestamp with tim…  │ timestamp with tim…  │ timestamp with time…  │ int64 │ int16 │                   blob                   │                          varchar                           │
├──────────────────────┼──────────────────────┼──────────────────────┼──────────────────────┼───────────────────────┼───────┼───────┼──────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
│ 018da9ad-5b90-8ec2…  │ 2024-02-14 14:12:0…  │ 2024-02-14 14:12:0…  │ 2023-03-15 13:09:5…  │                       │     1 │     1 │ 481d5e80de1b2803e89c6ad96ab349979a689358 │ https://i.imgur.com/I2rEbPF.png                            │
│ 018da9ad-5ba6-34a8…  │ 2024-02-14 14:12:0…  │ 2024-02-14 14:12:0…  │ 2023-07-21 18:20:4…  │                       │     1 │     3 │ 0edc9e1164b7d743517e6c0df4ec9f539ab4252b │ A sufficiently decentralized social network. farcaster.xyz │
│ 018da9ad-5bc3-5854…  │ 2024-02-14 14:12:0…  │ 2024-02-14 14:12:0…  │ 2023-07-21 18:20:4…  │                       │     1 │     2 │ 96b2d28bdeb7bbdd3a18bd8cca02dc7e47885e17 │ Farcaster                                                  │
│ 018da9ad-5bd1-e410…  │ 2024-02-14 14:12:0…  │ 2024-02-14 14:12:0…  │ 2023-07-21 18:20:4…  │                       │     1 │     6 │ a4a8e1d17e904e18ea5ac3b8f28060404009ab6a │ farcaster                                                  │
│ 018da9b2-b768-dec1…  │ 2024-02-14 14:17:5…  │ 2024-02-14 14:17:5…  │ 2023-03-14 23:40:2…  │                       │    20 │     6 │ e182eeb294ed98fe8fdc76c7cb06d3563a3f6855 │ barmstrong                                                 │
└──────────────────────┴──────────────────────┴──────────────────────┴──────────────────────┴───────────────────────┴───────┴───────┴──────────────────────────────────────────┴────────────────────────────────────────────────────────────┘
```

> Fun fact: As shown above, the first ever user data was an image of the Farcaster logo: [https://i.imgur.com/I2rEbPF](https://i.imgur.com/I2rEbPF). Plus, the fifth piece of user data was a message from/about Brian Armstrong (`barmstrong`)!

### Example logs

Below shows an abbreviated version of the logs. You can see that once the Farcaster replicator starts to backfill the FID registrations, it kicks off the Textile vault creation and streaming processes. Everything before the last section of the logs is part of the setup process, and once new data is inserted into the table, the streaming process begins.

```sh
replicator-1  | [22:36:36.847] INFO (7): Enqueuing jobs for backfilling FID registrations for 346480 FIDs...
...
postgres-1    | All required tables exist; proceeding with Textile vaults
postgres-1    | Creating vaults for tables...
postgres-1    | Vault demo_farcaster_2.chain_events created.
...
postgres-1    | Streaming tables...
postgres-1    | Streaming to vault: 'demo_farcaster_2.user_data'
...
2024/02/14 21:20:45 INFO created new db at=/root/.vaults/demo_farcaster_2.chain_events/1707945645693026302.db
2024/02/14 21:20:45 INFO applying create query="CREATE TABLE IF NOT EXISTS chain_events (id uuid NOT NULL,created_at timestamp with time zone NOT NULL,block_timestamp timestamp with time zone NOT NULL,fid bigint NOT NULL,chain_id bigint NOT NULL,block_number bigint NOT NULL,transaction_index smallint NOT NULL,log_index smallint NOT NULL,type smallint NOT NULL,block_hash blob NOT NULL,transaction_hash blob NOT NULL,body varchar NOT NULL,raw blob NOT NULL,PRIMARY KEY (id))"
...
2024-02-14 21:20:45.700 UTC [475] LOG:  starting logical decoding for slot "basin_chain_events"
2024-02-14 21:20:45.700 UTC [475] DETAIL:  Streaming transactions committing after 0/1A16208, reading WAL from 0/1A161D0.
2024-02-14 21:20:45.700 UTC [475] STATEMENT:  START_REPLICATION SLOT basin_chain_events LOGICAL 0/1A16208 ("pretty-print" 'false', "include-transaction" 'true', "include-lsn" 'true', "include-timestamp" 'true', "include-pk" 'true', "format-version" '2', "include-xids" 'true', "add-tables" 'public.chain_events')
2024-02-14 21:20:45.700 UTC [475] LOG:  logical decoding found consistent point at 0/1A161D0
2024-02-14 21:20:45.700 UTC [475] DETAIL:  There are no running transactions.
2024-02-14 21:20:45.700 UTC [475] STATEMENT:  START_REPLICATION SLOT basin_chain_events LOGICAL 0/1A16208 ("pretty-print" 'false', "include-transaction" 'true', "include-lsn" 'true', "include-timestamp" 'true', "include-pk" 'true', "format-version" '2', "include-xids" 'true', "add-tables" 'public.chain_events')
2024/02/14 21:20:45 INFO Logical replication started slot=basin_chain_events
...
2024/02/14 21:21:03 INFO new transaction received
2024/02/14 21:21:03 INFO replaying query="insert into chain_events (id, created_at, block_timestamp, fid, chain_id, block_number, transaction_index, log_index, type, block_hash, transaction_hash, body, raw) values ('018da97e-9c50-bd1d-0a3b-8c71bb062e74', '2024-02-14 21:21:03.508914+00', '2023-11-07 19:42:51+00', 22, 10, 111893697, 7, 24, 3, '73eaf3e303afa0d8e48ab3ac043ce60130f5061beb33314efa70d7bde5941b76', '286dd35ce467bfb3db7e8e4b036909a5e2769d0efadb6f342ef1d8970ea1e264', '{\"to\":\"0x411c9d8a1788c5764b32b44e6c381a541bfdce65\",\"eventType\":1,\"from\":\"0x\",\"recoveryAddress\":\"0x00000000fcb080a4d6c39a9354da9eb9bc104cd7\"}', '0803100a18c1b9ad35222073eaf3e303afa0d8e48ab3ac043ce60130f5061beb33314efa70d7bde5941b7628bba6aaaa063220286dd35ce467bfb3db7e8e4b036909a5e2769d0efadb6f342ef1d8970ea1e264381840165a2e0a14411c9d8a1788c5764b32b44e6c381a541bfdce651001221400000000fcb080a4d6c39a9354da9eb9bc104cd768077002')"
...
```

### Next steps

The script demonstarted a simple yet important concept: streaming data from a Postgres database to Textile's decentralized storage via the `vaults` CLI is a powerful way to make data publicly available and easily retrievable. From a programming perspective, the code could be improved quite a bit to handle failures, retries, and other edge cases.

Now, if you were to load *all* of the events/CIDs into something like DuckDB, you could then query the data across the entire Farcaster network. In other words, the replicated data on Textile is now available for you to use in your own applications, and you can query it as you would any other SQL (or other) database!

As a developer, this could facilitate a much quicker onboarding time. For example, if the Farcaster team were to run the vaults streaming process as a public good, then any developer continually could load all of the data into their own application and start building on top of the Farcaster network without having to run the replicator app themselves. This would save not only time but also costs and resources for the community—and also increase how quickly a dev can start building on top of the network's data.

## Development

If you'd like to alter the Textile scripts and/or Docker image, you can use `docker build` to produce the Postgres + Textile image with the following commands:

```sh
docker build -t <your_username>/textile-vaults-farcaster:latest .
docker image push <your_username>/textile-vaults-farcaster
```

Just be sure to update the `docker-compose.yml` file with the new image name under the `postgres` service. To support other architectures, check out [`docker buildx`](https://docs.docker.com/engine/reference/commandline/buildx/).