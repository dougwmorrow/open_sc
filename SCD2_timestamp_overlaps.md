# Solving SCD2 timestamp overlaps in SQL Server BCP pipelines

**The microsecond-level timestamp differences corrupting your trend analysis can be eliminated by capturing a single timestamp in a T-SQL variable and using it consistently across both UPDATE and INSERT operations.** The core fix is simple: declare `@ProcessTime DATETIME2 = SYSDATETIME()` once at the start of your SCD2 stored procedure, then reference this variable for both closing old records and opening new ones. This architectural pattern—BCP loading to staging followed by a stored procedure with MERGE—is the industry-standard approach for high-performance Python/SQL Server SCD2 pipelines.

## The root cause: non-deterministic function calls

When you call `GETDATE()` separately in UPDATE and INSERT statements, SQL Server evaluates the function at each call, creating timestamps that differ by microseconds to milliseconds. Even within a single MERGE statement, non-deterministic functions like `GETDATE()` or `SYSDATETIME()` are evaluated per-row during execution—not once per statement. This creates overlapping date ranges where `Record A.EndDate < Record B.StartDate` instead of exact equality, corrupting point-in-time queries and trend analysis.

The solution requires **pre-capturing the timestamp in a variable** before any DML operations begin:

```sql
DECLARE @ProcessTime DATETIME2(3) = SYSDATETIME();

-- Both operations now use identical timestamp
UPDATE DimCustomer SET EndDate = @ProcessTime WHERE IsCurrent = 1 AND CustomerKey = @Key;
INSERT INTO DimCustomer (..., StartDate, ...) VALUES (..., @ProcessTime, ...);
```

## Optimal stored procedure pattern using MERGE with OUTPUT

The MERGE statement cannot simultaneously UPDATE an old record and INSERT a replacement for the same source row. The standard pattern uses MERGE's **OUTPUT clause to capture expired records**, then inserts new versions in a second statement—all using the same pre-captured timestamp:

```sql
CREATE PROCEDURE dbo.ProcessSCD2Customer
    @BatchTimestamp DATETIME2(3) = NULL  -- Optional: pass from Python
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @ProcessTime DATETIME2(3) = ISNULL(@BatchTimestamp, SYSDATETIME());
    DECLARE @EndOfTime DATETIME2(3) = '9999-12-31';
    
    -- Capture changed records requiring new versions
    DECLARE @Changes TABLE (
        CustomerKey INT, Name NVARCHAR(100), Address NVARCHAR(200)
    );
    
    BEGIN TRANSACTION;
    
    MERGE INTO dbo.DimCustomer AS Target
    USING dbo.StagingCustomer AS Source
    ON Target.CustomerKey = Source.CustomerKey AND Target.IsCurrent = 1
    
    WHEN NOT MATCHED THEN
        INSERT (CustomerKey, Name, Address, StartDate, EndDate, IsCurrent)
        VALUES (Source.CustomerKey, Source.Name, Source.Address, 
                @ProcessTime, @EndOfTime, 1)
    
    WHEN MATCHED AND (
        ISNULL(Target.Name,'') <> ISNULL(Source.Name,'') OR
        ISNULL(Target.Address,'') <> ISNULL(Source.Address,'')
    ) THEN
        UPDATE SET EndDate = @ProcessTime, IsCurrent = 0
    
    OUTPUT $ACTION, Source.CustomerKey, Source.Name, Source.Address
    INTO @Changes;
    
    -- Insert new versions for updated records
    INSERT INTO dbo.DimCustomer (CustomerKey, Name, Address, StartDate, EndDate, IsCurrent)
    SELECT CustomerKey, Name, Address, @ProcessTime, @EndOfTime, 1
    FROM @Changes
    WHERE $ACTION = 'UPDATE';
    
    COMMIT TRANSACTION;
END
```

The **@ProcessTime variable ensures atomic timestamp consistency** across all operations regardless of execution duration.

## Python pipeline architecture: BCP to staging, then stored procedure

BCP is purely a bulk data loading utility—it cannot execute MERGE statements or complex logic. The recommended architecture separates concerns: BCP handles high-speed staging loads (**~175x faster** than pyodbc with fast_executemany), while a stored procedure manages SCD2 logic with guaranteed timestamp consistency.

```python
class SCD2Pipeline:
    def run(self, df: pd.DataFrame, staging_table: str, dim_table: str):
        # 1. Pre-calculate timestamp in Python for traceability
        batch_timestamp = datetime.now()
        
        # 2. Truncate and BCP load to staging
        self.truncate_table(staging_table)
        self.bcp_load(df, staging_table)
        
        # 3. Execute SCD2 stored procedure with timestamp parameter
        with pyodbc.connect(self.conn_str) as conn:
            cursor = conn.cursor()
            cursor.execute(
                "{CALL dbo.ProcessSCD2Customer (?)}",
                (batch_timestamp,)
            )
            conn.commit()
```

Passing the timestamp from Python provides **end-to-end traceability**—you can correlate dimension changes with specific pipeline runs. Alternatively, let the stored procedure generate its own timestamp internally for simpler implementations.

## Why DATETIME2 eliminates precision ambiguity

DATETIME's **~3.33 millisecond rounding** creates unpredictable boundary conditions. Values like `10:15:30.015` round to `10:15:30.017`, while `10:15:30.014` rounds to `10:15:30.013`. This rounding can cause two separately-called `GETDATE()` values to round to the same timestamp—or create unexpected gaps.

**DATETIME2 provides true fractional second precision** without rounding artifacts. For SCD2, DATETIME2(3) offers exact millisecond precision with only 7 bytes of storage (versus DATETIME's 8 bytes). SQL Server's temporal tables use DATETIME2 exclusively, confirming Microsoft's recommendation. Use `SYSDATETIME()` instead of `GETDATE()` to capture DATETIME2 values natively.

| Attribute | DATETIME | DATETIME2(3) |
|-----------|----------|--------------|
| Precision | ~3.33 ms (rounds to .000/.003/.007) | Exact 1 ms |
| Storage | 8 bytes | 7 bytes |
| Date range | 1753-01-01 to 9999-12-31 | 0001-01-01 to 9999-12-31 |
| Recommended | Legacy only | New development |

## Half-open intervals prevent overlap by design

Use the **half-open interval convention [StartDate, EndDate)** where StartDate is inclusive and EndDate is exclusive. When `Record1.EndDate = Record2.StartDate`, the intervals are perfectly contiguous with no mathematical possibility of overlap or gap.

This pattern is endorsed by Kimball methodology, dbt snapshots, SQL Server temporal tables, and follows Dijkstra's 1982 recommendation. The key query pattern becomes:

```sql
-- Point-in-time lookup using half-open intervals
SELECT * FROM DimCustomer
WHERE CustomerKey = @Key
    AND StartDate <= @AsOfDate
    AND @AsOfDate < EndDate  -- Exclusive boundary
```

For current records, use a **high-date sentinel value** like `'9999-12-31'` rather than NULL. This enables simpler range queries without COALESCE overhead and allows BETWEEN if needed. Add an `IsCurrent BIT` column for fast current-record filtering.

## SQL Server temporal tables as an alternative

SQL Server 2016+ temporal tables provide **automatic SCD2-style versioning** with system-managed ValidFrom/ValidTo columns. The engine handles timestamp consistency internally, eliminating manual management entirely:

```sql
CREATE TABLE dbo.DimCustomer (
    CustomerSK INT IDENTITY PRIMARY KEY,
    CustomerKey INT NOT NULL,
    Name NVARCHAR(100),
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    ValidTo DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.DimCustomerHistory));

-- Query any point in time
SELECT * FROM DimCustomer FOR SYSTEM_TIME AS OF '2024-06-15';
```

Temporal tables eliminate timestamp overlap issues completely but have tradeoffs: they capture ALL column changes (no selective Type 2 columns), use UTC timestamps exclusively, and maintain a separate history table. For new implementations without legacy constraints, they're worth strong consideration.

## Transaction isolation for high-concurrency scenarios

The timestamp variable approach ensures consistency regardless of isolation level, but **explicit transactions remain essential** for atomicity. For concurrent SCD2 operations where phantom reads or unique key violations are concerns:

```sql
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
-- Or use hint: MERGE INTO DimCustomer WITH (HOLDLOCK) AS Target
```

SERIALIZABLE prevents other transactions from inserting rows that would match your MERGE conditions during execution. For large batch operations, SNAPSHOT isolation reduces blocking while maintaining consistency, though it requires enabling at the database level.

## Validation: detecting and preventing overlaps

Implement post-load validation to catch any overlap issues that slip through:

```sql
-- Detect overlapping intervals for the same business key
SELECT A.CustomerKey, A.SurrogateKey, B.SurrogateKey AS OverlappingKey
FROM DimCustomer A
INNER JOIN DimCustomer B 
    ON A.CustomerKey = B.CustomerKey 
    AND A.SurrogateKey <> B.SurrogateKey
    AND A.StartDate < B.EndDate 
    AND B.StartDate < A.EndDate;
```

For preventive constraints, add a trigger that raises an error when overlaps are detected on INSERT or UPDATE, or rely on temporal tables' built-in consistency enforcement.

## Recommended implementation checklist

The complete solution combines several complementary patterns:

- **Migrate from DATETIME to DATETIME2(3)** for StartDate and EndDate columns to eliminate precision rounding issues
- **Create an SCD2 stored procedure** that declares `@ProcessTime` once and uses it for both expiring old records and creating new versions
- **Structure the pipeline as BCP → Staging → Stored Procedure** to maintain BCP's performance advantage while centralizing SCD2 logic
- **Adopt half-open intervals [start, end)** with a high-date sentinel value for EndDate on current records
- **Add an IsCurrent flag** for fast current-record queries without date comparison
- **Wrap operations in explicit transactions** for atomicity, with SERIALIZABLE hints if concurrency is a concern
- **Implement overlap detection queries** in post-load validation or as triggered constraints

This architecture resolves the timestamp overlap issue while maintaining the performance benefits of BCP bulk loading and providing a maintainable, debuggable SCD2 implementation.