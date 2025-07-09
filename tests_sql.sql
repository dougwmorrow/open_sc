#!/usr/bin/env python3
"""
File Statistics Tracker with SQL Server SCD2 Implementation
Analyzes all files in a directory and maintains historical tracking using SCD2 methodology
in SQL Server database.
"""

import os
import stat
import pwd
import grp
import hashlib
import mimetypes
from pathlib import Path
from datetime import datetime, timezone
import pandas as pd
import platform
import subprocess
import sys
from typing import Dict, List, Optional, Tuple
import sqlalchemy as sa
from sqlalchemy import create_engine, text, MetaData, Table, Column, Integer, String, DateTime, Boolean, Float, BigInteger
from sqlalchemy.dialects.mssql import UNIQUEIDENTIFIER
import pyodbc
import uuid
import json
from dataclasses import dataclass, asdict

@dataclass
class DatabaseConfig:
    """Database connection configuration"""
    server: str
    database: str
    username: Optional[str] = None
    password: Optional[str] = None
    driver: str = "ODBC Driver 17 for SQL Server"
    trusted_connection: bool = True

class FileStatsTracker:
    """Main class for file statistics tracking with SCD2 implementation"""
    
    def __init__(self, db_config: DatabaseConfig):
        self.db_config = db_config
        self.engine = self._create_connection()
        self.metadata = MetaData()
        self._create_tables()
    
    def _create_connection(self):
        """Create SQLAlchemy engine for SQL Server"""
        if self.db_config.trusted_connection:
            connection_string = (
                f"mssql+pyodbc://@{self.db_config.server}/{self.db_config.database}"
                f"?driver={self.db_config.driver.replace(' ', '+')}&trusted_connection=yes"
            )
        else:
            connection_string = (
                f"mssql+pyodbc://{self.db_config.username}:{self.db_config.password}"
                f"@{self.db_config.server}/{self.db_config.database}"
                f"?driver={self.db_config.driver.replace(' ', '+')}"
            )
        
        return create_engine(connection_string, echo=False)
    
    def _create_tables(self):
        """Create database tables if they don't exist"""
        
        # Main file statistics table with SCD2 structure
        self.file_stats_table = Table(
            'file_statistics_history',
            self.metadata,
            Column('surrogate_key', Integer, primary_key=True, autoincrement=True),
            Column('file_path', String(2000), nullable=False),  # Natural key
            Column('file_name', String(500)),
            Column('file_extension', String(50)),
            Column('directory_path', String(2000)),
            Column('is_file', Boolean),
            Column('is_directory', Boolean),
            Column('is_symlink', Boolean),
            Column('size_bytes', BigInteger),
            Column('size_kb', Float),
            Column('size_mb', Float),
            Column('mime_type', String(200)),
            Column('created_timestamp', Float),
            Column('modified_timestamp', Float),
            Column('accessed_timestamp', Float),
            Column('created_datetime', DateTime),
            Column('modified_datetime', DateTime),
            Column('accessed_datetime', DateTime),
            Column('owner_uid', Integer),
            Column('owner_name', String(100)),
            Column('group_gid', Integer),
            Column('group_name', String(100)),
            Column('permissions', String(20)),
            Column('mode', String(20)),
            Column('inode', BigInteger),
            Column('device_id', BigInteger),
            Column('hard_links', Integer),
            Column('md5_hash', String(32)),
            Column('last_accessed_user', String(100)),
            
            # SCD2 specific columns
            Column('effective_date', DateTime, nullable=False),
            Column('end_date', DateTime, nullable=True),
            Column('is_current', Boolean, nullable=False, default=True),
            Column('record_created_date', DateTime, nullable=False, default=datetime.utcnow),
            Column('record_created_by', String(100), nullable=False, default='system'),
            Column('change_reason', String(500)),
            Column('scan_id', UNIQUEIDENTIFIER, nullable=False),
            
            # Computed columns for easier querying
            Column('age_days', Integer),
            Column('last_modified_days_ago', Integer),
            Column('last_accessed_days_ago', Integer)
        )
        
        # Scan metadata table
        self.scan_metadata_table = Table(
            'scan_metadata',
            self.metadata,
            Column('scan_id', UNIQUEIDENTIFIER, primary_key=True),
            Column('scan_start_time', DateTime, nullable=False),
            Column('scan_end_time', DateTime),
            Column('directory_scanned', String(2000), nullable=False),
            Column('recursive_scan', Boolean, nullable=False),
            Column('include_hidden', Boolean, nullable=False),
            Column('total_files_found', Integer),
            Column('total_files_analyzed', Integer),
            Column('total_errors', Integer),
            Column('scan_status', String(50)),  # 'running', 'completed', 'failed'
            Column('error_message', String(2000))
        )
        
        # Create tables
        self.metadata.create_all(self.engine)
        print("Database tables created/verified successfully")
    
    def get_file_hash(self, file_path, hash_type='md5'):
        """Calculate file hash (MD5 by default)"""
        try:
            hash_obj = hashlib.new(hash_type)
            with open(file_path, 'rb') as f:
                for chunk in iter(lambda: f.read(4096), b""):
                    hash_obj.update(chunk)
            return hash_obj.hexdigest()
        except (IOError, OSError):
            return None

    def get_user_name(self, uid):
        """Get username from UID"""
        try:
            return pwd.getpwuid(uid).pw_name
        except (KeyError, AttributeError):
            return f"UID:{uid}"

    def get_group_name(self, gid):
        """Get group name from GID"""
        try:
            return grp.getgrgid(gid).gr_name
        except (KeyError, AttributeError):
            return f"GID:{gid}"

    def get_file_permissions(self, mode):
        """Convert file mode to readable permissions string"""
        return stat.filemode(mode)

    def get_mime_type(self, file_path):
        """Get MIME type of file"""
        mime_type, _ = mimetypes.guess_type(file_path)
        return mime_type or 'unknown'

    def get_last_accessed_user(self, file_path):
        """Attempt to get the last user who accessed the file"""
        try:
            if platform.system() == "Linux":
                result = subprocess.run(['lsof', str(file_path)], 
                                      capture_output=True, text=True, timeout=5)
                if result.returncode == 0 and result.stdout:
                    lines = result.stdout.strip().split('\n')
                    if len(lines) > 1:
                        return lines[1].split()[2]
        except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError):
            pass
        return "Unknown"

    def analyze_file(self, file_path: Path, scan_id: str) -> Dict:
        """Analyze a single file and return its statistics"""
        try:
            file_stat = file_path.stat()
            current_time = datetime.utcnow()
            
            # Basic file information
            file_info = {
                'file_path': str(file_path.absolute()),
                'file_name': file_path.name,
                'file_extension': file_path.suffix.lower(),
                'directory_path': str(file_path.parent),
                'is_file': file_path.is_file(),
                'is_directory': file_path.is_dir(),
                'is_symlink': file_path.is_symlink(),
            }
            
            # File size and type
            file_info.update({
                'size_bytes': file_stat.st_size,
                'size_kb': round(file_stat.st_size / 1024, 2),
                'size_mb': round(file_stat.st_size / (1024 * 1024), 2),
                'mime_type': self.get_mime_type(file_path),
            })
            
            # Timestamps
            created_dt = datetime.fromtimestamp(file_stat.st_ctime)
            modified_dt = datetime.fromtimestamp(file_stat.st_mtime)
            accessed_dt = datetime.fromtimestamp(file_stat.st_atime)
            
            file_info.update({
                'created_timestamp': file_stat.st_ctime,
                'modified_timestamp': file_stat.st_mtime,
                'accessed_timestamp': file_stat.st_atime,
                'created_datetime': created_dt,
                'modified_datetime': modified_dt,
                'accessed_datetime': accessed_dt,
            })
            
            # Ownership and permissions
            file_info.update({
                'owner_uid': file_stat.st_uid,
                'owner_name': self.get_user_name(file_stat.st_uid),
                'group_gid': file_stat.st_gid,
                'group_name': self.get_group_name(file_stat.st_gid),
                'permissions': self.get_file_permissions(file_stat.st_mode),
                'mode': oct(file_stat.st_mode),
            })
            
            # Advanced metadata
            file_info.update({
                'inode': file_stat.st_ino,
                'device_id': file_stat.st_dev,
                'hard_links': file_stat.st_nlink,
            })
            
            # File hash (only for regular files to avoid errors)
            if file_path.is_file() and file_stat.st_size < 100 * 1024 * 1024:
                file_info['md5_hash'] = self.get_file_hash(file_path)
            else:
                file_info['md5_hash'] = None
                
            # Last accessed user
            file_info['last_accessed_user'] = self.get_last_accessed_user(file_path)
            
            # SCD2 fields
            file_info.update({
                'effective_date': current_time,
                'end_date': None,
                'is_current': True,
                'record_created_date': current_time,
                'record_created_by': 'file_tracker_system',
                'scan_id': scan_id
            })
            
            # Computed fields
            file_info.update({
                'age_days': (current_time - created_dt).days,
                'last_modified_days_ago': (current_time - modified_dt).days,
                'last_accessed_days_ago': (current_time - accessed_dt).days,
            })
            
            return file_info
            
        except (OSError, IOError, PermissionError) as e:
            return {
                'file_path': str(file_path.absolute()),
                'file_name': file_path.name,
                'error': str(e),
                'analyzable': False,
                'scan_id': scan_id
            }

    def get_current_records(self) -> pd.DataFrame:
        """Get all current records from the database"""
        query = text("""
            SELECT file_path, size_bytes, modified_timestamp, md5_hash, 
                   permissions, owner_name, group_name, surrogate_key
            FROM file_statistics_history 
            WHERE is_current = 1
        """)
        
        with self.engine.connect() as conn:
            return pd.read_sql(query, conn)

    def detect_changes(self, new_record: Dict, existing_record: pd.Series) -> Tuple[bool, List[str]]:
        """Detect if a file has changed and what changed"""
        changes = []
        
        # Key fields to monitor for changes
        comparison_fields = {
            'size_bytes': 'File size',
            'modified_timestamp': 'Last modified time',
            'md5_hash': 'File content (hash)',
            'permissions': 'File permissions',
            'owner_name': 'File owner',
            'group_name': 'File group'
        }
        
        for field, description in comparison_fields.items():
            new_value = new_record.get(field)
            old_value = existing_record.get(field)
            
            if new_value != old_value:
                changes.append(f"{description} changed from '{old_value}' to '{new_value}'")
        
        return len(changes) > 0, changes

    def close_current_record(self, surrogate_key: int, end_date: datetime, change_reason: str):
        """Close (expire) the current record by setting end_date and is_current=False"""
        update_query = text("""
            UPDATE file_statistics_history 
            SET end_date = :end_date, 
                is_current = 0,
                change_reason = :change_reason
            WHERE surrogate_key = :surrogate_key
        """)
        
        with self.engine.connect() as conn:
            conn.execute(update_query, {
                'end_date': end_date,
                'change_reason': change_reason,
                'surrogate_key': surrogate_key
            })
            conn.commit()

    def insert_new_record(self, record: Dict):
        """Insert a new record into the database"""
        # Remove any fields that don't exist in the table
        table_columns = [col.name for col in self.file_stats_table.columns]
        filtered_record = {k: v for k, v in record.items() if k in table_columns}
        
        with self.engine.connect() as conn:
            conn.execute(self.file_stats_table.insert(), filtered_record)
            conn.commit()

    def process_scd2_updates(self, new_records: List[Dict], scan_id: str):
        """Process SCD2 updates for all new records"""
        current_records_df = self.get_current_records()
        current_time = datetime.utcnow()
        
        stats = {
            'new_files': 0,
            'updated_files': 0,
            'unchanged_files': 0,
            'deleted_files': 0
        }
        
        # Create lookup dictionary for existing records
        existing_lookup = {}
        if not current_records_df.empty:
            for _, row in current_records_df.iterrows():
                existing_lookup[row['file_path']] = row
        
        # Process new/updated records
        new_file_paths = set()
        for record in new_records:
            if 'error' in record:  # Skip error records
                continue
                
            file_path = record['file_path']
            new_file_paths.add(file_path)
            
            if file_path in existing_lookup:
                # File exists, check for changes
                existing_record = existing_lookup[file_path]
                has_changed, changes = self.detect_changes(record, existing_record)
                
                if has_changed:
                    # Close current record
                    change_reason = "; ".join(changes)
                    self.close_current_record(
                        existing_record['surrogate_key'], 
                        current_time, 
                        change_reason
                    )
                    
                    # Insert new record
                    record['change_reason'] = f"Updated: {change_reason}"
                    self.insert_new_record(record)
                    stats['updated_files'] += 1
                    print(f"Updated: {file_path}")
                else:
                    stats['unchanged_files'] += 1
            else:
                # New file
                record['change_reason'] = "New file discovered"
                self.insert_new_record(record)
                stats['new_files'] += 1
                print(f"New file: {file_path}")
        
        # Handle deleted files (existed before but not in current scan)
        if not current_records_df.empty:
            existing_file_paths = set(current_records_df['file_path'])
            deleted_paths = existing_file_paths - new_file_paths
            
            for deleted_path in deleted_paths:
                existing_record = existing_lookup[deleted_path]
                self.close_current_record(
                    existing_record['surrogate_key'],
                    current_time,
                    "File deleted or no longer accessible"
                )
                stats['deleted_files'] += 1
                print(f"Deleted: {deleted_path}")
        
        return stats

    def create_scan_record(self, directory_path: str, recursive: bool, include_hidden: bool) -> str:
        """Create a new scan record and return scan_id"""
        scan_id = str(uuid.uuid4())
        scan_record = {
            'scan_id': scan_id,
            'scan_start_time': datetime.utcnow(),
            'directory_scanned': directory_path,
            'recursive_scan': recursive,
            'include_hidden': include_hidden,
            'scan_status': 'running'
        }
        
        with self.engine.connect() as conn:
            conn.execute(self.scan_metadata_table.insert(), scan_record)
            conn.commit()
        
        return scan_id

    def update_scan_record(self, scan_id: str, **updates):
        """Update scan record with completion information"""
        update_query = text(f"""
            UPDATE scan_metadata 
            SET {', '.join([f"{k} = :{k}" for k in updates.keys()])}
            WHERE scan_id = :scan_id
        """)
        
        updates['scan_id'] = scan_id
        with self.engine.connect() as conn:
            conn.execute(update_query, updates)
            conn.commit()

    def scan_directory(self, directory_path: str, recursive: bool = True, include_hidden: bool = False):
        """Main method to scan directory and update database with SCD2 tracking"""
        directory = Path(directory_path)
        
        if not directory.exists():
            raise FileNotFoundError(f"Directory not found: {directory_path}")
        
        if not directory.is_dir():
            raise NotADirectoryError(f"Path is not a directory: {directory_path}")
        
        # Create scan record
        scan_id = self.create_scan_record(str(directory.absolute()), recursive, include_hidden)
        
        try:
            print(f"Starting scan: {scan_id}")
            print(f"Directory: {directory.absolute()}")
            print(f"Recursive: {recursive}, Include hidden: {include_hidden}")
            
            # Collect files to analyze
            if recursive:
                files = directory.rglob("*")
            else:
                files = directory.iterdir()
            
            # Filter hidden files if needed
            if not include_hidden:
                files = [f for f in files if not any(part.startswith('.') 
                        for part in f.parts[len(directory.parts):])]
            
            # Analyze all files
            file_data = []
            total_files = 0
            analyzed_files = 0
            error_count = 0
            
            for file_path in files:
                total_files += 1
                if total_files % 100 == 0:
                    print(f"Processed {total_files} files...")
                
                file_info = self.analyze_file(file_path, scan_id)
                file_data.append(file_info)
                
                if file_info.get('analyzable', True):
                    analyzed_files += 1
                else:
                    error_count += 1
            
            print(f"\nProcessing SCD2 updates...")
            scd2_stats = self.process_scd2_updates(file_data, scan_id)
            
            # Update scan record with completion information
            self.update_scan_record(
                scan_id,
                scan_end_time=datetime.utcnow(),
                total_files_found=total_files,
                total_files_analyzed=analyzed_files,
                total_errors=error_count,
                scan_status='completed'
            )
            
            print(f"\nScan completed successfully!")
            print(f"Scan ID: {scan_id}")
            print(f"Total files found: {total_files}")
            print(f"Successfully analyzed: {analyzed_files}")
            print(f"Errors: {error_count}")
            print(f"New files: {scd2_stats['new_files']}")
            print(f"Updated files: {scd2_stats['updated_files']}")
            print(f"Unchanged files: {scd2_stats['unchanged_files']}")
            print(f"Deleted files: {scd2_stats['deleted_files']}")
            
            return scan_id, scd2_stats
            
        except Exception as e:
            # Update scan record with error
            self.update_scan_record(
                scan_id,
                scan_end_time=datetime.utcnow(),
                scan_status='failed',
                error_message=str(e)
            )
            raise

    def get_file_history(self, file_path: str) -> pd.DataFrame:
        """Get complete history for a specific file"""
        query = text("""
            SELECT * FROM file_statistics_history 
            WHERE file_path = :file_path 
            ORDER BY effective_date DESC
        """)
        
        with self.engine.connect() as conn:
            return pd.read_sql(query, conn, params={'file_path': file_path})

    def get_current_statistics(self) -> pd.DataFrame:
        """Get current statistics for all files"""
        query = text("""
            SELECT * FROM file_statistics_history 
            WHERE is_current = 1 
            ORDER BY file_path
        """)
        
        with self.engine.connect() as conn:
            return pd.read_sql(query, conn)

    def generate_change_report(self, days_back: int = 7) -> pd.DataFrame:
        """Generate a report of all changes in the last N days"""
        query = text("""
            SELECT file_path, file_name, effective_date, end_date, 
                   change_reason, is_current, scan_id
            FROM file_statistics_history 
            WHERE record_created_date >= DATEADD(day, -:days_back, GETUTCDATE())
            ORDER BY record_created_date DESC
        """)
        
        with self.engine.connect() as conn:
            return pd.read_sql(query, conn, params={'days_back': days_back})

def main():
    """Main function for command-line usage"""
    import argparse
    
    parser = argparse.ArgumentParser(description="File Statistics Tracker with SQL Server SCD2")
    parser.add_argument("directory", help="Directory to analyze")
    parser.add_argument("--server", required=True, help="SQL Server instance")
    parser.add_argument("--database", required=True, help="Database name")
    parser.add_argument("--username", help="Database username")
    parser.add_argument("--password", help="Database password")
    parser.add_argument("--recursive", "-r", action="store_true", help="Scan recursively")
    parser.add_argument("--hidden", action="store_true", help="Include hidden files")
    parser.add_argument("--report", action="store_true", help="Generate change report")
    parser.add_argument("--days", type=int, default=7, help="Days back for report")
    
    args = parser.parse_args()
    
    try:
        # Create database configuration
        db_config = DatabaseConfig(
            server=args.server,
            database=args.database,
            username=args.username,
            password=args.password,
            trusted_connection=not (args.username and args.password)
        )
        
        # Initialize tracker
        tracker = FileStatsTracker(db_config)
        
        if args.report:
            # Generate change report
            report = tracker.generate_change_report(args.days)
            print(f"\nChange Report (Last {args.days} days):")
            print(report.to_string(index=False))
        else:
            # Perform scan
            scan_id, stats = tracker.scan_directory(
                args.directory,
                recursive=args.recursive,
                include_hidden=args.hidden
            )
        
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

# Example usage
if __name__ == "__main__":
    if len(sys.argv) > 1:
        main()
    else:
        print("File Statistics Tracker with SQL Server SCD2")
        print("\nExample usage:")
        print("# Initialize tracker")
        print("db_config = DatabaseConfig(server='localhost', database='FileTracking')")
        print("tracker = FileStatsTracker(db_config)")
        print("\n# Scan directory")
        print("scan_id, stats = tracker.scan_directory('/path/to/scan')")
        print("\n# Get file history")
        print("history = tracker.get_file_history('/path/to/specific/file.txt')")
        print("\n# Generate change report")
        print("changes = tracker.generate_change_report(days_back=30)")