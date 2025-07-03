import pyodbc
import pandas as pd
from datetime import datetime

def quick_lineage_check(connection_string: str, schema_name: str, table_name: str):
    """
    Quick data lineage check for a SQL Server table
    
    Args:
        connection_string: pyodbc connection string
        schema_name: Schema name (e.g., 'dbo')
        table_name: Table name to analyze
    """
    
    print(f"\n{'='*60}")
    print(f"Data Lineage Analysis for {schema_name}.{table_name}")
    print(f"{'='*60}\n")
    
    conn = pyodbc.connect(connection_string)
    
    # 1. Find stored procedures that modify the table
    print("1. Stored Procedures that modify this table:")
    print("-" * 40)
    
    sp_query = """
    SELECT DISTINCT 
        OBJECT_SCHEMA_NAME(object_id) + '.' + OBJECT_NAME(object_id) AS procedure_name,
        CASE 
            WHEN definition LIKE '%INSERT%' + ? + '%' THEN 'INSERT'
            WHEN definition LIKE '%UPDATE%' + ? + '%' THEN 'UPDATE'
            WHEN definition LIKE '%DELETE%' + ? + '%' THEN 'DELETE'
            WHEN definition LIKE '%MERGE%' + ? + '%' THEN 'MERGE'
            ELSE 'REFERENCE'
        END AS operation_type
    FROM sys.sql_modules
    WHERE definition LIKE '%' + ? + '%'
        AND OBJECTPROPERTY(object_id, 'IsProcedure') = 1
    ORDER BY procedure_name
    """
    
    df_procedures = pd.read_sql_query(sp_query, conn, params=[table_name]*5)
    
    if not df_procedures.empty:
        print(df_procedures.to_string(index=False))
    else:
        print("No stored procedures found")
    
    # 2. Find SQL Agent jobs
    print("\n\n2. SQL Agent Jobs that reference this table:")
    print("-" * 40)
    
    job_query = """
    SELECT DISTINCT
        j.name AS job_name,
        CASE j.enabled WHEN 1 THEN 'Enabled' ELSE 'Disabled' END AS status,
        COALESCE(
            CAST(h.last_run_date AS VARCHAR(20)), 
            'Never executed'
        ) AS last_run
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    LEFT JOIN (
        SELECT job_id, MAX(msdb.dbo.agent_datetime(run_date, run_time)) AS last_run_date
        FROM msdb.dbo.sysjobhistory
        WHERE step_id = 0
        GROUP BY job_id
    ) h ON j.job_id = h.job_id
    WHERE js.command LIKE '%' + ? + '%'
    ORDER BY j.name
    """
    
    df_jobs = pd.read_sql_query(job_query, conn, params=[table_name])
    
    if not df_jobs.empty:
        print(df_jobs.to_string(index=False))
    else:
        print("No SQL Agent jobs found")
    
    # 3. Find foreign key relationships
    print("\n\n3. Foreign Key Relationships:")
    print("-" * 40)
    
    fk_query = """
    -- Tables that reference our table (incoming)
    SELECT 
        'IN' AS direction,
        SCHEMA_NAME(tp.schema_id) + '.' + tp.name AS related_table,
        fk.name AS constraint_name
    FROM sys.foreign_keys fk
    INNER JOIN sys.tables tp ON fk.parent_object_id = tp.object_id
    INNER JOIN sys.tables tr ON fk.referenced_object_id = tr.object_id
    WHERE tr.name = ? AND SCHEMA_NAME(tr.schema_id) = ?
    
    UNION ALL
    
    -- Tables our table references (outgoing)
    SELECT 
        'OUT' AS direction,
        SCHEMA_NAME(tr.schema_id) + '.' + tr.name AS related_table,
        fk.name AS constraint_name
    FROM sys.foreign_keys fk
    INNER JOIN sys.tables tp ON fk.parent_object_id = tp.object_id
    INNER JOIN sys.tables tr ON fk.referenced_object_id = tr.object_id
    WHERE tp.name = ? AND SCHEMA_NAME(tp.schema_id) = ?
    ORDER BY direction, related_table
    """
    
    df_fkeys = pd.read_sql_query(fk_query, conn, 
                                 params=[table_name, schema_name, table_name, schema_name])
    
    if not df_fkeys.empty:
        print(df_fkeys.to_string(index=False))
    else:
        print("No foreign key relationships found")
    
    # 4. Find triggers
    print("\n\n4. Triggers on this table:")
    print("-" * 40)
    
    trigger_query = """
    SELECT 
        t.name AS trigger_name,
        t.type_desc AS trigger_type,
        CASE t.is_disabled WHEN 1 THEN 'Disabled' ELSE 'Enabled' END AS status,
        te.type_desc AS event_type
    FROM sys.triggers t
    INNER JOIN sys.trigger_events te ON t.object_id = te.object_id
    WHERE t.parent_id = OBJECT_ID(?)
    ORDER BY t.name
    """
    
    df_triggers = pd.read_sql_query(trigger_query, conn, 
                                   params=[f'{schema_name}.{table_name}'])
    
    if not df_triggers.empty:
        print(df_triggers.to_string(index=False))
    else:
        print("No triggers found")
    
    # 5. Recent query activity (from cache)
    print("\n\n5. Recent Query Activity (from cache):")
    print("-" * 40)
    
    activity_query = """
    SELECT TOP 10
        COUNT(*) AS execution_count,
        MAX(qs.last_execution_time) AS last_execution,
        CASE 
            WHEN qt.text LIKE '%INSERT%' THEN 'INSERT'
            WHEN qt.text LIKE '%UPDATE%' THEN 'UPDATE'
            WHEN qt.text LIKE '%DELETE%' THEN 'DELETE'
            WHEN qt.text LIKE '%MERGE%' THEN 'MERGE'
            ELSE 'SELECT'
        END AS operation_type,
        DB_NAME(qt.dbid) AS database_name
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
    WHERE qt.text LIKE '%' + ? + '%'
        AND qt.text NOT LIKE '%sys.%'  -- Exclude system queries
    GROUP BY 
        CASE 
            WHEN qt.text LIKE '%INSERT%' THEN 'INSERT'
            WHEN qt.text LIKE '%UPDATE%' THEN 'UPDATE'
            WHEN qt.text LIKE '%DELETE%' THEN 'DELETE'
            WHEN qt.text LIKE '%MERGE%' THEN 'MERGE'
            ELSE 'SELECT'
        END,
        DB_NAME(qt.dbid)
    ORDER BY MAX(qs.last_execution_time) DESC
    """
    
    df_activity = pd.read_sql_query(activity_query, conn, params=[table_name])
    
    if not df_activity.empty:
        # Format datetime for display
        df_activity['last_execution'] = pd.to_datetime(df_activity['last_execution']).dt.strftime('%Y-%m-%d %H:%M:%S')
        print(df_activity.to_string(index=False))
    else:
        print("No recent query activity found in cache")
    
    # 6. Summary and recommendations
    print("\n\n6. Summary and Recommendations:")
    print("-" * 40)
    
    total_sources = len(df_procedures) + len(df_jobs)
    print(f"• Found {total_sources} potential data sources")
    print(f"• Found {len(df_fkeys)} foreign key relationships")
    print(f"• Found {len(df_triggers)} triggers")
    
    if total_sources == 0:
        print("\n⚠️  No direct data sources found. Consider:")
        print("   - Check for dynamic SQL in application code")
        print("   - Look for ETL tools (SSIS, ADF, third-party)")
        print("   - Review application connection strings")
        print("   - Interview application developers")
    
    if len(df_activity) > 0:
        print(f"\n✓ Query cache shows recent activity")
    else:
        print("\n⚠️  No recent activity in query cache")
    
    conn.close()
    print(f"\n{'='*60}\n")


# Example usage
if __name__ == "__main__":
    # Configure your connection
    connection_string = """
    DRIVER={ODBC Driver 17 for SQL Server};
    SERVER=localhost;
    DATABASE=AdventureWorks;
    Trusted_Connection=yes;
    """
    
    # Analyze a table
    quick_lineage_check(connection_string, 'dbo', 'Customer')
    
    # You can also create a simple interactive version
    print("SQL Server Data Lineage Analyzer")
    print("-" * 30)
    
    server = input("Server name: ")
    database = input("Database name: ")
    use_windows_auth = input("Use Windows Authentication? (y/n): ").lower() == 'y'
    
    if use_windows_auth:
        conn_str = f"""
        DRIVER={{ODBC Driver 17 for SQL Server}};
        SERVER={server};
        DATABASE={database};
        Trusted_Connection=yes;
        """
    else:
        username = input("Username: ")
        password = input("Password: ")
        conn_str = f"""
        DRIVER={{ODBC Driver 17 for SQL Server}};
        SERVER={server};
        DATABASE={database};
        UID={username};
        PWD={password};
        """
    
    schema = input("Schema name (default: dbo): ") or 'dbo'
    table = input("Table name: ")
    
    quick_lineage_check(conn_str, schema, table)












import pyodbc
import pandas as pd
import json
from datetime import datetime
from typing import Dict, List, Tuple, Optional
import logging
from dataclasses import dataclass, asdict
import networkx as nx
import matplotlib.pyplot as plt
from collections import defaultdict

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

@dataclass
class DataSource:
    """Represents a data source that interacts with the table"""
    source_type: str  # 'stored_procedure', 'job', 'trigger', 'application'
    name: str
    schema: str
    operation_type: str  # 'INSERT', 'UPDATE', 'DELETE', 'MERGE'
    last_execution: Optional[datetime] = None
    execution_count: Optional[int] = None
    details: Optional[Dict] = None

@dataclass
class TableDependency:
    """Represents a dependency relationship"""
    dependency_type: str  # 'foreign_key', 'reference', 'trigger'
    source_schema: str
    source_object: str
    target_schema: str
    target_object: str
    details: Optional[Dict] = None

class SQLServerDataLineage:
    """Main class for discovering data lineage in SQL Server"""
    
    def __init__(self, connection_string: str):
        """
        Initialize the data lineage discovery tool
        
        Args:
            connection_string: pyodbc connection string
        """
        self.connection_string = connection_string
        self.data_sources: List[DataSource] = []
        self.dependencies: List[TableDependency] = []
        self.lineage_graph = nx.DiGraph()
        
    def connect(self) -> pyodbc.Connection:
        """Create a database connection"""
        return pyodbc.connect(self.connection_string)
    
    def discover_table_lineage(self, schema_name: str, table_name: str) -> Dict:
        """
        Main method to discover complete data lineage for a table
        
        Args:
            schema_name: Schema containing the table
            table_name: Name of the table to analyze
            
        Returns:
            Dictionary containing all lineage information
        """
        logger.info(f"Starting lineage discovery for {schema_name}.{table_name}")
        
        # Reset collections
        self.data_sources = []
        self.dependencies = []
        self.lineage_graph = nx.DiGraph()
        
        # Run all discovery methods
        self._find_stored_procedures(schema_name, table_name)
        self._find_triggers(schema_name, table_name)
        self._find_sql_agent_jobs(schema_name, table_name)
        self._find_foreign_keys(schema_name, table_name)
        self._find_referencing_objects(schema_name, table_name)
        self._analyze_recent_queries(schema_name, table_name)
        self._find_ssis_packages(schema_name, table_name)
        self._find_linked_servers()
        
        # Build the lineage graph
        self._build_lineage_graph(schema_name, table_name)
        
        # Compile results
        results = {
            'target_table': f'{schema_name}.{table_name}',
            'discovery_timestamp': datetime.now().isoformat(),
            'data_sources': [asdict(ds) for ds in self.data_sources],
            'dependencies': [asdict(dep) for dep in self.dependencies],
            'summary': self._generate_summary(),
            'recommendations': self._generate_recommendations()
        }
        
        logger.info(f"Lineage discovery completed. Found {len(self.data_sources)} data sources and {len(self.dependencies)} dependencies")
        
        return results
    
    def _find_stored_procedures(self, schema_name: str, table_name: str):
        """Find stored procedures that reference the table"""
        query = """
        SELECT DISTINCT 
            OBJECT_SCHEMA_NAME(sm.object_id) AS schema_name,
            OBJECT_NAME(sm.object_id) AS procedure_name,
            o.type_desc AS object_type,
            o.modify_date,
            sm.definition
        FROM sys.sql_modules sm
        INNER JOIN sys.objects o ON sm.object_id = o.object_id
        WHERE sm.definition LIKE ?
            AND o.type IN ('P', 'FN', 'TF', 'IF')
        ORDER BY schema_name, procedure_name
        """
        
        with self.connect() as conn:
            cursor = conn.cursor()
            search_pattern = f'%{table_name}%'
            cursor.execute(query, search_pattern)
            
            for row in cursor:
                # Analyze the procedure definition to determine operation type
                definition = row.definition.upper()
                operations = []
                if f'INSERT INTO {table_name.upper()}' in definition or f'INSERT {table_name.upper()}' in definition:
                    operations.append('INSERT')
                if f'UPDATE {table_name.upper()}' in definition:
                    operations.append('UPDATE')
                if f'DELETE FROM {table_name.upper()}' in definition:
                    operations.append('DELETE')
                if f'MERGE {table_name.upper()}' in definition:
                    operations.append('MERGE')
                
                if operations:
                    self.data_sources.append(DataSource(
                        source_type='stored_procedure',
                        name=row.procedure_name,
                        schema=row.schema_name,
                        operation_type=', '.join(operations),
                        details={
                            'object_type': row.object_type,
                            'last_modified': row.modify_date.isoformat() if row.modify_date else None
                        }
                    ))
    
    def _find_triggers(self, schema_name: str, table_name: str):
        """Find triggers on the table"""
        query = """
        SELECT 
            t.name AS trigger_name,
            t.is_disabled,
            t.is_instead_of_trigger,
            te.type_desc AS trigger_event,
            sm.definition
        FROM sys.triggers t
        INNER JOIN sys.trigger_events te ON t.object_id = te.object_id
        LEFT JOIN sys.sql_modules sm ON t.object_id = sm.object_id
        WHERE t.parent_id = OBJECT_ID(?)
        """
        
        with self.connect() as conn:
            cursor = conn.cursor()
            full_table_name = f'{schema_name}.{table_name}'
            cursor.execute(query, full_table_name)
            
            for row in cursor:
                self.data_sources.append(DataSource(
                    source_type='trigger',
                    name=row.trigger_name,
                    schema=schema_name,
                    operation_type=row.trigger_event,
                    details={
                        'is_disabled': row.is_disabled,
                        'is_instead_of': row.is_instead_of_trigger
                    }
                ))
    
    def _find_sql_agent_jobs(self, schema_name: str, table_name: str):
        """Find SQL Agent jobs that reference the table"""
        query = """
        SELECT DISTINCT
            j.job_id,
            j.name AS job_name,
            js.step_id,
            js.step_name,
            js.command,
            js.database_name,
            j.enabled,
            h.last_run_date,
            h.last_run_outcome,
            h.avg_duration_seconds
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
        LEFT JOIN (
            SELECT 
                job_id,
                MAX(msdb.dbo.agent_datetime(run_date, run_time)) AS last_run_date,
                MAX(CASE WHEN run_status = 1 THEN 'Succeeded' ELSE 'Failed' END) AS last_run_outcome,
                AVG(run_duration) AS avg_duration_seconds
            FROM msdb.dbo.sysjobhistory
            WHERE step_id = 0
            GROUP BY job_id
        ) h ON j.job_id = h.job_id
        WHERE js.command LIKE ?
        ORDER BY j.name, js.step_id
        """
        
        with self.connect() as conn:
            cursor = conn.cursor()
            search_pattern = f'%{table_name}%'
            cursor.execute(query, search_pattern)
            
            jobs_found = {}
            for row in cursor:
                job_key = row.job_name
                if job_key not in jobs_found:
                    # Determine operation type from command
                    command_upper = row.command.upper() if row.command else ''
                    operations = []
                    if 'INSERT' in command_upper:
                        operations.append('INSERT')
                    if 'UPDATE' in command_upper:
                        operations.append('UPDATE')
                    if 'DELETE' in command_upper:
                        operations.append('DELETE')
                    if 'MERGE' in command_upper:
                        operations.append('MERGE')
                    if 'EXECUTE' in command_upper or 'EXEC' in command_upper:
                        operations.append('STORED_PROCEDURE')
                    
                    self.data_sources.append(DataSource(
                        source_type='sql_agent_job',
                        name=row.job_name,
                        schema='msdb',
                        operation_type=', '.join(operations) if operations else 'UNKNOWN',
                        last_execution=row.last_run_date,
                        details={
                            'enabled': bool(row.enabled),
                            'database': row.database_name,
                            'last_outcome': row.last_run_outcome,
                            'avg_duration_seconds': row.avg_duration_seconds,
                            'step_name': row.step_name
                        }
                    ))
                    jobs_found[job_key] = True
    
    def _find_foreign_keys(self, schema_name: str, table_name: str):
        """Find foreign key relationships"""
        query = """
        -- Tables referencing our target table
        SELECT 
            'Incoming' AS direction,
            SCHEMA_NAME(tp.schema_id) AS parent_schema,
            tp.name AS parent_table,
            SCHEMA_NAME(tr.schema_id) AS referenced_schema,
            tr.name AS referenced_table,
            fk.name AS constraint_name
        FROM sys.foreign_keys fk
        INNER JOIN sys.tables tp ON fk.parent_object_id = tp.object_id
        INNER JOIN sys.tables tr ON fk.referenced_object_id = tr.object_id
        WHERE tr.name = ? AND SCHEMA_NAME(tr.schema_id) = ?
        
        UNION ALL
        
        -- Tables referenced by our target table
        SELECT 
            'Outgoing' AS direction,
            SCHEMA_NAME(tp.schema_id) AS parent_schema,
            tp.name AS parent_table,
            SCHEMA_NAME(tr.schema_id) AS referenced_schema,
            tr.name AS referenced_table,
            fk.name AS constraint_name
        FROM sys.foreign_keys fk
        INNER JOIN sys.tables tp ON fk.parent_object_id = tp.object_id
        INNER JOIN sys.tables tr ON fk.referenced_object_id = tr.object_id
        WHERE tp.name = ? AND SCHEMA_NAME(tp.schema_id) = ?
        """
        
        with self.connect() as conn:
            cursor = conn.cursor()
            cursor.execute(query, (table_name, schema_name, table_name, schema_name))
            
            for row in cursor:
                if row.direction == 'Incoming':
                    self.dependencies.append(TableDependency(
                        dependency_type='foreign_key',
                        source_schema=row.parent_schema,
                        source_object=row.parent_table,
                        target_schema=row.referenced_schema,
                        target_object=row.referenced_table,
                        details={'constraint_name': row.constraint_name, 'direction': 'incoming'}
                    ))
                else:
                    self.dependencies.append(TableDependency(
                        dependency_type='foreign_key',
                        source_schema=row.parent_schema,
                        source_object=row.parent_table,
                        target_schema=row.referenced_schema,
                        target_object=row.referenced_table,
                        details={'constraint_name': row.constraint_name, 'direction': 'outgoing'}
                    ))
    
    def _find_referencing_objects(self, schema_name: str, table_name: str):
        """Find objects that reference the table using sys.dm_sql_referencing_entities"""
        query = """
        SELECT 
            referencing_schema_name,
            referencing_entity_name,
            referencing_class_desc,
            is_caller_dependent
        FROM sys.dm_sql_referencing_entities(?, 'OBJECT')
        WHERE referencing_schema_name IS NOT NULL
        """
        
        try:
            with self.connect() as conn:
                cursor = conn.cursor()
                full_table_name = f'{schema_name}.{table_name}'
                cursor.execute(query, full_table_name)
                
                for row in cursor:
                    self.dependencies.append(TableDependency(
                        dependency_type='reference',
                        source_schema=row.referencing_schema_name,
                        source_object=row.referencing_entity_name,
                        target_schema=schema_name,
                        target_object=table_name,
                        details={
                            'class_desc': row.referencing_class_desc,
                            'is_caller_dependent': row.is_caller_dependent
                        }
                    ))
        except pyodbc.Error as e:
            logger.warning(f"Could not query referencing entities: {e}")
    
    def _analyze_recent_queries(self, schema_name: str, table_name: str):
        """Analyze recent queries from the query cache"""
        query = """
        SELECT TOP 50
            qs.execution_count,
            qs.last_execution_time,
            SUBSTRING(qt.text, (qs.statement_start_offset/2)+1,
                ((CASE qs.statement_end_offset
                    WHEN -1 THEN DATALENGTH(qt.text)
                    ELSE qs.statement_end_offset
                END - qs.statement_start_offset)/2) + 1) AS query_text,
            DB_NAME(qt.dbid) AS database_name,
            OBJECT_NAME(qt.objectid, qt.dbid) AS object_name
        FROM sys.dm_exec_query_stats qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
        WHERE qt.text LIKE ?
            AND (qt.text LIKE '%INSERT%' 
                OR qt.text LIKE '%UPDATE%' 
                OR qt.text LIKE '%DELETE%'
                OR qt.text LIKE '%MERGE%')
        ORDER BY qs.last_execution_time DESC
        """
        
        with self.connect() as conn:
            cursor = conn.cursor()
            search_pattern = f'%{table_name}%'
            cursor.execute(query, search_pattern)
            
            # Track unique query patterns
            query_patterns = defaultdict(lambda: {'count': 0, 'last_execution': None})
            
            for row in cursor:
                if row.query_text:
                    # Extract operation type
                    query_upper = row.query_text.upper()
                    operation = 'UNKNOWN'
                    if 'INSERT' in query_upper:
                        operation = 'INSERT'
                    elif 'UPDATE' in query_upper:
                        operation = 'UPDATE'
                    elif 'DELETE' in query_upper:
                        operation = 'DELETE'
                    elif 'MERGE' in query_upper:
                        operation = 'MERGE'
                    
                    # Group by object name or query pattern
                    key = row.object_name if row.object_name else f"Ad-hoc {operation}"
                    query_patterns[key]['count'] += row.execution_count
                    query_patterns[key]['last_execution'] = row.last_execution_time
                    query_patterns[key]['operation'] = operation
                    query_patterns[key]['database'] = row.database_name
            
            # Add patterns to data sources
            for pattern_name, pattern_info in query_patterns.items():
                self.data_sources.append(DataSource(
                    source_type='query_cache',
                    name=pattern_name,
                    schema=pattern_info.get('database', 'unknown'),
                    operation_type=pattern_info['operation'],
                    last_execution=pattern_info['last_execution'],
                    execution_count=pattern_info['count'],
                    details={'source': 'dm_exec_query_stats'}
                ))
    
    def _find_ssis_packages(self, schema_name: str, table_name: str):
        """Find SSIS packages that might interact with the table"""
        query = """
        SELECT 
            f.name AS folder_name,
            p.name AS project_name,
            pkg.name AS package_name,
            pkg.description,
            p.deployed_by_name,
            p.last_deployed_time
        FROM SSISDB.catalog.folders f
        INNER JOIN SSISDB.catalog.projects p ON p.folder_id = f.folder_id
        INNER JOIN SSISDB.catalog.packages pkg ON pkg.project_id = p.project_id
        ORDER BY f.name, p.name, pkg.name
        """
        
        try:
            with self.connect() as conn:
                cursor = conn.cursor()
                cursor.execute(query)
                
                for row in cursor:
                    # Note: We can't inspect package content without loading the package
                    # This just lists all packages for manual review
                    self.data_sources.append(DataSource(
                        source_type='ssis_package',
                        name=row.package_name,
                        schema=row.folder_name,
                        operation_type='ETL',
                        details={
                            'project': row.project_name,
                            'description': row.description,
                            'deployed_by': row.deployed_by_name,
                            'last_deployed': row.last_deployed_time.isoformat() if row.last_deployed_time else None,
                            'requires_manual_review': True
                        }
                    ))
        except pyodbc.Error as e:
            logger.info(f"SSISDB not available or accessible: {e}")
    
    def _find_linked_servers(self):
        """Find linked servers that might be data sources"""
        query = """
        SELECT 
            srv.name AS linked_server_name,
            srv.product,
            srv.provider,
            srv.data_source,
            srv.catalog,
            srv.is_linked
        FROM sys.servers srv
        WHERE srv.is_linked = 1
        """
        
        with self.connect() as conn:
            cursor = conn.cursor()
            cursor.execute(query)
            
            for row in cursor:
                self.data_sources.append(DataSource(
                    source_type='linked_server',
                    name=row.linked_server_name,
                    schema='external',
                    operation_type='POTENTIAL_SOURCE',
                    details={
                        'product': row.product,
                        'provider': row.provider,
                        'data_source': row.data_source,
                        'catalog': row.catalog
                    }
                ))
    
    def _build_lineage_graph(self, schema_name: str, table_name: str):
        """Build a directed graph representing the data lineage"""
        target_node = f"{schema_name}.{table_name}"
        self.lineage_graph.add_node(target_node, node_type='target_table')
        
        # Add data sources
        for source in self.data_sources:
            source_node = f"{source.schema}.{source.name}"
            self.lineage_graph.add_node(source_node, 
                                       node_type=source.source_type,
                                       operation=source.operation_type)
            self.lineage_graph.add_edge(source_node, target_node)
        
        # Add dependencies
        for dep in self.dependencies:
            if dep.dependency_type == 'foreign_key':
                if dep.details.get('direction') == 'incoming':
                    # Other tables reference our table
                    source_node = f"{dep.source_schema}.{dep.source_object}"
                    self.lineage_graph.add_node(source_node, node_type='dependent_table')
                    self.lineage_graph.add_edge(source_node, target_node)
                else:
                    # Our table references other tables
                    target_dep_node = f"{dep.target_schema}.{dep.target_object}"
                    self.lineage_graph.add_node(target_dep_node, node_type='referenced_table')
                    self.lineage_graph.add_edge(target_node, target_dep_node)
    
    def _generate_summary(self) -> Dict:
        """Generate a summary of findings"""
        source_types = defaultdict(int)
        operation_types = defaultdict(int)
        
        for source in self.data_sources:
            source_types[source.source_type] += 1
            for op in source.operation_type.split(', '):
                operation_types[op] += 1
        
        return {
            'total_data_sources': len(self.data_sources),
            'total_dependencies': len(self.dependencies),
            'source_types': dict(source_types),
            'operation_types': dict(operation_types),
            'graph_nodes': self.lineage_graph.number_of_nodes(),
            'graph_edges': self.lineage_graph.number_of_edges()
        }
    
    def _generate_recommendations(self) -> List[str]:
        """Generate recommendations based on findings"""
        recommendations = []
        
        # Check for missing documentation
        if len(self.data_sources) == 0:
            recommendations.append("No data sources found. Consider checking for dynamic SQL or external applications.")
        
        # Check for SQL Agent jobs without recent executions
        inactive_jobs = [s for s in self.data_sources 
                        if s.source_type == 'sql_agent_job' 
                        and s.last_execution is None]
        if inactive_jobs:
            recommendations.append(f"Found {len(inactive_jobs)} SQL Agent jobs that have never executed.")
        
        # Check for disabled triggers
        disabled_triggers = [s for s in self.data_sources 
                           if s.source_type == 'trigger' 
                           and s.details.get('is_disabled')]
        if disabled_triggers:
            recommendations.append(f"Found {len(disabled_triggers)} disabled triggers.")
        
        # Check for SSIS packages
        ssis_packages = [s for s in self.data_sources if s.source_type == 'ssis_package']
        if ssis_packages:
            recommendations.append(f"Found {len(ssis_packages)} SSIS packages that require manual review.")
        
        # Check for linked servers
        linked_servers = [s for s in self.data_sources if s.source_type == 'linked_server']
        if linked_servers:
            recommendations.append(f"Found {len(linked_servers)} linked servers that could be data sources.")
        
        return recommendations
    
    def visualize_lineage(self, output_file: str = 'data_lineage.png'):
        """Create a visualization of the data lineage graph"""
        if self.lineage_graph.number_of_nodes() == 0:
            logger.warning("No nodes in lineage graph to visualize")
            return
        
        plt.figure(figsize=(12, 8))
        
        # Define node colors based on type
        node_colors = {
            'target_table': 'red',
            'stored_procedure': 'lightblue',
            'sql_agent_job': 'lightgreen',
            'trigger': 'yellow',
            'linked_server': 'orange',
            'ssis_package': 'purple',
            'query_cache': 'pink',
            'dependent_table': 'lightgray',
            'referenced_table': 'darkgray'
        }
        
        # Get node colors
        colors = [node_colors.get(self.lineage_graph.nodes[node].get('node_type', ''), 'white') 
                 for node in self.lineage_graph.nodes()]
        
        # Layout
        pos = nx.spring_layout(self.lineage_graph, k=2, iterations=50)
        
        # Draw
        nx.draw(self.lineage_graph, pos, 
                node_color=colors,
                with_labels=True,
                node_size=3000,
                font_size=8,
                font_weight='bold',
                arrows=True,
                edge_color='gray',
                alpha=0.7)
        
        # Add title
        plt.title("Data Lineage Visualization", fontsize=16, fontweight='bold')
        
        # Save
        plt.tight_layout()
        plt.savefig(output_file, dpi=300, bbox_inches='tight')
        plt.close()
        
        logger.info(f"Lineage visualization saved to {output_file}")
    
    def export_to_json(self, results: Dict, output_file: str):
        """Export results to JSON file"""
        with open(output_file, 'w') as f:
            json.dump(results, f, indent=2, default=str)
        logger.info(f"Results exported to {output_file}")
    
    def generate_documentation(self, results: Dict, output_file: str):
        """Generate markdown documentation of the lineage"""
        with open(output_file, 'w') as f:
            f.write(f"# Data Lineage Report for {results['target_table']}\n\n")
            f.write(f"Generated: {results['discovery_timestamp']}\n\n")
            
            # Summary
            summary = results['summary']
            f.write("## Summary\n\n")
            f.write(f"- Total Data Sources: {summary['total_data_sources']}\n")
            f.write(f"- Total Dependencies: {summary['total_dependencies']}\n\n")
            
            # Data Sources
            f.write("## Data Sources\n\n")
            
            # Group by type
            sources_by_type = defaultdict(list)
            for source in results['data_sources']:
                sources_by_type[source['source_type']].append(source)
            
            for source_type, sources in sources_by_type.items():
                f.write(f"### {source_type.replace('_', ' ').title()}\n\n")
                for source in sources:
                    f.write(f"- **{source['schema']}.{source['name']}**\n")
                    f.write(f"  - Operations: {source['operation_type']}\n")
                    if source.get('last_execution'):
                        f.write(f"  - Last Execution: {source['last_execution']}\n")
                    if source.get('execution_count'):
                        f.write(f"  - Execution Count: {source['execution_count']}\n")
                    f.write("\n")
            
            # Dependencies
            if results['dependencies']:
                f.write("## Dependencies\n\n")
                for dep in results['dependencies']:
                    f.write(f"- {dep['source_schema']}.{dep['source_object']} → ")
                    f.write(f"{dep['target_schema']}.{dep['target_object']} ")
                    f.write(f"({dep['dependency_type']})\n")
            
            # Recommendations
            if results['recommendations']:
                f.write("\n## Recommendations\n\n")
                for rec in results['recommendations']:
                    f.write(f"- {rec}\n")
        
        logger.info(f"Documentation generated at {output_file}")


# Example usage
if __name__ == "__main__":
    # Connection string example - adjust as needed
    connection_string = """
    DRIVER={ODBC Driver 17 for SQL Server};
    SERVER=your_server;
    DATABASE=your_database;
    UID=your_username;
    PWD=your_password;
    """
    
    # Initialize the lineage discovery tool
    lineage_tool = SQLServerDataLineage(connection_string)
    
    # Discover lineage for a specific table
    results = lineage_tool.discover_table_lineage('dbo', 'YourTableName')
    
    # Export results
    lineage_tool.export_to_json(results, 'lineage_results.json')
    lineage_tool.generate_documentation(results, 'lineage_report.md')
    lineage_tool.visualize_lineage('lineage_graph.png')
    
    # Print summary
    print(f"\nLineage Discovery Complete!")
    print(f"Found {len(results['data_sources'])} data sources")
    print(f"Found {len(results['dependencies'])} dependencies")
    print("\nRecommendations:")
    for rec in results['recommendations']:
        print(f"- {rec}")










SELECT 
    referencing_schema_name,
    referencing_entity_name,
    referencing_class_desc,
    is_caller_dependent
FROM sys.dm_sql_referencing_entities('dbo.YourTableName', 'OBJECT')
ORDER BY referencing_schema_name, referencing_entity_name;







CREATE EVENT SESSION [DataLineageTracking] ON SERVER 
ADD EVENT sqlserver.sql_statement_completed(
    SET collect_statement=(1)
    ACTION(
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.username,
        sqlserver.sql_text
    )
    WHERE ([sqlserver].[like_i_sql_unicode_string]([statement],N'%INSERT%') 
           OR [sqlserver].[like_i_sql_unicode_string]([statement],N'%UPDATE%'))
           AND [sqlserver].[database_name] = N'YourDatabaseName'
)
ADD TARGET package0.event_file(SET filename=N'C:\DataLineageTracking.xel')
WITH (MAX_MEMORY=4096 KB, TRACK_CAUSALITY=ON, STARTUP_STATE=OFF);



SELECT 
    f.name AS FolderName,
    p.name AS ProjectName,
    pkg.name AS PackageName,
    pkg.description,
    ex.execution_count,
    ex.last_execution_time
FROM SSISDB.catalog.folders f
INNER JOIN SSISDB.catalog.projects p ON p.folder_id = f.folder_id
INNER JOIN SSISDB.catalog.packages pkg ON pkg.project_id = p.project_id
LEFT JOIN (
    SELECT package_name, 
           COUNT(*) AS execution_count,
           MAX(start_time) AS last_execution_time
    FROM SSISDB.catalog.executions
    GROUP BY package_name
) ex ON ex.package_name = pkg.name
ORDER BY f.name, p.name, pkg.name;


SELECT 
    j.name AS JobName,
    js.step_name,
    js.command,
    js.database_name,
    h.last_run_date,
    h.avg_duration_minutes
FROM msdb.dbo.sysjobs j
INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
LEFT JOIN (
    SELECT job_id,
           MAX(msdb.dbo.agent_datetime(run_date, run_time)) AS last_run_date,
           AVG(((run_duration/10000*3600 + (run_duration/100)%100*60 + run_duration%100 + 31) / 60)) AS avg_duration_minutes
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0
    GROUP BY job_id
) h ON j.job_id = h.job_id
WHERE js.command LIKE '%YourTableName%'
ORDER BY j.name;




-- Find linked servers
SELECT 
    srv.name AS LinkedServerName,
    srv.product,
    srv.data_source,
    srv.provider
FROM sys.servers srv
WHERE srv.is_linked = 1;

-- Find external data sources (SQL Server 2016+)
SELECT 
    eds.name AS ExternalDataSourceName,
    eds.location,
    eds.type_desc,
    eds.credential_id
FROM sys.external_data_sources eds;





DECLARE @TableName NVARCHAR(128) = 'YourTableName';
DECLARE @SchemaName NVARCHAR(128) = 'dbo';

-- Find all objects referencing the table
WITH Dependencies AS (
    SELECT 
        'Direct Reference' AS dependency_type,
        OBJECT_SCHEMA_NAME(sm.object_id) AS schema_name,
        OBJECT_NAME(sm.object_id) AS object_name,
        o.type_desc AS object_type
    FROM sys.sql_modules sm
    INNER JOIN sys.objects o ON sm.object_id = o.object_id
    WHERE sm.definition LIKE '%' + @TableName + '%'
    
    UNION ALL
    
    SELECT 
        'Foreign Key Reference' AS dependency_type,
        SCHEMA_NAME(tp.schema_id) AS schema_name,
        tp.name AS object_name,
        'TABLE' AS object_type
    FROM sys.foreign_keys f
    INNER JOIN sys.tables tp ON f.parent_object_id = tp.object_id
    INNER JOIN sys.tables tr ON f.referenced_object_id = tr.object_id
    WHERE tr.name = @TableName AND SCHEMA_NAME(tr.schema_id) = @SchemaName
    
    UNION ALL
    
    SELECT 
        'Trigger' AS dependency_type,
        @SchemaName AS schema_name,
        t.name AS object_name,
        t.type_desc AS object_type
    FROM sys.triggers t
    WHERE t.parent_id = OBJECT_ID(@SchemaName + '.' + @TableName)
)
SELECT DISTINCT * FROM Dependencies
ORDER BY dependency_type, schema_name, object_name;









  -- Find recent queries modifying the table
SELECT TOP 100
    qs.execution_count,
    qs.last_execution_time,
    SUBSTRING(qt.text, qs.statement_start_offset/2 + 1, 
        (CASE WHEN qs.statement_end_offset = -1 
              THEN LEN(CONVERT(NVARCHAR(MAX), qt.text)) * 2 
              ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) AS query_text,
    DB_NAME(qt.dbid) AS database_name,
    OBJECT_NAME(qt.objectid, qt.dbid) AS object_name
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
WHERE qt.text LIKE '%YourTableName%'
    AND (qt.text LIKE '%INSERT%' OR qt.text LIKE '%UPDATE%' OR qt.text LIKE '%MERGE%')
ORDER BY qs.last_execution_time DESC;






  



























