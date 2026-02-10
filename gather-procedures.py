import pyodbc
import os
import tempfile
import re

# Connection settings
SERVER = "your_server"
DATABASE = "your_database"
UID = "your_username"
PWD = "your_password"

CONN_STR = (
    f"DRIVER={{ODBC Driver 18 for SQL Server}};"
    f"SERVER={SERVER};"
    f"DATABASE={DATABASE};"
    f"UID={UID};"
    f"PWD={PWD};"
    f"TrustServerCertificate=yes;"
)

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
    
    cursor.execute("""
        SELECT OBJECT_DEFINITION(OBJECT_ID(?))
    """, f"{schema_name}.{proc_name}")
    
    row = cursor.fetchone()
    definition = row[0] if row and row[0] else None
    
    if definition:
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
Key changes: switched to ODBC Driver 18 for SQL Server with UID/PWD for SQL authentication, and added TrustServerCertificate=yes; since Driver 18 enforces encryption by default and will fail without it if your server uses a self-signed cert.