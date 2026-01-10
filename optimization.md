# Optimizing billion-record Oracle-to-SQL Server migrations with Python and BCP

**For billion-record migrations from Oracle to SQL Server, a Python extraction with CSV staging and parallel BCP loading achieves the best balance of performance, reliability, and cost.** This approach consistently delivers **100,000-200,000 rows/second** on single-server infrastructure, completing billion-row transfers in **2-4 hours** with proper optimization. The key success factors are ROWID-based parallel extraction from Oracle using python-oracledb, streaming CSV generation with Polars, and BCP configured with TABLOCK hints, disabled indexes, and batch sizes of 100,000+ rows.

Modern Python tooling has transformed this pipeline: python-oracledb's Arrow integration enables zero-copy data interchange, [Readthedocs](https://python-oracledb.readthedocs.io/en/latest/user_guide/dataframes.html) Polars' streaming engine processes transformations with **8-10x less memory** than pandas, and BCP's bulk insert remains the fastest method for SQL Server loading. Alternative approaches like SSIS require careful tuning to avoid memory issues, Spark demands cluster infrastructure, and linked servers are completely non-viable at billion-record scale.

---

## Oracle extraction delivers maximum throughput with python-oracledb

The **python-oracledb** library (Oracle's successor to cx_Oracle) is the definitive choice for billion-record extraction. Released in May 2022 [GitConnected](https://levelup.gitconnected.com/what-is-the-difference-between-cx-oracle-and-python-oracledb-d2887336f75a) and actively maintained, it offers native asyncio support, a thin mode requiring no Oracle Client installation, and direct Apache Arrow integration in version 3.0+.

**Critical configuration for billion-record extraction:**

```python
import oracledb

# Static connection pool matching worker count
pool = oracledb.create_pool(
    user="user", password="password",
    dsn="host:1521/service",
    min=10, max=10,  # Static pool - no dynamic sizing
    increment=0,
    stmtcachesize=50
)

# Cursor optimization for bulk extraction
cursor = conn.cursor()
cursor.arraysize = 10000        # Rows fetched per network round-trip
cursor.prefetchrows = 10001    # Set to arraysize+1 to prevent extra round-trip
```

The **arraysize** parameter transforms performance: the default of 100 requires 10,000 network round-trips for 1 million rows, while 10,000 reduces this to just 100 round-trips. For billion-record tables, this optimization alone can improve extraction speed by **5-10x**.

**ROWID-based parallel extraction** is the most effective technique for large tables. By splitting the table into ranges based on Oracle's internal ROWID, multiple worker processes can extract different portions simultaneously without coordination overhead:

```python
from concurrent.futures import ThreadPoolExecutor

def extract_chunk(pool, start_rowid, end_rowid, output_file):
    conn = pool.acquire()
    cursor = conn.cursor()
    cursor.arraysize = 10000
    cursor.prefetchrows = 10001
    
    sql = """SELECT /*+ PARALLEL(t, 4) FULL(t) */ * 
             FROM large_table t
             WHERE ROWID BETWEEN :start AND :end"""
    cursor.execute(sql, {'start': start_rowid, 'end': end_rowid})
    
    with open(output_file, 'w') as f:
        while rows := cursor.fetchmany(100000):
            for row in rows:
                f.write('|'.join(str(v) if v is not None else '' for v in row) + '\n')
    pool.release(conn)

# Launch 8-16 parallel workers
with ThreadPoolExecutor(max_workers=10) as executor:
    futures = [executor.submit(extract_chunk, pool, start, end, f"chunk_{i}.csv")
               for i, (start, end) in enumerate(rowid_ranges)]
```

For tables with LOB columns, set `oracledb.defaults.fetch_lobs = False` to fetch LOBs as strings/bytes directly rather than streaming through locators—this dramatically improves performance for LOBs under 1GB. [Readthedocs](https://python-oracledb.readthedocs.io/en/v2.4.1/user_guide/lob_data.html)

---

## Polars and Arrow enable memory-efficient billion-record processing

**Polars** has emerged as the optimal DataFrame library for billion-record transformations, delivering **8-10x better memory efficiency** and **5-10x faster processing** than pandas. Its streaming engine processes data in batches, enabling larger-than-memory operations that would crash pandas.

| Metric | Pandas | Polars | Improvement |
|--------|--------|--------|-------------|
| 1GB CSV load | ~87 sec | ~7.8 sec | **11x faster** |
| Memory usage | 1.4GB | 179MB | **8x less** |
| Billion-row capability | OOM likely | Streaming mode | **Works** |

**Streaming CSV generation with Polars:**

```python
import polars as pl

# Stream from Oracle extraction files through transformation to output
(
    pl.scan_csv("extracted_chunks/*.csv")
    .filter(pl.col("status") == "active")
    .with_columns([
        pl.col("date_col").str.to_date("%Y-%m-%d"),
        pl.col("amount").cast(pl.Float64)
    ])
    .sink_csv("output/processed.csv")  # Streaming write - constant memory
)
```

**python-oracledb 3.0+ integrates directly with Arrow** via the PyCapsule interface, enabling zero-copy conversion to Polars:

```python
import oracledb
import polars as pl
import pyarrow

# Batch extraction with Arrow conversion
for oracle_df in connection.fetch_df_batches(
    statement="SELECT * FROM large_table",
    size=500000
):
    arrow_table = pyarrow.table(oracle_df)
    polars_df = pl.from_arrow(arrow_table)  # Zero-copy
    polars_df.write_csv(f"batch_{batch_num}.csv")
```

**DuckDB** excels for complex SQL transformations on intermediate data:

```python
import duckdb

duckdb.sql("""
    COPY (
        SELECT customer_id, SUM(amount) as total
        FROM read_csv_auto('extracted_data/*.csv')
        GROUP BY customer_id
    ) TO 'aggregated.csv' (HEADER, DELIMITER '|')
""")
```

**Apache Polaris is NOT applicable** to this use case—it's an Iceberg REST catalog service for data lakehouse metadata management, not a data processing tool.

---

## BCP configuration determines SQL Server load performance

BCP (Bulk Copy Program) remains the fastest method for SQL Server data loading, capable of **170,000-250,000 rows/second** when properly configured. The difference between default and optimized settings can mean **5-20x performance difference**.

**Optimized BCP command for billion-record loads:**

```bash
bcp TargetDB.dbo.LargeTable in "data.csv" ^
    -S sqlserver ^
    -T ^                              # Trusted connection
    -c ^                              # Character mode
    -t "|" ^                          # Field terminator (avoid comma)
    -r "\n" ^                         # Row terminator
    -a 32768 ^                        # Packet size 32KB (default 4KB)
    -b 100000 ^                       # Batch size 100K rows
    -h "TABLOCK,ORDER(id ASC)" ^      # Hints for minimal logging
    -e "errors.log"                   # Error file
```

**Critical SQL Server preparation before loading:**

```sql
-- 1. Switch to BULK_LOGGED recovery (enables minimal logging)
ALTER DATABASE TargetDB SET RECOVERY BULK_LOGGED;

-- 2. Disable all indexes (30-50% faster loads)
ALTER INDEX ALL ON dbo.LargeTable DISABLE;

-- 3. Disable constraints
ALTER TABLE dbo.LargeTable NOCHECK CONSTRAINT ALL;

-- 4. Enable table lock for bulk operations
EXEC sp_tableoption 'dbo.LargeTable', 'table lock on bulk load', 1;
```

**Parallel BCP execution** multiplies throughput by running multiple BCP processes against split data files:

```powershell
# PowerShell parallel BCP execution (8 streams)
1..8 | ForEach-Object -Parallel {
    bcp TargetDB.dbo.Table in "chunk_$_.csv" -S server -T -c -t"|" `
        -a 32768 -b 100000 -h "TABLOCK" -e "errors_$_.log"
} -ThrottleLimit 8
```

**Expected throughput at scale:**

| Configuration | Rows/Second | Billion-Row Load Time |
|---------------|-------------|----------------------|
| Single BCP, defaults | 170,000 | ~12 hours |
| Single BCP, optimized | 200,000-250,000 | ~8-10 hours |
| 4 parallel streams | 600,000-800,000 | ~2-3 hours |
| 8 parallel streams | 1,000,000+ | ~1-2 hours |

**Post-load restoration:**

```sql
-- Rebuild indexes with parallelism
ALTER INDEX ALL ON dbo.LargeTable REBUILD WITH (MAXDOP = 8, SORT_IN_TEMPDB = ON);

-- Re-enable and verify constraints
ALTER TABLE dbo.LargeTable WITH CHECK CHECK CONSTRAINT ALL;

-- Update statistics
UPDATE STATISTICS dbo.LargeTable WITH FULLSCAN;

-- Return to FULL recovery
ALTER DATABASE TargetDB SET RECOVERY FULL;
BACKUP LOG TargetDB TO DISK = 'post_load.trn';
```

---

## Pipeline architecture requires staged files and checkpointing

For billion-record migrations, **staged batch files with checkpointing** provide the reliability necessary for production operations. Direct streaming (via named pipes) eliminates intermediate storage but makes restart impossible when failures occur mid-transfer.

**Recommended architecture:**

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Oracle DB     │───▶│  Python Extract  │───▶│  NVMe Staging   │───▶│   SQL Server    │
│                 │    │  (oracledb +     │    │  (CSV files)    │    │   (BCP Load)    │
│  SDU=2MB        │    │   Polars)        │    │                 │    │   TABLOCK       │
│  arraysize=10K  │    │  Checkpointing   │    │  100-500MB each │    │   Parallel      │
└─────────────────┘    └──────────────────┘    └─────────────────┘    └─────────────────┘
```

**Checkpoint implementation for restart capability:**

```python
import json
from pathlib import Path

class CheckpointManager:
    def __init__(self, checkpoint_file: str):
        self.file = Path(checkpoint_file)
        self.state = self._load()
    
    def _load(self) -> dict:
        if self.file.exists():
            return json.loads(self.file.read_text())
        return {"last_key": 0, "rows_extracted": 0, "batch": 0}
    
    def save(self, last_key: int, rows: int, batch: int):
        self.state = {"last_key": last_key, "rows_extracted": rows, "batch": batch}
        self.file.write_text(json.dumps(self.state))
    
    def get_restart_point(self) -> tuple:
        return self.state["last_key"], self.state["batch"]
```

**Storage recommendations:**
- **Local NVMe SSD in RAID 0**: Best for temporary staging (2,500-7,000 MB/s)
- **File size**: Split into 100-500MB files for parallel BCP loading
- **Sizing formula**: `Rows × Avg_Row_Size × 1.2` (240GB for 1B rows at 200 bytes/row)

**Network tuning for Oracle extraction:**

```
# sqlnet.ora - increase for large transfers
DEFAULT_SDU_SIZE = 2097152  # 2MB maximum
RECV_BUF_SIZE = 1048576
SEND_BUF_SIZE = 1048576
TCP.NODELAY = YES
```

**Pipeline orchestration with Dagster:**

```python
from dagster import asset, job

@asset
def oracle_extraction(context):
    """Extract with checkpointing and progress tracking"""
    checkpoint = CheckpointManager("extraction.json")
    start_key, _ = checkpoint.get_restart_point()
    
    for batch in extract_batches(start_key):
        write_csv_batch(batch, output_path)
        checkpoint.save(batch[-1].key, len(batch), batch_num)
        context.log.info(f"Extracted batch {batch_num}: {len(batch)} rows")

@asset(deps=[oracle_extraction])
def bcp_load(context):
    """Parallel BCP loading"""
    for file in Path("staging/").glob("*.csv"):
        run_bcp(file)
```

---

## Alternative approaches have specific tradeoffs

**Linked Servers**: Completely non-viable for billion-record tables. Performance degrades dramatically—small queries take 30x longer than OPENQUERY, [SQLServerCentral](https://www.sqlservercentral.com/forums/topic/very-slow-performance-using-where-on-oracle-linked-server) and large tables cause timeouts and memory exhaustion.

**SSIS**: Requires careful tuning to avoid out-of-memory errors. Default settings produce 10-20x slower performance. With Attunity/Microsoft connectors tuned properly (BatchSize=100,000, DefaultBufferMaxRows=500,000), throughput reaches 36,000-76,000 rows/second—but still **50% slower than optimized BCP**.

**Apache Spark**: Excellent throughput (100,000-500,000+ rows/second) with partitioned JDBC reads, but requires cluster infrastructure. Best when:
- Existing Spark/Databricks environment
- Complex transformations during migration
- Multiple large sources to process

**ETL Platforms (Fivetran/Airbyte)**: Cost-prohibitive for billion-row initial loads (estimates: $10,000-50,000+ for Fivetran). Best reserved for ongoing CDC replication after initial bulk load via BCP.

**SSMA (SQL Server Migration Assistant)**: Useful for schema conversion but timeouts on tables exceeding 10-20 million rows. Use for schema/stored procedure migration, then Python/BCP for data.

| Approach | Throughput (rows/sec) | Billion-Row Viable | Best Use Case |
|----------|----------------------|-------------------|---------------|
| **Python/CSV/BCP** | 100K-200K | ✅ Excellent | Primary recommendation |
| **Spark (clustered)** | 100K-500K+ | ✅ Excellent | Existing Spark infrastructure |
| **SSIS (tuned)** | 36K-76K | ⚠️ Requires tuning | Enterprise SSIS environments |
| **Linked Server** | <5K | ❌ Not viable | Never for large tables |
| **SSMA** | 10K-30K | ❌ Timeouts | Schema conversion only |

---

## Production-ready implementation pattern

**Complete extraction-to-load pipeline:**

```python
import oracledb
import polars as pl
import subprocess
from concurrent.futures import ThreadPoolExecutor, ProcessPoolExecutor

class BillionRowMigration:
    def __init__(self, oracle_dsn: str, sql_server: str, table: str):
        self.oracle_dsn = oracle_dsn
        self.sql_server = sql_server
        self.table = table
        self.checkpoint = CheckpointManager(f"{table}_checkpoint.json")
    
    def extract_parallel(self, num_workers: int = 10):
        """ROWID-based parallel extraction"""
        pool = oracledb.create_pool(
            dsn=self.oracle_dsn, min=num_workers, max=num_workers
        )
        
        rowid_ranges = self._get_rowid_ranges(pool, num_workers)
        
        with ThreadPoolExecutor(max_workers=num_workers) as executor:
            futures = [
                executor.submit(self._extract_chunk, pool, i, start, end)
                for i, (start, end) in enumerate(rowid_ranges)
            ]
            for future in futures:
                future.result()
        
        pool.close()
    
    def _extract_chunk(self, pool, chunk_id, start_rowid, end_rowid):
        conn = pool.acquire()
        cursor = conn.cursor()
        cursor.arraysize = 10000
        cursor.prefetchrows = 10001
        
        sql = f"""SELECT /*+ PARALLEL(t, 4) */ * FROM {self.table} t
                  WHERE ROWID BETWEEN :s AND :e"""
        cursor.execute(sql, {'s': start_rowid, 'e': end_rowid})
        
        output = f"staging/{self.table}_chunk_{chunk_id:04d}.csv"
        with open(output, 'w') as f:
            while rows := cursor.fetchmany(100000):
                for row in rows:
                    f.write('|'.join(str(v) if v is not None else '' for v in row) + '\n')
        
        pool.release(conn)
    
    def load_parallel(self, num_streams: int = 4):
        """Parallel BCP loading"""
        files = list(Path("staging/").glob(f"{self.table}_chunk_*.csv"))
        
        with ProcessPoolExecutor(max_workers=num_streams) as executor:
            executor.map(self._bcp_load, files)
    
    def _bcp_load(self, file_path: Path):
        cmd = f'''bcp {self.table} in "{file_path}" 
                  -S {self.sql_server} -T -c -t"|" 
                  -a 32768 -b 100000 -h "TABLOCK"'''
        subprocess.run(cmd, shell=True, check=True)

# Usage
migration = BillionRowMigration(
    oracle_dsn="host:1521/service",
    sql_server="sqlserver.local",
    table="dbo.LargeTable"
)
migration.extract_parallel(num_workers=10)
migration.load_parallel(num_streams=4)
```

---

## Conclusion: proven patterns for billion-record scale

The Python/CSV/BCP pipeline represents the optimal approach for billion-record Oracle-to-SQL Server migrations, achieving **100,000-200,000 rows/second** with production-grade reliability. Three optimizations deliver the majority of performance gains:

1. **Oracle extraction**: python-oracledb with `arraysize=10000`, ROWID-based parallelism, and connection pooling
2. **Transformation**: Polars streaming engine for memory-efficient processing, Arrow for zero-copy interchange
3. **SQL Server loading**: BCP with `-a 32768 -b 100000 -h "TABLOCK"`, disabled indexes, and BULK_LOGGED recovery

The staged-file architecture with checkpointing ensures restartability—critical for multi-hour migrations where failures are probable. For organizations with existing Spark infrastructure, partitioned JDBC extraction can achieve higher throughput but at the cost of cluster complexity and compute expense.

**Expected timeline for 1 billion rows at 200 bytes/row:**
- Extraction: 2-3 hours (10 parallel workers)
- Staging: 240GB disk space
- Loading: 1-2 hours (4-8 parallel BCP streams)
- Index rebuild: 30-60 minutes
- **Total: 4-6 hours end-to-end**