# Taming runaway SQL Agent jobs: a complete diagnostic and prevention toolkit

**SQL Agent jobs that intermittently balloon from 4 hours to 21+ hours — and then fail because a job-related value goes NULL at midnight — are a solvable problem with the right combination of diagnostics, monitoring, and prevention.** The root cause typically involves a confluence of query plan regression (often parameter sniffing), stale statistics, or blocking, compounded by SQL Agent's well-documented fragility around date boundaries. This guide provides every T-SQL script and configuration needed to diagnose, monitor, and prevent this exact scenario.

---

## Diagnosing slow queries inside Agent jobs with DMVs

The first step when an Agent job runs long is identifying *which specific query* within the job step is consuming time. SQL Agent job sessions identify themselves through the `program_name` column, which follows the pattern `SQLAgent - TSQL JobStep (Job 0x<hex_job_id> : Step <N>)`. [sqlskills +2](https://www.sqlskills.com/blogs/jonathan/tracking-extended-events-for-a-sql-agent-job/) This makes them filterable across every DMV.

**Find all currently running Agent job sessions and their active queries:**

```sql
SELECT
    s.session_id,
    s.program_name,
    r.status,
    r.command,
    r.wait_type,
    r.wait_time,
    r.blocking_session_id,
    r.cpu_time,
    r.total_elapsed_time / 1000.0 AS elapsed_sec,
    r.reads,
    r.writes,
    r.logical_reads,
    DB_NAME(r.database_id) AS database_name,
    t.text AS sql_text,
    qp.query_plan
FROM sys.dm_exec_sessions s
INNER JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE s.program_name LIKE 'SQLAgent - TSQL JobStep%'
ORDER BY r.total_elapsed_time DESC;
```

This returns the exact SQL statement executing right now, its execution plan, what it's waiting on, and whether it's blocked. [Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql?view=sql-server-ver17) The **`wait_type`** column is the single most diagnostic piece of information [DEV Community](https://dev.to/shiviyer/mastering-performance-troubleshooting-with-sysdmexecrequests-in-azure-sql-3f0j) — `LCK_M_X` means it's blocked by another session, `PAGEIOLATCH_SH` means disk I/O pressure, `CXPACKET` indicates parallelism waits, and `SOS_SCHEDULER_YIELD` signals CPU saturation.

**Find historically expensive queries from the plan cache:**

```sql
SELECT TOP 25
    qs.total_elapsed_time,
    qs.execution_count,
    qs.total_elapsed_time / NULLIF(qs.execution_count, 0) AS avg_elapsed_time,
    qs.total_worker_time AS total_cpu_time,
    qs.total_logical_reads,
    qs.total_physical_reads,
    qs.min_elapsed_time,
    qs.max_elapsed_time,
    SUBSTRING(t.text,
        (qs.statement_start_offset / 2) + 1,
        (CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(t.text)
            ELSE qs.statement_end_offset
         END - qs.statement_start_offset) / 2 + 1
    ) AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
ORDER BY qs.total_elapsed_time DESC;
```

**Detect parameter sniffing** — the most common cause of intermittent slowdowns — by finding queries where maximum execution time dwarfs the average:

```sql
SELECT
    q.query_hash,
    q.plan_count,
    q.execution_count,
    q.avg_elapsed_time,
    q.min_elapsed_time,
    q.max_elapsed_time,
    q.max_to_avg_ratio,
    t.text AS sample_query_text
FROM (
    SELECT
        qs.query_hash,
        COUNT(DISTINCT qs.plan_handle) AS plan_count,
        SUM(qs.execution_count) AS execution_count,
        SUM(qs.total_elapsed_time) / NULLIF(SUM(qs.execution_count), 0) AS avg_elapsed_time,
        MIN(qs.min_elapsed_time) AS min_elapsed_time,
        MAX(qs.max_elapsed_time) AS max_elapsed_time,
        CAST(MAX(qs.max_elapsed_time) AS FLOAT)
            / NULLIF(SUM(qs.total_elapsed_time) * 1.0 / NULLIF(SUM(qs.execution_count), 0), 0)
            AS max_to_avg_ratio,
        MIN(qs.sql_handle) AS sample_sql_handle
    FROM sys.dm_exec_query_stats qs
    GROUP BY qs.query_hash
    HAVING SUM(qs.execution_count) >= 2
) q
CROSS APPLY sys.dm_exec_sql_text(q.sample_sql_handle) t
WHERE q.max_to_avg_ratio > 10
ORDER BY q.max_to_avg_ratio DESC;
```

Queries with **`max_to_avg_ratio` exceeding 10** and **`plan_count` greater than 1** are strong parameter sniffing candidates. Solutions include adding `OPTION(RECOMPILE)` to the offending statement, using `OPTION(OPTIMIZE FOR UNKNOWN)`, or forcing a known-good plan through Query Store. [DB Cloud TECH](https://mostafaelmasry.com/2017/12/19/query-store-for-solving-query-performance-regressions/) [IDERA](https://www.idera.com/blogs/sql-server-parameter-sniffing/)

### Wait statistics reveal the bottleneck pattern

```sql
WITH WaitStats AS (
    SELECT wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP',
        'BROKER_TO_FLUSH','BROKER_TRANSMITTER','CHECKPOINT_QUEUE','CHKPT',
        'CLR_AUTO_EVENT','CLR_MANUAL_EVENT','CLR_SEMAPHORE','DIRTY_PAGE_POLL',
        'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
        'HADR_CLUSAPI_CALL','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'HADR_LOGCAPTURE_WAIT','HADR_NOTIFICATION_DEQUEUE','HADR_TIMER_TASK',
        'HADR_WORK_QUEUE','KSOURCE_WAKEUP','LAZYWRITER_SLEEP','LOGMGR_QUEUE',
        'ONDEMAND_TASK_QUEUE','PREEMPTIVE_XE_GETTARGETSTATE',
        'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_ASYNC_QUEUE',
        'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP','QDS_SHUTDOWN_QUEUE',
        'REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE','SERVER_IDLE_CHECK',
        'SLEEP_BPOOL_FLUSH','SLEEP_DBSTARTUP','SLEEP_DCOMSTARTUP',
        'SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED',
        'SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK','SLEEP_TASK','SLEEP_TEMPDBSTARTUP',
        'SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH',
        'SQLTRACE_INCREMENTAL_FLUSH_SLEEP','SQLTRACE_WAIT_ENTRIES',
        'WAIT_FOR_RESULTS','WAITFOR','WAITFOR_TASKSHUTDOWN',
        'XE_BUFFERMGR_ALLPROCESSED_EVENT','XE_DISPATCHER_JOIN',
        'XE_DISPATCHER_WAIT','XE_TIMER_EVENT'
    ) AND wait_time_ms > 0
),
Totals AS (SELECT SUM(wait_time_ms) AS total_wait_time_ms FROM WaitStats)
SELECT
    w.wait_type,
    CAST(w.wait_time_ms / 1000.0 AS DECIMAL(18,2)) AS wait_time_s,
    w.waiting_tasks_count,
    CAST(100.0 * w.wait_time_ms / t.total_wait_time_ms AS DECIMAL(5,2)) AS pct_of_total,
    CAST(SUM(w.wait_time_ms) OVER (ORDER BY w.wait_time_ms DESC)
         * 100.0 / t.total_wait_time_ms AS DECIMAL(5,2)) AS running_pct
FROM WaitStats w CROSS JOIN Totals t
ORDER BY w.wait_time_ms DESC;
```

The top wait types tell the story: **`CXPACKET`/`CXCONSUMER`** means parallelism overhead, **`LCK_M_*`** waits indicate lock contention, **`PAGEIOLATCH_SH`** points to insufficient memory or slow disks, [Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql?view=sql-server-ver17) **`WRITELOG`** signals transaction log bottlenecks, and **`RESOURCE_SEMAPHORE`** means queries cannot get memory grants.

### Blocking chain detection finds head blockers

```sql
;WITH BlockingChain AS (
    SELECT s.session_id, NULL AS blocking_session_id, 0 AS nest_level,
        CAST(CAST(s.session_id AS VARCHAR(10)) AS VARCHAR(4000)) AS chain_path
    FROM sys.dm_exec_sessions s
    WHERE s.session_id IN (
        SELECT DISTINCT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0
    ) AND s.session_id NOT IN (
        SELECT session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0
    )
    UNION ALL
    SELECT r.session_id, r.blocking_session_id, bc.nest_level + 1,
        CAST(bc.chain_path + ' -> ' + CAST(r.session_id AS VARCHAR(10)) AS VARCHAR(4000))
    FROM sys.dm_exec_requests r
    INNER JOIN BlockingChain bc ON r.blocking_session_id = bc.session_id
    WHERE r.blocking_session_id <> 0 AND bc.nest_level < 20
)
SELECT bc.chain_path, bc.session_id, bc.blocking_session_id AS blocked_by,
    r.wait_type, r.wait_time AS wait_ms, s.program_name,
    blocked_txt.text AS blocked_sql, blocker_txt.text AS blocker_sql
FROM BlockingChain bc
INNER JOIN sys.dm_exec_sessions s ON bc.session_id = s.session_id
LEFT JOIN sys.dm_exec_requests r ON bc.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) blocked_txt
OUTER APPLY sys.dm_exec_sql_text(
    (SELECT TOP 1 r2.sql_handle FROM sys.dm_exec_requests r2
     WHERE r2.session_id = bc.blocking_session_id)
) blocker_txt
ORDER BY bc.chain_path;
```

---

## Extended Events capture long-running queries automatically

Extended Events is the lightweight, production-safe replacement for SQL Profiler. [SQL Shack](https://www.sqlshack.com/using-sql-server-extended-events-to-monitor-query-performance/) **Duration in Extended Events is measured in microseconds** — 30 seconds equals 30,000,000.

```sql
CREATE EVENT SESSION [LongRunningQueries] ON SERVER

ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.session_id,
            sqlserver.client_app_name, sqlserver.username,
            sqlserver.query_hash, sqlserver.query_plan_hash)
    WHERE ([duration] > 30000000)  -- 30 seconds
),

ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.session_id,
            sqlserver.client_app_name, sqlserver.username,
            sqlserver.query_hash, sqlserver.query_plan_hash)
    WHERE ([duration] > 30000000)
),

ADD EVENT sqlserver.sp_statement_completed (
    SET collect_object_name = (1)
    ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.session_id,
            sqlserver.client_app_name, sqlserver.username,
            sqlserver.query_hash, sqlserver.query_plan_hash)
    WHERE ([duration] > 30000000)
)

ADD TARGET package0.event_file (
    SET filename = N'C:\XELogs\LongRunningQueries.xel',
        max_file_size = 50,
        max_rollover_files = 10
)

WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = ON
);
GO

ALTER EVENT SESSION [LongRunningQueries] ON SERVER STATE = START;
```

To filter specifically for SQL Agent jobs, add `AND [sqlserver].[client_app_name] LIKE N'SQLAgent%'` to each WHERE clause. [SQLskills](https://www.sqlskills.com/blogs/jonathan/tracking-extended-events-for-a-sql-agent-job/) **Always use the file target in production** [SQLyard](https://sqlyard.com/2025/08/27/sql-profiler-is-deprecated-use-extended-events-instead/) — the ring_buffer target has a 4 MB XML output limit [Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/targets-for-extended-events-in-sql-server?view=sql-server-ver17) and silently truncates data, making it unsuitable for anything beyond quick spot-checks.

**Query the captured data:**

```sql
SELECT
    event_data.value('(event/@name)[1]', 'VARCHAR(50)') AS event_name,
    event_data.value('(event/@timestamp)[1]', 'DATETIMEOFFSET') AS event_timestamp,
    event_data.value('(event/data[@name="duration"]/value)[1]', 'BIGINT') / 1000000 AS duration_seconds,
    event_data.value('(event/data[@name="cpu_time"]/value)[1]', 'BIGINT') / 1000 AS cpu_time_ms,
    event_data.value('(event/data[@name="logical_reads"]/value)[1]', 'BIGINT') AS logical_reads,
    event_data.value('(event/action[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)') AS sql_text,
    event_data.value('(event/action[@name="database_name"]/value)[1]', 'NVARCHAR(128)') AS database_name,
    event_data.value('(event/action[@name="client_app_name"]/value)[1]', 'NVARCHAR(256)') AS app_name
FROM (
    SELECT CAST(event_data AS XML) AS event_data
    FROM sys.fn_xe_file_target_read_file(
        'C:\XELogs\LongRunningQueries*.xel', NULL, NULL, NULL)
) AS xevents
ORDER BY duration_seconds DESC;
```

---

## Query Store tracks plan regression over time

Query Store retains execution plans and their performance statistics across server restarts, making it the primary tool for catching intermittent slowdowns caused by plan changes. [Rackspace +2](https://www.rackspace.com/blog/microsoft-sql-server-query-store) **On SQL Server 2022+, Query Store is enabled by default for new databases.**

```sql
ALTER DATABASE [YourDatabaseName]
SET QUERY_STORE = ON (
    OPERATION_MODE = READ_WRITE,
    MAX_STORAGE_SIZE_MB = 1024,
    INTERVAL_LENGTH_MINUTES = 30,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    QUERY_CAPTURE_MODE = AUTO,
    MAX_PLANS_PER_QUERY = 200,
    WAIT_STATS_CAPTURE_MODE = ON
);
```

**Find regressed queries** — those whose recent performance is significantly worse than historical:

```sql
;WITH RecentStats AS (
    SELECT q.query_id, AVG(rs.avg_duration) AS recent_avg_duration
    FROM sys.query_store_query q
    JOIN sys.query_store_plan p ON q.query_id = p.query_id
    JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
    JOIN sys.query_store_runtime_stats_interval rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())
    GROUP BY q.query_id
),
HistoricalStats AS (
    SELECT q.query_id, AVG(rs.avg_duration) AS historical_avg_duration
    FROM sys.query_store_query q
    JOIN sys.query_store_plan p ON q.query_id = p.query_id
    JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
    JOIN sys.query_store_runtime_stats_interval rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(DAY, -7, GETUTCDATE())
      AND rsi.start_time < DATEADD(HOUR, -2, GETUTCDATE())
    GROUP BY q.query_id
)
SELECT TOP 25
    r.query_id, qt.query_sql_text,
    h.historical_avg_duration / 1000000.0 AS hist_avg_sec,
    r.recent_avg_duration / 1000000.0 AS recent_avg_sec,
    (r.recent_avg_duration - h.historical_avg_duration)
        / h.historical_avg_duration * 100.0 AS pct_regression
FROM RecentStats r
JOIN HistoricalStats h ON r.query_id = h.query_id
JOIN sys.query_store_query q ON r.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE r.recent_avg_duration > h.historical_avg_duration * 2
  AND h.historical_avg_duration > 0
ORDER BY pct_regression DESC;
```

**Find queries with multiple plans** (parameter sniffing indicator) and the performance variation between them:

```sql
SELECT q.query_id, qt.query_sql_text,
    COUNT(DISTINCT p.plan_id) AS plan_count,
    MIN(rs.avg_duration) / 1000000.0 AS fastest_plan_avg_sec,
    MAX(rs.avg_duration) / 1000000.0 AS slowest_plan_avg_sec,
    MAX(rs.avg_duration) / NULLIF(MIN(rs.avg_duration), 0) AS slowdown_factor
FROM sys.query_store_query_text qt
JOIN sys.query_store_query q ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
GROUP BY q.query_id, qt.query_sql_text
HAVING COUNT(DISTINCT p.plan_id) > 1
ORDER BY slowdown_factor DESC;
```

Once you identify a bad plan, **force the known-good one**: `EXEC sp_query_store_force_plan @query_id = 42, @plan_id = 7;` [Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)

---

## The midnight date-rollover problem and how to fix it

Microsoft documented a confirmed bug in **KB2598903** where SQL Agent jobs scheduled to run across midnight randomly stop executing after the date boundary and don't resume until the next scheduled day. Though patched for SQL Server 2005–2008 R2, [Microsoft Support](https://support.microsoft.com/en-us/topic/kb2598903-fix-sql-server-agent-job-randomly-stops-when-you-schedule-the-job-to-run-past-midnight-on-specific-days-in-sql-server-2005-in-sql-server-2008-or-in-sql-server-2008-r2-65c8f54f-d88d-048b-50cf-76418601fc18) the underlying architectural fragility persists in later versions through several mechanisms.

**The `sysjobactivity` session correlation problem** is the most common cause of NULL job-related values. Every time SQL Agent starts, it creates a new `session_id` in `msdb.dbo.syssessions`. [SQLServerCentral](https://www.sqlservercentral.com/forums/topic/get-sql-server-ageng-job-id-from-within-a-running-job) If SQL Agent restarts at or near midnight — due to failover, maintenance, or service interruption — any running job's activity record becomes orphaned. The old session's row retains `start_execution_date` populated with `stop_execution_date` as NULL, making the job appear perpetually running. **Any monitoring query that doesn't filter by `MAX(session_id)` will produce phantom results or NULL job_id values.**

```sql
-- CORRECT way to find currently running jobs (always filter by current session)
SELECT j.name AS job_name, ja.start_execution_date,
    DATEDIFF(MINUTE, ja.start_execution_date, GETDATE()) AS duration_minutes,
    ISNULL(ja.last_executed_step_id, 0) + 1 AS current_step_id,
    js.step_name
FROM msdb.dbo.sysjobactivity ja
INNER JOIN msdb.dbo.sysjobs j ON j.job_id = ja.job_id
LEFT JOIN msdb.dbo.sysjobsteps js
    ON ja.job_id = js.job_id
    AND ISNULL(ja.last_executed_step_id, 0) + 1 = js.step_id
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
    AND ja.start_execution_date IS NOT NULL
    AND ja.stop_execution_date IS NULL
ORDER BY duration_minutes DESC;
```

**Token replacement is another midnight trap.** The `$(ESCAPE_SQUOTE(DATE))` and `$(ESCAPE_SQUOTE(TIME))` tokens resolve at *step execution time*, not job start time. If step 1 runs before midnight and step 5 runs after, they'll see different dates. The `$(ESCAPE_SQUOTE(STRTDT))` token captures the *job start date* and remains consistent across all steps — always prefer it. [Flylib](https://flylib.com/books/en/1.514.1.49/1/)

```sql
-- Step 1: Capture the business date at job start, use in all subsequent steps
IF OBJECT_ID('tempdb..##JobContext') IS NOT NULL DROP TABLE ##JobContext;
CREATE TABLE ##JobContext (
    JobStartDate DATE,
    JobStartDateTime DATETIME,
    BusinessDate DATE
);
INSERT INTO ##JobContext VALUES (
    CAST(GETDATE() AS DATE),
    GETDATE(),
    CASE WHEN DATEPART(HOUR, GETDATE()) < 6
         THEN DATEADD(DAY, -1, CAST(GETDATE() AS DATE))
         ELSE CAST(GETDATE() AS DATE)
    END
);
```

**SQL Agent has no built-in step-level timeout** for on-premises installations (the `step_timeout_seconds` parameter exists only in Azure Elastic Jobs). [GitHub](https://github.com/MicrosoftDocs/sql-docs/blob/live/docs/relational-databases/system-stored-procedures/sp-add-jobstep-elastic-jobs-transact-sql.md) To prevent runaway executions, implement a watchdog job:

```sql
CREATE PROCEDURE dbo.usp_WatchdogKillLongRunningJobs
    @MaxRunMinutes INT = 360,
    @KillJob BIT = 0,
    @ExcludeJobs NVARCHAR(MAX) = NULL,
    @MailProfile VARCHAR(128) = 'DefaultMailProfile',
    @MailRecipients VARCHAR(MAX) = 'dba@company.com'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LongRunningJobs TABLE (JobName SYSNAME, StartTime DATETIME, DurationMinutes INT);

    INSERT INTO @LongRunningJobs
    SELECT sj.name, sja.start_execution_date,
        DATEDIFF(MINUTE, sja.start_execution_date, GETDATE())
    FROM msdb.dbo.sysjobs sj
    JOIN msdb.dbo.sysjobactivity sja ON sj.job_id = sja.job_id
    WHERE sja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
        AND sja.start_execution_date IS NOT NULL
        AND sja.stop_execution_date IS NULL
        AND DATEDIFF(MINUTE, sja.start_execution_date, GETDATE()) > @MaxRunMinutes
        AND sj.name NOT IN (
            SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@ExcludeJobs, ''), ',')
            WHERE value <> ''
        )
        AND sj.name <> 'WatchdogMonitor';

    IF EXISTS (SELECT 1 FROM @LongRunningJobs)
    BEGIN
        DECLARE @JobName SYSNAME, @Duration INT, @Subject NVARCHAR(255), @Body NVARCHAR(MAX);
        DECLARE job_cursor CURSOR FOR SELECT JobName, DurationMinutes FROM @LongRunningJobs;
        OPEN job_cursor;
        FETCH NEXT FROM job_cursor INTO @JobName, @Duration;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @KillJob = 1
            BEGIN
                EXEC msdb.dbo.sp_stop_job @job_name = @JobName;
                SET @Subject = N'KILLED: Job [' + @JobName + '] exceeded '
                    + CAST(@MaxRunMinutes AS VARCHAR) + ' min on ' + @@SERVERNAME;
            END
            ELSE
                SET @Subject = N'WARNING: Job [' + @JobName + '] running '
                    + CAST(@Duration AS VARCHAR) + ' min on ' + @@SERVERNAME;

            SET @Body = N'Job: ' + @JobName + CHAR(13) + CHAR(10)
                + N'Duration: ' + CAST(@Duration AS VARCHAR) + ' minutes' + CHAR(13) + CHAR(10)
                + N'Action: ' + CASE WHEN @KillJob = 1 THEN 'Stopped' ELSE 'Alert only' END;

            EXEC msdb.dbo.sp_send_dbmail @profile_name = @MailProfile,
                @recipients = @MailRecipients, @subject = @Subject, @body = @Body;

            FETCH NEXT FROM job_cursor INTO @JobName, @Duration;
        END
        CLOSE job_cursor; DEALLOCATE job_cursor;
    END
END;
```

Schedule this watchdog every **15 minutes** to catch runaway jobs before they reach the 21-hour mark.

---

## Building a proactive monitoring ecosystem

Reactive troubleshooting catches problems after users complain. A proactive system catches them before impact. Here are the key components.

### Automated email alerts for long-running queries

```sql
CREATE TABLE dbo.LongRunningQueryAlerts (
    alert_id INT IDENTITY(1,1) PRIMARY KEY,
    session_id SMALLINT NOT NULL,
    sql_text_hash VARBINARY(64) NOT NULL,
    database_name NVARCHAR(128) NULL,
    elapsed_time_sec INT NOT NULL,
    wait_type NVARCHAR(60) NULL,
    blocking_session_id SMALLINT NULL,
    sql_text NVARCHAR(MAX) NULL,
    alert_time DATETIME NOT NULL DEFAULT GETDATE(),
    INDEX IX_AlertTime_Hash (alert_time, sql_text_hash)
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_AlertLongRunningQueries
    @ThresholdSeconds INT = 300,
    @MailProfileName SYSNAME = N'DefaultMailProfile',
    @Recipients NVARCHAR(MAX) = N'dba-team@company.com'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME = GETDATE(), @HtmlBody NVARCHAR(MAX), @Subject NVARCHAR(255);

    IF OBJECT_ID('tempdb..#LongRunning') IS NOT NULL DROP TABLE #LongRunning;

    SELECT r.session_id, r.request_id, DB_NAME(r.database_id) AS database_name,
        DATEDIFF(SECOND, r.start_time, @Now) AS elapsed_time_sec,
        r.wait_type, r.blocking_session_id,
        SUBSTRING(st.text, (r.statement_start_offset/2)+1,
            (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
             ELSE r.statement_end_offset END - r.statement_start_offset)/2+1) AS sql_text,
        HASHBYTES('SHA2_256', ISNULL(CAST(st.text AS NVARCHAR(MAX)), N'')
            + CAST(r.session_id AS NVARCHAR(10))) AS sql_text_hash
    INTO #LongRunning
    FROM sys.dm_exec_requests r
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
    WHERE r.session_id <> @@SPID AND r.session_id > 50
      AND DATEDIFF(SECOND, r.start_time, @Now) > @ThresholdSeconds;

    -- Remove duplicates alerted within last 30 minutes
    DELETE lr FROM #LongRunning lr
    WHERE EXISTS (SELECT 1 FROM dbo.LongRunningQueryAlerts a
        WHERE a.sql_text_hash = lr.sql_text_hash AND a.session_id = lr.session_id
          AND a.alert_time >= DATEADD(MINUTE, -30, @Now));

    IF NOT EXISTS (SELECT 1 FROM #LongRunning) RETURN;

    INSERT INTO dbo.LongRunningQueryAlerts
        (session_id, sql_text_hash, database_name, elapsed_time_sec,
         wait_type, blocking_session_id, sql_text, alert_time)
    SELECT session_id, sql_text_hash, database_name, elapsed_time_sec,
        wait_type, blocking_session_id, sql_text, @Now
    FROM #LongRunning;

    SET @Subject = N'⚠ Long-Running Queries on ' + @@SERVERNAME;
    SET @HtmlBody = N'<html><body><h2>Long-Running Queries</h2>
        <table border="1" cellpadding="5" style="border-collapse:collapse;">
        <tr style="background:#4472C4;color:#FFF;">
        <th>SPID</th><th>Database</th><th>Elapsed (sec)</th>
        <th>Wait</th><th>Blocker</th><th>SQL Text</th></tr>';

    SELECT @HtmlBody = @HtmlBody +
        N'<tr><td>' + CAST(session_id AS NVARCHAR) + '</td>'
        + '<td>' + ISNULL(database_name, '-') + '</td>'
        + '<td>' + CAST(elapsed_time_sec AS NVARCHAR) + '</td>'
        + '<td>' + ISNULL(wait_type, '(running)') + '</td>'
        + '<td>' + CASE WHEN blocking_session_id = 0 THEN '-'
                        ELSE CAST(blocking_session_id AS NVARCHAR) END + '</td>'
        + '<td>' + ISNULL(LEFT(sql_text, 200), '-') + '</td></tr>'
    FROM #LongRunning ORDER BY elapsed_time_sec DESC;

    SET @HtmlBody = @HtmlBody + N'</table></body></html>';

    EXEC msdb.dbo.sp_send_dbmail @profile_name = @MailProfileName,
        @recipients = @Recipients, @subject = @Subject,
        @body = @HtmlBody, @body_format = 'HTML';
END;
```

Schedule this procedure as an Agent job running every **5–10 minutes**.

### sp_whoisactive logging for historical analysis

Adam Machanic's `sp_whoisactive` provides richer output than raw DMVs. Set up automatic logging:

```sql
-- Create the logging table from sp_whoisactive's schema
DECLARE @schema VARCHAR(MAX);
EXEC sp_WhoIsActive @get_plans = 1, @return_schema = 1, @schema = @schema OUTPUT;
SET @schema = REPLACE(@schema, '<table_name>', 'dbo.WhoIsActiveLog');
EXEC (@schema);
GO

ALTER TABLE dbo.WhoIsActiveLog ADD capture_time DATETIME NOT NULL DEFAULT GETDATE();
CREATE NONCLUSTERED INDEX IX_CaptureTime ON dbo.WhoIsActiveLog (capture_time);
GO
```

Schedule an Agent job every 5 minutes that runs `EXEC sp_WhoIsActive @get_plans = 1, @destination_table = 'dbo.WhoIsActiveLog';` followed by a purge of rows older than 7 days. This creates an invaluable historical record for diagnosing intermittent issues after the fact.

### Performance counter baselines via DMV

```sql
SELECT RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name, cntr_value,
    CASE RTRIM(counter_name)
        WHEN 'Batch Requests/sec' THEN 'Baseline it; >1000 = busy'
        WHEN 'SQL Compilations/sec' THEN 'Keep < 10% of Batch Requests/sec'
        WHEN 'Page life expectancy' THEN '>300s acceptable; >1000s healthy'
        WHEN 'User Connections' THEN 'Baseline; watch for spikes'
        WHEN 'Lock Waits/sec' THEN 'Should be ~0; >1/sec investigate'
    END AS threshold_guidance
FROM sys.dm_os_performance_counters
WHERE (RTRIM(counter_name) = 'Batch Requests/sec' AND RTRIM(object_name) LIKE '%SQL Statistics%')
   OR (RTRIM(counter_name) = 'SQL Compilations/sec' AND RTRIM(object_name) LIKE '%SQL Statistics%')
   OR (RTRIM(counter_name) = 'Page life expectancy' AND RTRIM(object_name) LIKE '%Buffer Manager%')
   OR (RTRIM(counter_name) = 'User Connections' AND RTRIM(object_name) LIKE '%General Statistics%')
   OR (RTRIM(counter_name) = 'Lock Waits/sec' AND RTRIM(object_name) LIKE '%Locks%'
       AND RTRIM(instance_name) = '_Total');
```

**Page life expectancy below 300 seconds** signals memory pressure that directly causes query slowdowns through increased physical reads.

### Live query progress with dm_exec_query_profiles

On SQL Server 2019+, lightweight query profiling is enabled by default. For earlier versions, enable trace flag 7412.

```sql
SELECT session_id, node_id, physical_operator_name AS operator,
    row_count AS actual_rows_so_far, estimate_row_count AS estimated_rows,
    CASE WHEN estimate_row_count > 0
         THEN CAST(CAST(row_count AS FLOAT) / estimate_row_count * 100.0 AS DECIMAL(7,2))
         ELSE 0 END AS pct_complete,
    OBJECT_NAME(object_id) AS object_name
FROM sys.dm_exec_query_profiles
WHERE session_id = 55  -- replace with target SPID
ORDER BY node_id;
```

---

## Prevention strategies that stop runaway queries before they start

### Resource Governor limits Agent job resource consumption

Resource Governor (Enterprise edition pre-2022, Standard edition in 2022+) routes SQL Agent sessions to a constrained resource pool:

```sql
CREATE RESOURCE POOL AgentJobPool WITH (
    MAX_CPU_PERCENT = 30, MAX_MEMORY_PERCENT = 25, MAX_IOPS_PER_VOLUME = 500
);

CREATE WORKLOAD GROUP AgentJobGroup WITH (
    IMPORTANCE = LOW, REQUEST_MAX_CPU_TIME_SEC = 300,
    REQUEST_MAX_MEMORY_GRANT_PERCENT = 15, MAX_DOP = 4, GROUP_MAX_REQUESTS = 10
) USING AgentJobPool;

CREATE FUNCTION dbo.ResourceGovernorClassifier()
RETURNS SYSNAME WITH SCHEMABINDING AS
BEGIN
    RETURN CASE WHEN APP_NAME() LIKE 'SQLAgent%' THEN 'AgentJobGroup' ELSE 'default' END;
END;
GO

ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.ResourceGovernorClassifier);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```

**`REQUEST_MAX_CPU_TIME_SEC` does not kill queries by default** — it only fires an event. To enable actual query termination, enable Trace Flag 2422 on SQL Server 2016 SP2+ or 2017 CU3+.

### Index and statistics maintenance prevents gradual degradation

Stale statistics are the silent killer of consistent query performance. SQL Server's default auto-update threshold requires **20% of rows to change** before triggering a statistics update — a 1-million-row table needs 200,500 modifications. On SQL Server 2016+, the dynamic threshold (equivalent to trace flag 2371) is the default, reducing this to approximately `SQRT(1000 × rows)` (~32,000 for a million-row table).

**Find and update stale statistics automatically:**

```sql
DECLARE @SQL NVARCHAR(MAX);
DECLARE StatsCursor CURSOR FOR
SELECT 'UPDATE STATISTICS [' + SCHEMA_NAME(o.schema_id) + '].['
    + OBJECT_NAME(s.object_id) + '] [' + s.name + '] WITH '
    + CASE WHEN sp.rows < 500000 THEN 'FULLSCAN'
           WHEN sp.rows < 10000000 THEN 'SAMPLE 50 PERCENT'
           ELSE 'SAMPLE 20 PERCENT' END + ';'
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
JOIN sys.objects o ON s.object_id = o.object_id
WHERE o.is_ms_shipped = 0 AND o.type = 'U'
    AND (sp.modification_counter > 1000
        OR DATEDIFF(DAY, sp.last_updated, GETDATE()) > 7
        OR sp.last_updated IS NULL)
ORDER BY sp.modification_counter DESC;

OPEN StatsCursor;
FETCH NEXT FROM StatsCursor INTO @SQL;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_executesql @SQL; END TRY
    BEGIN CATCH PRINT 'ERROR: ' + ERROR_MESSAGE(); END CATCH
    FETCH NEXT FROM StatsCursor INTO @SQL;
END
CLOSE StatsCursor; DEALLOCATE StatsCursor;
```

For index maintenance, **Ola Hallengren's IndexOptimize** is the industry standard. Schedule it with `@FragmentationLevel1 = 5` (reorganize threshold), `@FragmentationLevel2 = 30` (rebuild threshold), and `@MinNumberOfPages = 1000` to skip tiny indexes. Always include `@UpdateStatistics = 'ALL', @OnlyModifiedStatistics = 'Y'` to combine statistics updates with index maintenance.

### Job design patterns for midnight resilience

- **Capture all dates once at job start** using `STRTDT` tokens or a variable, and pass them through `##GlobalTempTables` or persistent control tables to subsequent steps
- **Break monolithic jobs into independently restartable steps** with checkpoints stored in a control table, enabling safe restart from the last completed batch
- **Use small, focused transactions** — never wrap an entire multi-hour job in one transaction, as rollback will take equally long
- **Design idempotent steps** using MERGE patterns or "process if not already processed" guards so re-execution is safe
- **Set `LOCK_TIMEOUT`** within job steps (e.g., `SET LOCK_TIMEOUT 60000;` for 60 seconds) combined with retry logic to prevent indefinite lock waits
- **Configure job failure notifications** via `sp_update_job @notify_level_email = 2` to alert on failures immediately

---

## Conclusion

The scenario of a 4-hour job inflating to 21 hours and failing at midnight traces to two distinct but related problems. The *duration explosion* typically stems from parameter sniffing, stale statistics, or blocking — all detectable through the DMV queries, Query Store regression analysis, and Extended Events sessions described above. The *midnight NULL failure* stems from SQL Agent's session-based tracking architecture and the `sysjobactivity` correlation breaking across date boundaries — solvable by always filtering on `MAX(session_id)`, using `STRTDT` tokens instead of `GETDATE()`, and capturing date context once at job start.

The most impactful immediate actions are enabling Query Store to catch plan regressions, deploying the watchdog procedure with a 6-hour kill threshold, scheduling the email alert procedure every 5 minutes, and implementing Ola Hallengren's maintenance solution for index and statistics upkeep. Together, these create a defense-in-depth system where **no single query can silently consume 21 hours** without multiple alerts firing and automated intervention engaging.