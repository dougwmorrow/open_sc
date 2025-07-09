#!/usr/bin/env python3
"""
File Statistics Tracker
Analyzes all files in a directory and creates a comprehensive pandas DataFrame
with detailed file statistics including ownership, timestamps, and metadata.
"""

import os
import stat
import pwd
import grp
import hashlib
import mimetypes
from pathlib import Path
from datetime import datetime
import pandas as pd
import platform
import subprocess
import sys

def get_file_hash(file_path, hash_type='md5'):
    """Calculate file hash (MD5 by default)"""
    try:
        hash_obj = hashlib.new(hash_type)
        with open(file_path, 'rb') as f:
            for chunk in iter(lambda: f.read(4096), b""):
                hash_obj.update(chunk)
        return hash_obj.hexdigest()
    except (IOError, OSError):
        return None

def get_user_name(uid):
    """Get username from UID"""
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return f"UID:{uid}"

def get_group_name(gid):
    """Get group name from GID"""
    try:
        return grp.getgrgid(gid).gr_name
    except KeyError:
        return f"GID:{gid}"

def get_file_permissions(mode):
    """Convert file mode to readable permissions string"""
    return stat.filemode(mode)

def get_mime_type(file_path):
    """Get MIME type of file"""
    mime_type, _ = mimetypes.guess_type(file_path)
    return mime_type or 'unknown'

def get_last_accessed_user(file_path):
    """
    Attempt to get the last user who accessed the file.
    Note: This is system-dependent and may not always be available.
    """
    try:
        if platform.system() == "Linux":
            # On Linux, we can try to use lsof to see who has the file open
            result = subprocess.run(['lsof', str(file_path)], 
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0 and result.stdout:
                lines = result.stdout.strip().split('\n')
                if len(lines) > 1:  # Skip header
                    return lines[1].split()[2]  # Username is typically the 3rd column
    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError):
        pass
    return "Unknown"

def analyze_file(file_path):
    """Analyze a single file and return its statistics"""
    try:
        file_stat = file_path.stat()
        
        # Basic file information
        file_info = {
            'file_path': str(file_path.absolute()),
            'file_name': file_path.name,
            'file_extension': file_path.suffix.lower(),
            'directory': str(file_path.parent),
            'is_file': file_path.is_file(),
            'is_directory': file_path.is_dir(),
            'is_symlink': file_path.is_symlink(),
        }
        
        # File size and type
        file_info.update({
            'size_bytes': file_stat.st_size,
            'size_kb': round(file_stat.st_size / 1024, 2),
            'size_mb': round(file_stat.st_size / (1024 * 1024), 2),
            'mime_type': get_mime_type(file_path),
        })
        
        # Timestamps
        file_info.update({
            'created_timestamp': file_stat.st_ctime,
            'modified_timestamp': file_stat.st_mtime,
            'accessed_timestamp': file_stat.st_atime,
            'created_datetime': datetime.fromtimestamp(file_stat.st_ctime),
            'modified_datetime': datetime.fromtimestamp(file_stat.st_mtime),
            'accessed_datetime': datetime.fromtimestamp(file_stat.st_atime),
        })
        
        # Ownership and permissions
        file_info.update({
            'owner_uid': file_stat.st_uid,
            'owner_name': get_user_name(file_stat.st_uid),
            'group_gid': file_stat.st_gid,
            'group_name': get_group_name(file_stat.st_gid),
            'permissions': get_file_permissions(file_stat.st_mode),
            'mode': oct(file_stat.st_mode),
        })
        
        # Advanced metadata
        file_info.update({
            'inode': file_stat.st_ino,
            'device_id': file_stat.st_dev,
            'hard_links': file_stat.st_nlink,
        })
        
        # File hash (only for regular files to avoid errors)
        if file_path.is_file() and file_stat.st_size < 100 * 1024 * 1024:  # Skip very large files
            file_info['md5_hash'] = get_file_hash(file_path)
        else:
            file_info['md5_hash'] = None
            
        # Last accessed user (best effort)
        file_info['last_accessed_user'] = get_last_accessed_user(file_path)
        
        return file_info
        
    except (OSError, IOError, PermissionError) as e:
        # Return minimal info for files we can't fully analyze
        return {
            'file_path': str(file_path.absolute()),
            'file_name': file_path.name,
            'error': str(e),
            'analyzable': False
        }

def scan_directory(directory_path, recursive=True, include_hidden=False):
    """
    Scan directory and return comprehensive file statistics
    
    Args:
        directory_path (str): Path to directory to scan
        recursive (bool): Whether to scan subdirectories
        include_hidden (bool): Whether to include hidden files
    
    Returns:
        pandas.DataFrame: DataFrame with file statistics
    """
    directory = Path(directory_path)
    
    if not directory.exists():
        raise FileNotFoundError(f"Directory not found: {directory_path}")
    
    if not directory.is_dir():
        raise NotADirectoryError(f"Path is not a directory: {directory_path}")
    
    print(f"Scanning directory: {directory.absolute()}")
    print(f"Recursive: {recursive}, Include hidden: {include_hidden}")
    
    file_data = []
    
    # Choose the appropriate method based on recursive flag
    if recursive:
        pattern = "**/*" if include_hidden else "**/*"
        files = directory.rglob("*")
    else:
        files = directory.iterdir()
    
    # Filter hidden files if needed
    if not include_hidden:
        files = [f for f in files if not any(part.startswith('.') for part in f.parts[len(directory.parts):])]
    
    total_files = 0
    analyzed_files = 0
    
    for file_path in files:
        total_files += 1
        if total_files % 100 == 0:
            print(f"Processed {total_files} files...")
        
        file_info = analyze_file(file_path)
        file_data.append(file_info)
        
        if file_info.get('analyzable', True):
            analyzed_files += 1
    
    print(f"\nScan complete!")
    print(f"Total files/directories found: {total_files}")
    print(f"Successfully analyzed: {analyzed_files}")
    print(f"Errors/Permission denied: {total_files - analyzed_files}")
    
    # Create DataFrame
    df = pd.DataFrame(file_data)
    
    # Add some computed columns
    if not df.empty and 'created_datetime' in df.columns:
        df['age_days'] = (datetime.now() - pd.to_datetime(df['created_datetime'], errors='coerce')).dt.days
        df['last_modified_days_ago'] = (datetime.now() - pd.to_datetime(df['modified_datetime'], errors='coerce')).dt.days
        df['last_accessed_days_ago'] = (datetime.now() - pd.to_datetime(df['accessed_datetime'], errors='coerce')).dt.days
    
    return df

def generate_summary_stats(df):
    """Generate summary statistics from the file DataFrame"""
    if df.empty:
        return "No files found to analyze."
    
    summary = []
    summary.append("FILE ANALYSIS SUMMARY")
    summary.append("=" * 50)
    
    # Basic counts
    total_files = len(df)
    actual_files = len(df[df.get('is_file', False) == True])
    directories = len(df[df.get('is_directory', False) == True])
    
    summary.append(f"Total entries: {total_files}")
    summary.append(f"Files: {actual_files}")
    summary.append(f"Directories: {directories}")
    
    if 'size_mb' in df.columns:
        total_size_mb = df['size_mb'].sum()
        summary.append(f"Total size: {total_size_mb:.2f} MB")
        
        if actual_files > 0:
            avg_size_mb = df[df['is_file'] == True]['size_mb'].mean()
            summary.append(f"Average file size: {avg_size_mb:.2f} MB")
    
    # File types
    if 'file_extension' in df.columns:
        extensions = df['file_extension'].value_counts().head(10)
        summary.append("\nTop 10 file extensions:")
        for ext, count in extensions.items():
            summary.append(f"  {ext or '(no extension)'}: {count}")
    
    # Ownership
    if 'owner_name' in df.columns:
        owners = df['owner_name'].value_counts().head(5)
        summary.append("\nTop 5 file owners:")
        for owner, count in owners.items():
            summary.append(f"  {owner}: {count}")
    
    return "\n".join(summary)

def main():
    """Main function for command-line usage"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Analyze files in a directory")
    parser.add_argument("directory", help="Directory to analyze")
    parser.add_argument("--output", "-o", help="Output CSV file path")
    parser.add_argument("--recursive", "-r", action="store_true", help="Scan recursively")
    parser.add_argument("--hidden", action="store_true", help="Include hidden files")
    parser.add_argument("--summary", "-s", action="store_true", help="Show summary statistics")
    
    args = parser.parse_args()
    
    try:
        # Scan directory
        df = scan_directory(args.directory, 
                          recursive=args.recursive, 
                          include_hidden=args.hidden)
        
        # Show summary if requested
        if args.summary:
            print("\n" + generate_summary_stats(df))
        
        # Save to CSV if output path provided
        if args.output:
            df.to_csv(args.output, index=False)
            print(f"\nData saved to: {args.output}")
        
        return df
        
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

# Example usage
if __name__ == "__main__":
    # If run as script, use command line interface
    if len(sys.argv) > 1:
        main()
    else:
        # Example usage when imported
        print("File Statistics Tracker")
        print("Usage example:")
        print("  df = scan_directory('/path/to/directory')")
        print("  print(generate_summary_stats(df))")
        print("  df.to_csv('file_stats.csv')")