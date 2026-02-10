import pyodbc
import os
import tempfile
import re

# Connection settings
SERVER = "your_server"
DATABASE = "your_database"
CONN_STR = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={SERVER};DATABASE={DATABASE};Trusted_Connection=yes;"

# Create temp directory
output_dir = os.path.join(tempfile.gettempdir(), f"{DATABASE}_procedures")
os.makedirs(output_dir, exist_ok=True)

conn = pyodbc.connect(CONN_STR)
cursor = conn.cursor()

# Get all stored procedure names with their schema
cursor.execute("""
    SELECT s.name AS schema_name, p.name AS proc_name
    FROM sys.procedures p
    JOIN sys.schemas s ON p.schema_id = s.schema_id
    ORDER BY s.name, p.name
""")

procs = cursor.fetchall()
print(f"Found {len(procs)} procedures. Extracting to: {output_dir}")

for schema_name, proc_name in procs:
    full_name = f"{schema_name}.{proc_name}"
    
    # Get the procedure definition
    cursor.execute("""
        SELECT OBJECT_DEFINITION(OBJECT_ID(?))
    """, f"{schema_name}.{proc_name}")
    
    row = cursor.fetchone()
    definition = row[0] if row and row[0] else None
    
    if definition:
        # Sanitize filename
        safe_name = re.sub(r'[^\w\-.]', '_', full_name)
        filepath = os.path.join(output_dir, f"{safe_name}.sql")
        
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(definition)
        
        print(f"  ✓ {full_name}")
    else:
        print(f"  ✗ {full_name} (encrypted or empty)")

cursor.close()
conn.close()
print(f"\nDone. {len(procs)} procedures written to {output_dir}")
This pulls every stored procedure's definition via OBJECT_DEFINITION() and writes each one as a .sql file into a temp directory named after the database. Encrypted procs will show as empty since their definitions aren't accessible. Schema is included in the filename (e.g., dbo.MyProc.sql).