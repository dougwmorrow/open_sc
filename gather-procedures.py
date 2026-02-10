Option 1: Search for a specific procedure across all jobs
SELECT 
    j.name AS job_name,
    js.step_id,
    js.step_name,
    js.subsystem,
    js.command
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE js.command LIKE '%your_procedure_name%'
ORDER BY j.name, js.step_id;
Option 2: Full extraction script for all jobs and their steps
import pyodbc
import os
import tempfile
import csv

# Connection settings
SERVER = "your_server"
DATABASE = "msdb"
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

output_dir = os.path.join(tempfile.gettempdir(), "sql_agent_jobs")
os.makedirs(output_dir, exist_ok=True)

conn = pyodbc.connect(CONN_STR)
cursor = conn.cursor()

cursor.execute("""
    SELECT 
        j.name AS job_name,
        j.enabled AS job_enabled,
        js.step_id,
        js.step_name,
        js.subsystem,
        js.database_name,
        js.command
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    ORDER BY j.name, js.step_id
""")

rows = cursor.fetchall()
columns = [desc[0] for desc in cursor.description]

# Write to CSV for easy review
csv_path = os.path.join(output_dir, "all_agent_jobs.csv")
with open(csv_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(columns)
    writer.writerows(rows)

# Also write each job's steps as individual .sql files
jobs = {}
for row in rows:
    job_name = row[0]
    if job_name not in jobs:
        jobs[job_name] = []
    jobs[job_name].append(row)

for job_name, steps in jobs.items():
    safe_name = "".join(c if c.isalnum() or c in "._- " else "_" for c in job_name)
    filepath = os.path.join(output_dir, f"{safe_name}.sql")
    
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(f"-- Job: {job_name}\n")
        f.write(f"-- Enabled: {steps[0][1]}\n\n")
        
        for step in steps:
            step_id, step_name, subsystem, db_name, command = step[2], step[3], step[4], step[5], step[6]
            f.write(f"-- Step {step_id}: {step_name}\n")
            f.write(f"-- Subsystem: {subsystem} | Database: {db_name}\n")
            f.write(f"{command or '-- (no command)'}\n\n")
            f.write("-" * 80 + "\n\n")
    
    print(f"  ✓ {job_name} ({len(steps)} steps)")

cursor.close()
conn.close()

print(f"\nDone. {len(jobs)} jobs extracted to {output_dir}")
print(f"CSV summary: {csv_path}")
I'd recommend starting with