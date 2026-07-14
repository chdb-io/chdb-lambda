"""Bake the dataset into the image at build time.

Runs inside `docker build` (which Lambda executes during
create-microvm-image). It pulls N partitions of the public ClickBench web
analytics dataset from S3 and materializes them as a MergeTree table on the
image filesystem. The /ready hook later warms this store before Lambda
snapshots, so every MicroVM starts with the data hot.

Swap the CREATE TABLE ... AS SELECT below for your own dataset — anything
chDB can read works: S3, HTTP, Postgres, MySQL, Iceberg, local files.
"""
import os

from chdb import session as chdb_session

DATA_PATH = os.getenv("CHDB_DATA_PATH", "/app/chdb-data")
# How many 1M-row partitions to bake (ClickBench ships 100 of them).
PARTITIONS = int(os.getenv("BAKE_PARTITIONS", "1"))

BUCKET = "https://clickhouse-public-datasets.s3.amazonaws.com/hits_compatible/athena_partitioned"

sess = chdb_session.Session(DATA_PATH)
sess.query("CREATE DATABASE IF NOT EXISTS demo")

# Parquet columns come back Nullable; a MergeTree sorting key must not be,
# hence the assumeNotNull on the three key columns.
source = f"{BUCKET}/hits_{{0..{PARTITIONS - 1}}}.parquet" if PARTITIONS > 1 else f"{BUCKET}/hits_0.parquet"
sess.query(f"""
CREATE TABLE demo.hits
ENGINE = MergeTree
ORDER BY (CounterID, EventDate, UserID)
AS SELECT * REPLACE (
    assumeNotNull(CounterID) AS CounterID,
    assumeNotNull(EventDate) AS EventDate,
    assumeNotNull(UserID)    AS UserID
)
FROM s3('{source}', NOSIGN)
""")

rows = sess.query("SELECT count() FROM demo.hits", "TabSeparated").data().strip()
size = sess.query(
    "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts "
    "WHERE database = 'demo' AND table = 'hits' AND active",
    "TabSeparated",
).data().strip()
print(f"baked demo.hits: {rows} rows, {size} on disk at {DATA_PATH}")
sess.close()
