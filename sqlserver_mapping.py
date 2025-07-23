import pyodbc
import pandas as pd
import sys
from typing import List, Dict, Any, Optional

def create_connection(server: str, username: str = None, password: str = None, 
                     driver: str = 'ODBC Driver 17 for SQL Server') -> pyodbc.Connection:
    """
    Create a connection to SQL Server
    
    Args:
        server: SQL Server instance name or IP
        username: Username for SQL Server (optional for Windows auth)
        password: Password for SQL Server (optional for Windows auth)
        driver: ODBC driver to use
    
    Returns:
        pyodbc.Connection object
    """
    try:
        if username and password:
            # SQL Server authentication
            conn_string = f"DRIVER={{{driver}}};SERVER={server};UID={username};PWD={password};"
        else:
            # Windows authentication
            conn_string = f"DRIVER={{{driver}}};SERVER={server};Trusted_Connection=yes;"
        
        connection = pyodbc.connect(conn_string)
        print(f"Successfully connected to SQL Server: {server}")
        return connection
    
    except Exception as e:
        print(f"Error connecting to SQL Server: {e}")
        raise

def get_databases(connection: pyodbc.Connection) -> List[str]:
    """
    Get list of all databases on the SQL Server instance
    
    Args:
        connection: Active pyodbc connection
    
    Returns:
        List of database names
    """
    try:
        cursor = connection.cursor()
        cursor.execute("""
            SELECT name 
            FROM sys.databases 
            WHERE state = 0  -- Online databases only
            AND name NOT IN ('master', 'tempdb', 'model', 'msdb')  -- Exclude system databases
            ORDER BY name
        """)
        
        databases = [row[0] for row in cursor.fetchall()]
        print(f"Found {len(databases)} user databases")
        return databases
    
    except Exception as e:
        print(f"Error getting databases: {e}")
        return []

def get_tables(connection: pyodbc.Connection, database: str) -> List[str]:
    """
    Get list of all tables in a specific database
    
    Args:
        connection: Active pyodbc connection
        database: Database name
    
    Returns:
        List of table names
    """
    try:
        cursor = connection.cursor()
        cursor.execute(f"""
            SELECT TABLE_NAME 
            FROM [{database}].INFORMATION_SCHEMA.TABLES 
            WHERE TABLE_TYPE = 'BASE TABLE'
            ORDER BY TABLE_NAME
        """)
        
        tables = [row[0] for row in cursor.fetchall()]
        return tables
    
    except Exception as e:
        print(f"Error getting tables for database {database}: {e}")
        return []

def get_column_info(connection: pyodbc.Connection, database: str, table: str) -> List[Dict[str, Any]]:
    """
    Get column information for a specific table
    
    Args:
        connection: Active pyodbc connection
        database: Database name
        table: Table name
    
    Returns:
        List of dictionaries containing column information
    """
    try:
        cursor = connection.cursor()
        cursor.execute(f"""
            SELECT 
                COLUMN_NAME,
                DATA_TYPE,
                IS_NULLABLE,
                CHARACTER_MAXIMUM_LENGTH,
                NUMERIC_PRECISION,
                NUMERIC_SCALE
            FROM [{database}].INFORMATION_SCHEMA.COLUMNS 
            WHERE TABLE_NAME = '{table}'
            ORDER BY ORDINAL_POSITION
        """)
        
        columns = []
        for row in cursor.fetchall():
            columns.append({
                'column_name': row[0],
                'data_type': row[1],
                'is_nullable': row[2],
                'max_length': row[3],
                'precision': row[4],
                'scale': row[5]
            })
        
        return columns
    
    except Exception as e:
        print(f"Error getting column info for {database}.{table}: {e}")
        return []

def get_sample_values(connection: pyodbc.Connection, database: str, table: str, 
                     column: str, sample_size: int = 3) -> List[Any]:
    """
    Get sample unique values from a specific column
    
    Args:
        connection: Active pyodbc connection
        database: Database name
        table: Table name
        column: Column name
        sample_size: Number of sample values to retrieve
    
    Returns:
        List of sample values
    """
    try:
        cursor = connection.cursor()
        cursor.execute(f"""
            SELECT DISTINCT TOP {sample_size} [{column}]
            FROM [{database}].[dbo].[{table}]
            WHERE [{column}] IS NOT NULL
            ORDER BY [{column}]
        """)
        
        values = [row[0] for row in cursor.fetchall()]
        return values
    
    except Exception as e:
        print(f"Error getting sample values for {database}.{table}.{column}: {e}")
        return []

def format_data_type(column_info: Dict[str, Any]) -> str:
    """
    Format data type information into a readable string
    
    Args:
        column_info: Dictionary containing column information
    
    Returns:
        Formatted data type string
    """
    data_type = column_info['data_type']
    
    if column_info['max_length'] and column_info['max_length'] != -1:
        return f"{data_type}({column_info['max_length']})"
    elif column_info['precision'] and column_info['scale']:
        return f"{data_type}({column_info['precision']},{column_info['scale']})"
    elif column_info['precision']:
        return f"{data_type}({column_info['precision']})"
    else:
        return data_type

def create_data_map(server: str, username: str = None, password: str = None, 
                   output_file: str = 'sql_server_data_map.csv') -> pd.DataFrame:
    """
    Main function to create a comprehensive data map of SQL Server
    
    Args:
        server: SQL Server instance name or IP
        username: Username for SQL Server (optional)
        password: Password for SQL Server (optional)
        output_file: Output CSV file name
    
    Returns:
        pandas DataFrame containing the data map
    """
    # Initialize the results list
    data_map_results = []
    
    try:
        # Create connection
        connection = create_connection(server, username, password)
        
        # Get all databases
        databases = get_databases(connection)
        
        total_tables = 0
        total_columns = 0
        
        # Process each database
        for database in databases:
            print(f"\nProcessing database: {database}")
            
            # Get all tables in the database
            tables = get_tables(connection, database)
            total_tables += len(tables)
            
            # Process each table
            for table in tables:
                print(f"  Processing table: {table}")
                
                # Get column information
                columns_info = get_column_info(connection, database, table)
                total_columns += len(columns_info)
                
                # Process each column
                for col_info in columns_info:
                    column_name = col_info['column_name']
                    
                    # Get sample values
                    sample_values = get_sample_values(connection, database, table, column_name)
                    sample_values_str = ', '.join([str(v) for v in sample_values]) if sample_values else 'No data'
                    
                    # Format data type
                    formatted_data_type = format_data_type(col_info)
                    
                    # Add to results
                    data_map_results.append({
                        'database': database,
                        'table': table,
                        'column': column_name,
                        'data_type': formatted_data_type,
                        'sample_values': sample_values_str,
                        'is_nullable': col_info['is_nullable']
                    })
        
        # Close connection
        connection.close()
        
        # Create DataFrame
        df = pd.DataFrame(data_map_results)
        
        # Save to CSV
        df.to_csv(output_file, index=False)
        
        print(f"\n=== Data Mapping Complete ===")
        print(f"Total databases processed: {len(databases)}")
        print(f"Total tables processed: {total_tables}")
        print(f"Total columns processed: {total_columns}")
        print(f"Data map saved to: {output_file}")
        print(f"DataFrame shape: {df.shape}")
        
        return df
    
    except Exception as e:
        print(f"Error in create_data_map: {e}")
        return pd.DataFrame()

def display_summary(df: pd.DataFrame):
    """
    Display a summary of the data map
    
    Args:
        df: DataFrame containing the data map
    """
    if df.empty:
        print("No data to summarize")
        return
    
    print("\n=== DATA MAP SUMMARY ===")
    print(f"Total records: {len(df)}")
    print(f"Databases: {df['database'].nunique()}")
    print(f"Tables: {df['table'].nunique()}")
    print(f"Unique columns: {df['column'].nunique()}")
    
    print(f"\nTop 10 most common data types:")
    print(df['data_type'].value_counts().head(10))
    
    print(f"\nDatabases and table counts:")
    print(df.groupby('database')['table'].nunique().sort_values(ascending=False))

def main():
    """
    Main execution function
    """
    # Configuration - Update these values
    SERVER = "localhost"  # or your server name/IP
    USERNAME = None  # Set to your username if using SQL Server auth
    PASSWORD = None  # Set to your password if using SQL Server auth
    OUTPUT_FILE = "sql_server_data_map.csv"
    
    print("Starting SQL Server Data Mapping...")
    print(f"Target server: {SERVER}")
    
    # Create the data map
    df = create_data_map(SERVER, USERNAME, PASSWORD, OUTPUT_FILE)
    
    if not df.empty:
        # Display summary
        display_summary(df)
        
        # Display first few rows
        print("\n=== FIRST 10 ROWS ===")
        print(df.head(10).to_string(index=False))
    else:
        print("Data mapping failed. Please check your connection settings and permissions.")

if __name__ == "__main__":
    main()
