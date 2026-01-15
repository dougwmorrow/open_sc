# Extracting 4 Billion Oracle Rows to SQL Server via Python and BCP

Moving **4 billion records** from an unindexed Oracle 19c table to SQL Server requires a carefully orchestrated pipeline combining ROWID-based parallel extraction, memory-efficient Polars processing, and optimized BCP bulk loading. The key breakthrough is using Oracle's physical ROWID structure to partition extraction without indexes, enabling parallel workers to each process distinct data block ranges. Real-world implementations at this scale—including a documented **55 billion row migration**—demonstrate that properly configured pipelines achieve [SQL Jana](https://sqljana.wordpress.com/2017/04/10/eating-an-elephant-how-to-work-with-huge-datasets-in-oracle-and-sql-server/) **1.5-3 million rows per second**, making a 4 billion row transfer feasible in **4-10 hours**. [wordpress](https://sqljana.wordpress.com/2017/04/10/eating-an-elephant-how-to-work-with-huge-datasets-in-oracle-and-sql-server/)

This architecture spans three servers: Python extraction on Red Hat Linux pulling from Oracle 19c (read-only), transforming via Polars to CSV, then BCP loading to Windows SQL Server. The critical constraints—no DBA access to Oracle, no indexes available—make ROWID range partitioning the only viable parallel extraction strategy.

## ROWID range partitioning unlocks parallel extraction without indexes

Oracle's extended ROWID encodes the physical location of every row: data object number, relative file number, block number, and row number within the block. The `DBMS_ROWID` package exposes functions to decompose and construct ROWIDs, [oracle](https://docs.oracle.com/en/database/oracle/oracle-database/19/arpls/DBMS_ROWID.html) [Oracle](https://docs.oracle.com/cd/B10500_01/appdev.920/a96612/d_rowid.htm) enabling you to calculate block ranges that partition the table into parallel chunks.

**Calculating ROWID ranges from extent information:**

```sql
-- Query extent information and create ROWID range boundaries
WITH extents_data AS (
    SELECT o.data_object_id, e.relative_fno, e.block_id, e.blocks,
           SUM(e.blocks) OVER() AS total_blocks,
           SUM(e.blocks) OVER(ORDER BY e.file_id, e.block_id) AS cumul_blocks
    FROM dba_extents e
    JOIN all_objects o ON (e.owner, e.segment_name) = (o.owner, o.object_name)
    WHERE e.segment_name = 'MY_TABLE' AND e.owner = 'MY_SCHEMA'
      AND e.segment_type LIKE 'TABLE%'
),
bucketed AS (
    SELECT data_object_id, relative_fno, block_id, blocks,
           CEIL(cumul_blocks / (total_blocks / :num_workers)) AS bucket
    FROM extents_data
)
SELECT bucket AS worker_id,
       DBMS_ROWID.ROWID_CREATE(1, MIN(data_object_id), 
           MIN(relative_fno), MIN(block_id), 0) AS start_rowid,
       DBMS_ROWID.ROWID_CREATE(1, MAX(data_object_id), 
           MAX(relative_fno), MAX(block_id) + MAX(blocks) - 1, 32767) AS end_rowid
FROM bucketed
GROUP BY bucket ORDER BY bucket;
```

Oracle's built-in `DBMS_PARALLEL_EXECUTE` package offers an alternative that handles chunk calculation automatically:

```sql
BEGIN
    DBMS_PARALLEL_EXECUTE.create_task('extract_task');
    DBMS_PARALLEL_EXECUTE.create_chunks_by_rowid(
        task_name   => 'extract_task',
        table_owner => 'MY_SCHEMA',
        table_name  => 'MY_TABLE',
        by_row      => FALSE,     -- Chunk by blocks, not rows
        chunk_size  => 10000     -- Blocks per chunk
    );
END;
-- Retrieve: SELECT chunk_id, start_rowid, end_rowid 
--           FROM user_parallel_execute_chunks WHERE task_name = 'extract_task';
```

Each extraction worker then executes `SELECT /*+ FULL(t) */ * FROM my_table t WHERE ROWID BETWEEN :start AND :end`, with Oracle efficiently scanning only the relevant physical blocks. **ROWID-based chunking avoids the critical flaw of ROWNUM approaches**—OFFSET/FETCH still scans all preceding rows, creating redundant I/O and potential hot spots.

## Python extraction architecture with python-oracledb

**python-oracledb replaces cx_Oracle** as the recommended driver for new projects. It offers thin mode (no Oracle Client libraries required), asyncio support, and active development since cx_Oracle's 2022 deprecation. The migration is a simple import change.

**Optimized parallel extraction implementation:**

```python
import oracledb
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
from dataclasses import dataclass

@dataclass
class RowidRange:
    worker_id: int
    start_rowid: str
    end_rowid: str

CONFIG = {
    'user': 'readonly_user',
    'password': 'password',
    'dsn': 'oracle-host:1521/service_name',
    'num_workers': 8,
    'batch_size': 5000,       # Rows per fetch
    'output_dir': '/data/extract'
}

# Create connection pool sized for workers
pool = oracledb.create_pool(
    user=CONFIG['user'], password=CONFIG['password'], dsn=CONFIG['dsn'],
    min=CONFIG['num_workers'], max=CONFIG['num_workers'] + 2
)

# Set fetch optimization globally
oracledb.defaults.arraysize = CONFIG['batch_size']
oracledb.defaults.prefetchrows = CONFIG['batch_size']

def extract_chunk(range_info: RowidRange, output_path: str) -> dict:
    """Extract one ROWID range to CSV file."""
    sql = """SELECT /*+ FULL(t) */ * FROM my_schema.my_table t
             WHERE ROWID BETWEEN :start_rowid AND :end_rowid"""
    
    stats = {'worker_id': range_info.worker_id, 'rows': 0}
    
    with pool.acquire() as conn:
        with conn.cursor() as cursor:
            cursor.arraysize = CONFIG['batch_size']
            cursor.execute(sql, start_rowid=range_info.start_rowid, 
                          end_rowid=range_info.end_rowid)
            columns = [d[0] for d in cursor.description]
            
            with open(output_path, 'w', newline='') as f:
                writer = csv.writer(f)
                writer.writerow(columns)
                while batch := cursor.fetchmany():
                    writer.writerows(batch)
                    stats['rows'] += len(batch)
    return stats

def parallel_extract(rowid_ranges: list[RowidRange]):
    with ThreadPoolExecutor(max_workers=CONFIG['num_workers']) as executor:
        futures = {
            executor.submit(extract_chunk, r, 
                f"{CONFIG['output_dir']}/chunk_{r.worker_id:04d}.csv"): r
            for r in rowid_ranges
        }
        for future in as_completed(futures):
            stats = future.result()
            print(f"Worker {stats['worker_id']}: {stats['rows']:,} rows")
```

**Key tuning parameters**: Set `arraysize` and `prefetchrows` to **1,000-10,000** for bulk extraction (default 100 is far too small). These control rows fetched per network round-trip. Using `/*+ PARALLEL(t, 8) */` hints forces direct path reads bypassing the buffer cache, [SmartTechWays](https://smarttechways.com/2025/12/03/oracle-direct-path-read-explained-a-complete-guide-causes-internals-tuning-tips/) beneficial when Oracle has available parallel query slaves. [Dincosman](https://dincosman.com/2023/10/26/oracle-optimizer-decisions/)

## Polars streaming enables memory-efficient CSV generation

Processing 4 billion rows requires strict memory management. Polars provides streaming capabilities through `LazyFrame` operations and `sink_csv()`, but for database extraction, **chunk-by-chunk eager processing** is more practical since database cursors don't integrate with Polars' lazy scanning.

**Memory-efficient pattern for database-to-CSV:**

```python
import polars as pl

def db_chunk_to_polars_csv(cursor, output_path: str, batch_size: int = 100_000):
    """Stream database results through Polars to CSV."""
    
    # Optimized schema reduces memory ~50-80% vs defaults
    schema = {
        "id": pl.Int32,              # vs Int64: 50% smaller
        "category": pl.Categorical,   # vs String: 80%+ smaller for repeated values
        "amount": pl.Float32,         # vs Float64: 50% smaller
        "created_date": pl.Date,
    }
    
    first_chunk = True
    columns = [d[0] for d in cursor.description]
    
    while rows := cursor.fetchmany(batch_size):
        # Convert to dict format for Polars
        data = {col: [row[i] for row in rows] for i, col in enumerate(columns)}
        df = pl.DataFrame(data).cast(schema)
        
        # Append to CSV (mode 'a' after first chunk)
        with open(output_path, 'ab' if not first_chunk else 'wb') as f:
            df.write_csv(f, include_header=first_chunk, batch_size=1024)
        
        first_chunk = False
        del df  # Explicit cleanup
```

**Memory estimates**: With 100,000-row batches and 10 columns of mixed types, expect **50-200 MB peak memory** per worker. For 4 billion rows split across 8 workers writing to separate files, total memory stays under 2 GB while achieving high throughput.

For multi-file output splitting (recommended for parallel BCP loading), target **10-50 million rows per file**:

```python
def split_output_files(cursor, output_dir: str, max_rows_per_file: int = 10_000_000):
    file_idx, rows_in_file = 0, 0
    current_writer = None
    
    for batch in fetch_batches(cursor):
        if rows_in_file + len(batch) > max_rows_per_file or current_writer is None:
            if current_writer: current_writer.close()
            file_idx += 1
            current_writer = open(f"{output_dir}/data_{file_idx:04d}.csv", 'w')
            rows_in_file = 0
        # Write batch...
        rows_in_file += len(batch)
```

## BCP bulk loading at maximum throughput

BCP (Bulk Copy Program) is the **fastest method for loading data into SQL Server**, significantly outperforming SSIS or linked server approaches. The critical optimization is enabling **minimal logging** through proper configuration.

**Optimized BCP command for billion-row loads:**

```bash
bcp MyDatabase.dbo.TargetTable in /staging/data_0001.csv \
    -S sqlserver-host \
    -T \                          # Trusted connection (or -U/-P)
    -c \                          # Character format for CSV
    -t, \                         # Comma field terminator
    -r "\n" \                     # Newline row terminator
    -a 16384 \                    # 16KB packet size (optimal for extent writes)
    -b 100000 \                   # 100K rows per batch/transaction
    -h "TABLOCK,ORDER(id ASC)" \  # Critical: enables minimal logging
    -e /logs/errors.log \
    -o /logs/output.log
```

**Minimal logging prerequisites** (all must be met):
- Database recovery model: **BULK_LOGGED** or SIMPLE
- **TABLOCK** hint specified (acquires table lock)
- Target table is empty heap, or empty clustered index, or has TF610/Fast Load Context enabled
- Table not published for replication

**SQL Server preparation script:**

```sql
-- Pre-load configuration
ALTER DATABASE TargetDB SET RECOVERY BULK_LOGGED;
ALTER INDEX ALL ON dbo.TargetTable DISABLE;  -- Disable non-clustered indexes
ALTER TABLE dbo.TargetTable NOCHECK CONSTRAINT ALL;

-- After all BCP loads complete:
ALTER INDEX ALL ON dbo.TargetTable REBUILD WITH (MAXDOP = 8, ONLINE = OFF);
UPDATE STATISTICS dbo.TargetTable WITH FULLSCAN;
ALTER TABLE dbo.TargetTable CHECK CONSTRAINT ALL;
ALTER DATABASE TargetDB SET RECOVERY FULL;
BACKUP DATABASE TargetDB TO DISK = 'backup_path';  -- Required after BULK_LOGGED
```

**Parallel BCP loading** multiplies throughput. With pre-split CSV files:

```bash
#!/bin/bash
# Parallel BCP loader - 4 concurrent processes
MAX_PARALLEL=4
for file in /staging/data_*.csv; do
    while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]; do sleep 1; done
    bcp MyDB.dbo.Table in "$file" -S server -T -c -t, -b 100000 -h "TABLOCK" &
done
wait
```

**Expected throughput benchmarks**:

| Configuration | Rows/Second |
|---------------|-------------|
| Single BCP, no optimization | 50,000-100,000 |
| Single BCP, optimized (TABLOCK, batch sizing) | 200,000-500,000 |
| Parallel BCP (4 processes) | 500,000-1,500,000 |
| Parallel BCP + SSD + optimal config | 1,500,000-3,000,000 |

## End-to-end pipeline architecture with checkpointing

The **55 billion row Oracle-to-SQL-Server migration** documented by SQL Jana validates this chunked, checkpoint-enabled architecture. Their "PowerPump" approach emphasizes: break tables into ROWID chunks, track completion status, enable resume on failure. [wordpress](https://sqljana.wordpress.com/2017/04/10/eating-an-elephant-how-to-work-with-huge-datasets-in-oracle-and-sql-server/) [SQL Jana](https://sqljana.wordpress.com/2017/04/10/eating-an-elephant-how-to-work-with-huge-datasets-in-oracle-and-sql-server/)

**Pipeline architecture diagram:**

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐     ┌─────────────┐
│   Oracle    │────▶│   Extract    │────▶│   Polars    │────▶│    BCP      │
│   Source    │     │   Workers    │     │   Transform │     │   Loaders   │
│  (4B rows)  │     │   (4-8)      │     │   to CSV    │     │   (4-10)    │
└─────────────┘     └──────────────┘     └─────────────┘     └─────────────┘
                           │                    │                    │
                           ▼                    ▼                    ▼
                    ┌──────────────────────────────────────────────────┐
                    │              SQLite Checkpoint Store              │
                    │  (table, chunk_id, start_rowid, end_rowid, status)│
                    └──────────────────────────────────────────────────┘
```

**Checkpoint implementation:**

```python
import sqlite3

def init_checkpoint_db(db_path: str):
    conn = sqlite3.connect(db_path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS checkpoints (
            table_name TEXT, chunk_id INTEGER, start_rowid TEXT, end_rowid TEXT,
            status TEXT, rows_processed INTEGER, timestamp DATETIME,
            PRIMARY KEY (table_name, chunk_id)
        )
    """)
    return conn

def mark_chunk_complete(conn, table_name: str, chunk_id: int, rows: int):
    conn.execute("""
        UPDATE checkpoints SET status='COMPLETE', rows_processed=?, 
               timestamp=datetime('now') WHERE table_name=? AND chunk_id=?
    """, (rows, table_name, chunk_id))
    conn.commit()

def get_pending_chunks(conn, table_name: str) -> list:
    return conn.execute("""
        SELECT chunk_id, start_rowid, end_rowid FROM checkpoints
        WHERE table_name=? AND status='PENDING' ORDER BY chunk_id
    """, (table_name,)).fetchall()
```

**Named pipes eliminate disk bottleneck** when network and processing speeds align. On Linux, create a FIFO that streams extraction directly to compression or transfer:

```bash
mkfifo /tmp/datastream
# Producer: Python writes to FIFO
python extract_to_pipe.py --output /tmp/datastream &
# Consumer: Compress and transfer
cat /tmp/datastream | gzip | ssh sqlserver "gunzip > /staging/data.csv"
```

However, **intermediate files are preferable** when checkpointing is critical or parallel BCP loading is needed—you cannot restart a failed stream, but you can resume from the last completed chunk file.

## Disk space planning and performance expectations

**Storage estimation for 4 billion rows:**

| Metric | Estimate |
|--------|----------|
| Average row size (typical OLTP) | 100-200 bytes |
| Uncompressed CSV total | 400-800 GB |
| With gzip compression (~70% reduction) | 120-240 GB |
| Working space (extract + staging) | 1-1.5 TB recommended |

**Timeline projection** based on benchmarks:

| Phase | Duration | Assumptions |
|-------|----------|-------------|
| ROWID range calculation | 5-15 minutes | Querying DBA_EXTENTS |
| Parallel extraction (8 workers) | 2-4 hours | 500K rows/sec aggregate |
| Network transfer (1 Gbps) | 1-2 hours | Compressed ~200 GB |
| Parallel BCP load (4 processes) | 1-3 hours | 1M+ rows/sec aggregate |
| Index rebuild | 30-60 minutes | MAXDOP=8, depends on indexes |
| **Total** | **4-10 hours** | With SSD storage throughout |

**Common failure modes to monitor:**
- **ORA-01555 "snapshot too old"**: Increase UNDO retention or reduce chunk sizes [wordpress](https://sqljana.wordpress.com/2017/04/10/eating-an-elephant-how-to-work-with-huge-datasets-in-oracle-and-sql-server/)
- **SQL Server transaction log full**: Ensure BULK_LOGGED mode, appropriate batch sizes
- **Memory exhaustion**: Bound queue sizes, reduce batch_size if needed [GitHub](https://github.com/Delgan/loguru/issues/1419)
- **Network timeouts**: Implement retry logic with exponential backoff

## Conclusion

Successfully extracting 4 billion rows from an unindexed Oracle table requires orchestrating ROWID-based physical partitioning, connection-pooled parallel extraction via python-oracledb, memory-bounded Polars transformation, and TABLOCK-enabled BCP bulk loading. The **critical insight from 55-billion-row production migrations** is that chunk-level checkpointing transforms an all-or-nothing operation into a resumable, parallelizable workflow. [wordpress](https://sqljana.wordpress.com/2017/04/10/eating-an-elephant-how-to-work-with-huge-datasets-in-oracle-and-sql-server/) [SQL Jana](https://sqljana.wordpress.com/2017/04/10/eating-an-elephant-how-to-work-with-huge-datasets-in-oracle-and-sql-server/)

Key configuration values to start with: **8 extraction workers**, **5,000 arraysize/prefetchrows**, **100,000 BCP batch size**, **16KB packet size**, **10M rows per CSV file**. Stage files on SSD, pre-split for parallel BCP processes, and disable non-clustered indexes during load. With this architecture, expect **completion in 4-10 hours** depending on row width, network speed, and storage performance—a dramatic improvement over naive sequential approaches that would take days.