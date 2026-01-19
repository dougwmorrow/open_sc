# Oracle-to-SQL Server billion-row extraction pipeline

Extracting **3 billion rows** in under 2 hours from read-only Oracle to SQL Server via CSV/BCP is achievable with the right configuration—targeting **1M+ rows/second** aggregate throughput using parallel ROWID-based extraction, optimized python-oracledb settings, and parallel BCP loading. The critical constraint of having no primary keys or indexes is addressed through Oracle's ROWID-based partitioning, which works independently of table structure. Your 8-core/68GB Linux environment can safely run **8-12 parallel extraction workers**, each streaming data with **arraysize=25000** and **256KB write buffers**, producing split CSV files for parallel BCP ingestion.

## Optimal python-oracledb configuration for billion-row extraction

The default python-oracledb settings are inadequate for large-scale extraction. The default **arraysize of 100** creates excessive round-trips—for 3 billion rows, that's 30 million network round-trips versus only **120,000 round-trips with arraysize=25000**.

**Critical configuration parameters for 68GB RAM:**

| Parameter | Recommended Value | Impact |
|-----------|-------------------|--------|
| `arraysize` | 25,000 | Reduces round-trips by 250x vs default |
| `prefetchrows` | 25,000 | Match arraysize for optimal buffering |
| `SDU` | 2,097,152 (2MB) | Maximum allowed; reduces packet overhead |
| `fetchmany batch` | 50,000 | Streaming batch size for CSV writing |
| `parallel workers` | 8-12 | 1-1.5x core count for I/O-bound work |

The **SDU (Session Data Unit)** configuration is often overlooked but critical for network throughput. Default SDU of 8KB creates significant packet overhead; the maximum 2MB setting can improve throughput by **2-4x** for bulk extractions. Configure via connection string: `hostname:1521/service_name?SDU=2097152`.

```python
import oracledb
import csv

CONFIG = {
    'arraysize': 25000,
    'prefetchrows': 25000, 
    'sdu': 2097152,
    'batch_size': 50000,
    'buffer_size': 262144  # 256KB CSV write buffer
}

def create_optimized_connection(user, password, host, port, service):
    return oracledb.connect(
        user=user,
        password=password,
        dsn=f"{host}:{port}/{service}?SDU={CONFIG['sdu']}"
    )

def extract_streaming(connection, query, output_file):
    """Memory-efficient extraction using fetchmany streaming."""
    cursor = connection.cursor()
    cursor.arraysize = CONFIG['arraysize']
    cursor.prefetchrows = CONFIG['prefetchrows']
    cursor.execute(query)
    
    columns = [col[0] for col in cursor.description]
    
    with open(output_file, 'w', newline='', buffering=CONFIG['buffer_size']) as f:
        writer = csv.writer(f, delimiter='|', quoting=csv.QUOTE_MINIMAL)
        writer.writerow(columns)
        
        while True:
            rows = cursor.fetchmany(CONFIG['batch_size'])
            if not rows:
                break
            writer.writerows(rows)
    
    cursor.close()
```

For **LOB/CLOB handling**, set `oracledb.defaults.fetch_lobs = False` to fetch LOBs as strings directly rather than using LOB locators—this eliminates per-LOB round-trips and works for LOBs under 1GB. Use **Thin mode** (pure Python, no Oracle Client required) unless you need Native Network Encryption.

## ROWID-based parallel extraction without primary keys

Since your tables lack primary keys and indexes, **ROWID-based partitioning** is the optimal parallelization strategy. ROWIDs exist for all heap tables and provide physical addressing that Oracle uses for efficient partial table scans—no indexes required.

**Method 1: DBMS_PARALLEL_EXECUTE (if accessible)**

```sql
-- Generate ROWID chunks on Oracle side
BEGIN
    DBMS_PARALLEL_EXECUTE.CREATE_TASK(task_name => 'EXTRACT_BIG_TABLE');
    DBMS_PARALLEL_EXECUTE.CREATE_CHUNKS_BY_ROWID(
        task_name   => 'EXTRACT_BIG_TABLE',
        table_owner => 'SCHEMA',
        table_name  => 'BIG_TABLE',
        by_row      => FALSE,  -- Chunk by blocks (faster generation)
        chunk_size  => 50000   -- Blocks per chunk
    );
END;

-- Query chunk boundaries for Python workers
SELECT chunk_id, start_rowid, end_rowid
FROM user_parallel_execute_chunks
WHERE task_name = 'EXTRACT_BIG_TABLE'
ORDER BY chunk_id;
```

**Method 2: Date-based partitioning (simpler, uses your date columns)**

For tables with reliable date columns, partition extraction by date ranges—this avoids the ROWID complexity while still achieving parallelism:

```python
from datetime import date, timedelta

def generate_date_chunks(table, date_col, start, end, num_workers):
    """Generate date-range queries for parallel extraction."""
    total_days = (end - start).days
    days_per_chunk = total_days // num_workers
    
    queries = []
    for i in range(num_workers):
        chunk_start = start + timedelta(days=i * days_per_chunk)
        chunk_end = end if i == num_workers - 1 else start + timedelta(days=(i+1) * days_per_chunk)
        
        query = f"""
            SELECT /*+ PARALLEL(t, 4) FULL(t) */ *
            FROM {table} t
            WHERE {date_col} >= DATE '{chunk_start}'
              AND {date_col} < DATE '{chunk_end}'
        """
        queries.append((query, f"output_chunk_{i:03d}.csv"))
    
    return queries
```

**Use multiprocessing, not threading.** Python's GIL limits threading benefits; multiprocessing provides true parallelism. Each worker needs its own Oracle connection—connections cannot be shared across processes.

```python
from concurrent.futures import ProcessPoolExecutor, as_completed
import oracledb
import csv
import os

def worker_extract(args):
    """Worker function - creates own connection, extracts to CSV."""
    query, output_file, db_config = args
    
    conn = oracledb.connect(**db_config)
    cursor = conn.cursor()
    cursor.arraysize = 25000
    cursor.prefetchrows = 25000
    
    cursor.execute(query)
    columns = [col[0] for col in cursor.description]
    
    row_count = 0
    with open(output_file, 'w', newline='', buffering=262144) as f:
        writer = csv.writer(f, delimiter='|')
        writer.writerow(columns)
        
        while True:
            rows = cursor.fetchmany(50000)
            if not rows:
                break
            writer.writerows(rows)
            row_count += len(rows)
    
    cursor.close()
    conn.close()
    return output_file, row_count

def run_parallel_extraction(queries, db_config, max_workers=12):
    """Execute parallel extraction across multiple processes."""
    tasks = [(q, f, db_config) for q, f in queries]
    
    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(worker_extract, t): t for t in tasks}
        
        for future in as_completed(futures):
            output_file, rows = future.result()
            print(f"Completed: {output_file} - {rows:,} rows")
```

**Optimal chunk sizing for 3 billion rows:** Use **25-50 million rows per chunk** (60-120 total chunks), allowing load balancing across workers while minimizing coordination overhead. For 8 cores with I/O-bound work, **12 workers** is optimal.

## Incremental extraction using timestamp columns

For daily incremental loads of 1-3 million records, timestamp-based extraction with **flashback consistency** is the reliable approach given your read-only constraints.

**Use AS OF SCN for transactional consistency:**

```python
from datetime import datetime, timedelta
import json
from pathlib import Path

class IncrementalExtractor:
    def __init__(self, connection, watermark_file):
        self.conn = connection
        self.watermark_file = Path(watermark_file)
        self.overlap_minutes = 5  # Catch edge-case transactions
    
    def get_current_scn(self):
        cursor = self.conn.cursor()
        cursor.execute("SELECT CURRENT_SCN FROM V$DATABASE")
        return cursor.fetchone()[0]
    
    def extract_incremental(self, table_name, date_column, output_file):
        # Capture extraction snapshot point FIRST
        extraction_scn = self.get_current_scn()
        
        # Load last watermark
        watermark = self._load_watermark(table_name)
        last_timestamp = watermark.get('timestamp')
        
        if last_timestamp:
            # Apply overlap window for edge cases
            overlap_time = (
                datetime.fromisoformat(last_timestamp) - 
                timedelta(minutes=self.overlap_minutes)
            ).strftime('%Y-%m-%d %H:%M:%S')
            
            query = f"""
                SELECT /*+ PARALLEL(t, 4) */ t.*
                FROM {table_name} AS OF SCN {extraction_scn} t
                WHERE {date_column} >= TO_TIMESTAMP('{overlap_time}', 'YYYY-MM-DD HH24:MI:SS')
            """
        else:
            # Initial full load
            query = f"""
                SELECT /*+ PARALLEL(t, 4) */ t.*
                FROM {table_name} AS OF SCN {extraction_scn} t
            """
        
        row_count = self._extract_to_csv(query, output_file)
        
        # Save watermark ONLY after successful extraction
        self._save_watermark(table_name, extraction_scn)
        return row_count
```

**ORA_ROWSCN limitations are significant.** Without ROWDEPENDENCIES (which requires table recreation), ORA_ROWSCN operates at block level—when any row in a block changes, ALL rows in that block appear changed. This creates **massive false positives** and is generally unsuitable for your read-only scenario.

**Delete detection is the hardest problem.** Without supplemental logging or triggers, your options are:

- **Periodic full comparison**: Extract distinct key-equivalent columns, hash rows, compare with previous extraction
- **Soft delete patterns**: If application uses `is_deleted` or `status='DELETED'` columns, query these
- **Accept limitation**: Run weekly full reconciliation; tolerate some orphaned records on target

For **300M+ row tables**, delete detection via full comparison is expensive. Consider whether the business can tolerate eventual consistency via periodic full refreshes.

## CSV generation and BCP loading optimization

**CSV write buffering is critical.** Default Python buffer of 8KB is inadequate; use **256KB buffers** for high-throughput writes:

```python
# Optimal CSV writing pattern
with open(output_file, 'w', newline='', buffering=262144, encoding='utf-8') as f:
    writer = csv.writer(f, delimiter='|', quoting=csv.QUOTE_MINIMAL)
    writer.writerows(batch)  # writerows() is faster than individual writerow()
```

**Use pipe delimiter (`|`) instead of comma**—it's rare in data and avoids escaping complications. For row terminator, use `\n` (LF)—works on both Linux and Windows.

**File splitting strategy for parallel BCP:** Split output during extraction into **500MB-1GB files** (8-16 files for a 3B row table). Round-robin distribution across files ensures even sizing:

```python
from itertools import cycle

def split_extraction(cursor, base_filename, num_files=8):
    files = [open(f"{base_filename}_{i:03d}.csv", 'w', buffering=262144) 
             for i in range(num_files)]
    writers = [csv.writer(f, delimiter='|') for f in files]
    file_cycle = cycle(range(num_files))
    
    for row in cursor:
        writers[next(file_cycle)].writerow(row)
    
    for f in files:
        f.close()
```

**BCP does NOT support compressed input directly**—decompress before loading or use named pipes. For local processing, **skip compression**; for network transfer, use **LZ4** (500MB/s compression, multi-GB/s decompression).

**Optimal BCP command for maximum throughput:**

```bash
bcp database.dbo.target_table in /data/file.csv \
    -S sqlserver.example.com \
    -d database_name \
    -U username -P "$PASSWORD" \
    -c \
    -C 65001 \
    -t "|" \
    -r "\n" \
    -b 500000 \
    -a 32768 \
    -h "TABLOCK" \
    -k \
    -e error.log
```

Key settings: **batch size 500,000 rows** (`-b 500000`), **packet size 32KB** (`-a 32768`), **TABLOCK hint** for minimal logging. Pre-requisites for minimal logging: BULK_LOGGED recovery model, heap table or empty clustered table, TABLOCK specified.

**Parallel BCP loading:**

```bash
#!/bin/bash
MAX_PARALLEL=8

for file in /data/csv/*.csv; do
    ((i=i%MAX_PARALLEL)); ((i++==0)) && wait
    bcp database.dbo.table in "$file" \
        -S server -U user -P pass \
        -c -C 65001 -t "|" -r "\n" \
        -b 500000 -a 32768 -h "TABLOCK" -k &
done
wait
```

## Linux RHEL and network tuning

Create `/etc/sysctl.d/99-oracle-extraction.conf`:

```bash
# Network tuning for high-throughput Oracle extraction
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
net.core.netdev_max_backlog = 30000
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_slow_start_after_idle = 0

# Memory tuning for 68GB RAM
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
```

**Disable Transparent Huge Pages** for database workloads:
```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

**XFS is recommended** for the extraction output volume with mount options: `noatime,nodiratime,logbufs=8`. For NVMe/SSDs, use I/O scheduler `none` or `mq-deadline`.

**Oracle client-side sqlnet.ora:**
```
DEFAULT_SDU_SIZE = 2097152
SQLNET.RECV_BUF_SIZE = 67108864
SQLNET.SEND_BUF_SIZE = 67108864
TCP.NODELAY = YES
```

## Checkpoint and recovery for multi-hour extractions

For resumable extractions, use **SQLite with WAL mode** for checkpoint persistence:

```python
import sqlite3
from datetime import datetime

class CheckpointManager:
    def __init__(self, db_path="extraction_state.db"):
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self._init_schema()
    
    def _init_schema(self):
        self.conn.executescript("""
            CREATE TABLE IF NOT EXISTS chunk_status (
                job_id TEXT,
                chunk_id INTEGER,
                start_rowid TEXT,
                end_rowid TEXT,
                status TEXT DEFAULT 'PENDING',
                rows_extracted INTEGER DEFAULT 0,
                output_file TEXT,
                error_message TEXT,
                retry_count INTEGER DEFAULT 0,
                PRIMARY KEY (job_id, chunk_id)
            );
            
            CREATE TABLE IF NOT EXISTS watermarks (
                table_name TEXT PRIMARY KEY,
                last_scn INTEGER,
                last_timestamp TEXT,
                updated_at TEXT
            );
        """)
    
    def mark_chunk_started(self, job_id, chunk_id):
        self.conn.execute("""
            UPDATE chunk_status SET status='PROCESSING'
            WHERE job_id=? AND chunk_id=?
        """, (job_id, chunk_id))
        self.conn.commit()
    
    def mark_chunk_completed(self, job_id, chunk_id, rows, output_file):
        self.conn.execute("""
            UPDATE chunk_status 
            SET status='COMPLETED', rows_extracted=?, output_file=?
            WHERE job_id=? AND chunk_id=?
        """, (rows, output_file, job_id, chunk_id))
        self.conn.commit()
    
    def get_pending_chunks(self, job_id, max_retries=3):
        cursor = self.conn.execute("""
            SELECT chunk_id, start_rowid, end_rowid
            FROM chunk_status
            WHERE job_id=? AND (status='PENDING' OR (status='FAILED' AND retry_count < ?))
        """, (job_id, max_retries))
        return cursor.fetchall()
```

**Atomic file writes prevent corruption:** Write to `.tmp` file, then `os.rename()` to final name. On same filesystem, rename is atomic.

**Signal handling for graceful shutdown:**

```python
import signal
from multiprocessing import Event

class GracefulShutdown:
    def __init__(self):
        self.stop_event = Event()
        signal.signal(signal.SIGTERM, self._handler)
        signal.signal(signal.SIGINT, self._handler)
    
    def _handler(self, signum, frame):
        self.stop_event.set()
    
    def should_stop(self):
        return self.stop_event.is_set()
```

## ConnectorX as an alternative for smaller datasets

**ConnectorX** offers significant performance advantages—**3x faster than pandas, 3x less memory**—through zero-copy Arrow-based processing. However, it has critical limitations for your scenario:

- **No streaming mode**: Entire result set must fit in memory
- **Partition column must be numerical non-NULL**: Cannot partition on dates directly
- **No LOB support**: Fails on CLOB/BLOB columns
- **Memory bound**: For 68GB RAM, practical limit is ~40-50GB datasets

**Use ConnectorX for tables under 40GB** that fit in memory and lack LOBs. For billion-row tables exceeding memory, **python-oracledb with streaming is required**.

```python
import connectorx as cx
import pyarrow.csv as csv

# ConnectorX with manual query partitioning (for tables < 40GB)
conn = 'oracle://user:pass@host:1521/service'
queries = [f"SELECT * FROM table WHERE date_col >= DATE '{start}' AND date_col < DATE '{end}'" 
           for start, end in date_ranges]

table = cx.read_sql(conn, queries, return_type="arrow")
csv.write_csv(table, 'output.csv')
```

## Realistic performance expectations

| Configuration | Throughput | Time for 3B Rows |
|--------------|-----------|------------------|
| Single-threaded, default settings | 50K-80K rows/sec | 10-17 hours |
| Single-threaded, optimized settings | 100K-200K rows/sec | 4-8 hours |
| 8-12 parallel workers | 600K-1.2M rows/sec | **40-80 minutes** |
| BCP import (8 parallel, TABLOCK) | 500K-1M+ rows/sec | 50-100 minutes |

**Your 2-hour extraction target is achievable** with 8-12 parallel workers using ROWID or date-based partitioning. The 5-hour window provides comfortable margin for the complete pipeline: extraction (60-90 min), optional compression/transfer, BCP loading (60-90 min).

**Memory utilization with 68GB RAM:**
- Per worker: ~100-200MB (25000 arraysize × row width × buffer overhead)
- 12 workers: ~1.5-2.5GB total for Oracle buffers
- CSV write buffers: ~3MB per worker
- Ample headroom for OS, Python overhead, and file system cache

## Conclusion

The key to achieving your 2-hour extraction goal lies in three parallel strategies working together: **ROWID or date-based partitioning** eliminates the primary key dependency, **optimized python-oracledb settings** (arraysize=25000, SDU=2MB, 256KB buffers) maximize per-connection throughput, and **12 parallel workers** with checkpoint/recovery enables both speed and reliability. For incremental loads, timestamp-based extraction with AS OF SCN consistency handles the daily 1-3M record updates, though delete detection requires accepting either periodic full comparisons or eventual consistency. The infrastructure foundation—BBR congestion control, XFS with proper mount options, and correctly sized TCP buffers—ensures the network and disk subsystems don't become bottlenecks. Focus initial optimization efforts on the largest tables first; the 200 smaller tables (100-300M rows each) will extract quickly once the billion-row patterns are proven.
