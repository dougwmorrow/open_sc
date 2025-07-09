#!/usr/bin/env python3
"""
Enhanced File Statistics Tracker
Analyzes all files in a directory and creates a comprehensive pandas DataFrame
with detailed file statistics including ownership, timestamps, metadata, and advanced analysis.

Based on comprehensive research of Python's file tracking capabilities.
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
from concurrent.futures import ProcessPoolExecutor, as_completed
import logging
from typing import Dict, List, Optional, Union
import time

# Optional advanced libraries with graceful fallbacks
try:
    import magic
    HAS_PYTHON_MAGIC = True
except ImportError:
    HAS_PYTHON_MAGIC = False

try:
    import xattr
    HAS_XATTR = True
except ImportError:
    HAS_XATTR = False

try:
    import chardet
    HAS_CHARDET = True
except ImportError:
    HAS_CHARDET = False

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class EnhancedFileTracker:
    """Enhanced file tracking with advanced metadata extraction capabilities"""
    
    def __init__(self, use_parallel=True, max_workers=None, hash_algorithm='sha256', 
                 hash_large_files=False, large_file_threshold=100*1024*1024):
        """
        Initialize the enhanced file tracker
        
        Args:
            use_parallel: Whether to use parallel processing
            max_workers: Number of worker processes (None for auto)
            hash_algorithm: Hash algorithm to use (sha256 recommended over md5)
            hash_large_files: Whether to hash files larger than threshold
            large_file_threshold: Size threshold for large files in bytes
        """
        self.use_parallel = use_parallel
        self.max_workers = max_workers
        self.hash_algorithm = hash_algorithm
        self.hash_large_files = hash_large_files
        self.large_file_threshold = large_file_threshold
        self.system = platform.system()
        
        # Platform-specific initialization
        self._init_platform_specific()
    
    def _init_platform_specific(self):
        """Initialize platform-specific capabilities"""
        self.can_get_creation_time = False
        self.has_extended_attrs = False
        
        if self.system == "Windows":
            self.can_get_creation_time = True
            try:
                import win32security
                self.has_win32 = True
            except ImportError:
                self.has_win32 = False
        elif self.system == "Darwin":  # macOS
            self.can_get_creation_time = True
            self.has_extended_attrs = HAS_XATTR
        elif self.system == "Linux":
            self.has_extended_attrs = HAS_XATTR
    
    def get_file_hash(self, file_path: Path, chunk_size: int = 8192) -> Optional[str]:
        """
        Calculate file hash using specified algorithm with streaming for large files
        
        Args:
            file_path: Path to file
            chunk_size: Chunk size for reading large files
            
        Returns:
            Hash string or None if error
        """
        try:
            # Skip hashing large files unless explicitly enabled
            if not self.hash_large_files and file_path.stat().st_size > self.large_file_threshold:
                return None
                
            hash_obj = hashlib.new(self.hash_algorithm)
            with open(file_path, 'rb') as f:
                while chunk := f.read(chunk_size):
                    hash_obj.update(chunk)
            return hash_obj.hexdigest()
        except (IOError, OSError, ValueError) as e:
            logger.debug(f"Error calculating hash for {file_path}: {e}")
            return None

    def get_user_name(self, uid: int) -> str:
        """Get username from UID with error handling"""
        try:
            return pwd.getpwuid(uid).pw_name
        except (KeyError, OSError):
            return f"UID:{uid}"

    def get_group_name(self, gid: int) -> str:
        """Get group name from GID with error handling"""
        try:
            return grp.getgrgid(gid).gr_name
        except (KeyError, OSError):
            return f"GID:{gid}"

    def get_enhanced_mime_type(self, file_path: Path) -> Dict[str, str]:
        """
        Get MIME type using multiple methods for accuracy
        
        Returns:
            Dictionary with mime_type and detection_method
        """
        result = {'mime_type': 'unknown', 'detection_method': 'none'}
        
        # Try python-magic first (more accurate)
        if HAS_PYTHON_MAGIC and file_path.is_file():
            try:
                mime_type = magic.from_file(str(file_path), mime=True)
                result = {'mime_type': mime_type, 'detection_method': 'python-magic'}
            except Exception as e:
                logger.debug(f"python-magic failed for {file_path}: {e}")
        
        # Fallback to mimetypes
        if result['mime_type'] == 'unknown':
            mime_type, _ = mimetypes.guess_type(str(file_path))
            if mime_type:
                result = {'mime_type': mime_type, 'detection_method': 'mimetypes'}
        
        return result

    def get_creation_time(self, file_stat: os.stat_result) -> Optional[float]:
        """
        Get file creation time with platform-specific handling
        
        Returns:
            Creation timestamp or None if unavailable
        """
        if self.system == "Windows":
            return file_stat.st_ctime
        elif self.system == "Darwin":
            # macOS has st_birthtime
            return getattr(file_stat, 'st_birthtime', None)
        else:
            # Linux: st_ctime is metadata change time, not creation time
            return None

    def get_extended_attributes(self, file_path: Path) -> Dict[str, str]:
        """
        Get extended filesystem attributes where available
        
        Returns:
            Dictionary of extended attributes
        """
        attrs = {}
        
        if not self.has_extended_attrs or not HAS_XATTR:
            return attrs
            
        try:
            for attr_name in xattr.listxattr(str(file_path)):
                try:
                    attr_value = xattr.getxattr(str(file_path), attr_name)
                    # Convert bytes to string, handling binary data
                    if isinstance(attr_value, bytes):
                        try:
                            attr_value = attr_value.decode('utf-8')
                        except UnicodeDecodeError:
                            attr_value = f"<binary data: {len(attr_value)} bytes>"
                    attrs[attr_name] = str(attr_value)
                except (OSError, UnicodeDecodeError) as e:
                    attrs[attr_name] = f"<error: {e}>"
        except OSError:
            pass  # Extended attributes not supported or accessible
            
        return attrs

    def get_file_encoding(self, file_path: Path) -> Optional[str]:
        """
        Detect text file encoding using chardet
        
        Returns:
            Detected encoding or None
        """
        if not HAS_CHARDET or not file_path.is_file():
            return None
            
        try:
            # Only check text-like files and limit sample size
            mime_info = self.get_enhanced_mime_type(file_path)
            if not mime_info['mime_type'].startswith('text/'):
                return None
                
            with open(file_path, 'rb') as f:
                # Read first 10KB for encoding detection
                sample = f.read(10240)
                
            if sample:
                result = chardet.detect(sample)
                return result.get('encoding')
        except Exception as e:
            logger.debug(f"Encoding detection failed for {file_path}: {e}")
            
        return None

    def analyze_file(self, file_path: Path) -> Dict:
        """
        Analyze a single file and return comprehensive statistics
        
        Args:
            file_path: Path object for the file to analyze
            
        Returns:
            Dictionary with file analysis results
        """
        try:
            # Use lstat to avoid following symlinks initially
            file_stat = file_path.lstat()
            
            # Basic file information
            file_info = {
                'file_path': str(file_path.absolute()),
                'file_name': file_path.name,
                'file_extension': file_path.suffix.lower(),
                'directory': str(file_path.parent),
                'is_file': file_path.is_file(),
                'is_directory': file_path.is_dir(),
                'is_symlink': file_path.is_symlink(),
                'is_mount_point': file_path.is_mount() if hasattr(file_path, 'is_mount') else False,
            }
            
            # File size information
            file_info.update({
                'size_bytes': file_stat.st_size,
                'size_kb': round(file_stat.st_size / 1024, 2),
                'size_mb': round(file_stat.st_size / (1024 * 1024), 4),
                'size_gb': round(file_stat.st_size / (1024 * 1024 * 1024), 6),
            })
            
            # Enhanced MIME type detection
            mime_info = self.get_enhanced_mime_type(file_path)
            file_info.update(mime_info)
            
            # Comprehensive timestamp handling
            creation_time = self.get_creation_time(file_stat)
            file_info.update({
                'created_timestamp': creation_time,
                'modified_timestamp': file_stat.st_mtime,
                'accessed_timestamp': file_stat.st_atime,
                'metadata_changed_timestamp': file_stat.st_ctime,  # Always metadata change time on Unix
                'created_datetime': datetime.fromtimestamp(creation_time) if creation_time else None,
                'modified_datetime': datetime.fromtimestamp(file_stat.st_mtime),
                'accessed_datetime': datetime.fromtimestamp(file_stat.st_atime),
                'metadata_changed_datetime': datetime.fromtimestamp(file_stat.st_ctime),
                'creation_time_available': creation_time is not None,
            })
            
            # Ownership and permissions
            file_info.update({
                'owner_uid': file_stat.st_uid,
                'owner_name': self.get_user_name(file_stat.st_uid),
                'group_gid': file_stat.st_gid,
                'group_name': self.get_group_name(file_stat.st_gid),
                'permissions_octal': oct(file_stat.st_mode)[-3:],
                'permissions_string': stat.filemode(file_stat.st_mode),
                'is_readable': os.access(file_path, os.R_OK),
                'is_writable': os.access(file_path, os.W_OK),
                'is_executable': os.access(file_path, os.X_OK),
            })
            
            # Advanced metadata
            file_info.update({
                'inode': file_stat.st_ino,
                'device_id': file_stat.st_dev,
                'hard_links_count': file_stat.st_nlink,
                'is_special_file': stat.S_ISCHR(file_stat.st_mode) or stat.S_ISBLK(file_stat.st_mode),
                'is_fifo': stat.S_ISFIFO(file_stat.st_mode),
                'is_socket': stat.S_ISSOCK(file_stat.st_mode),
            })
            
            # File hash for regular files
            if file_path.is_file() and not file_path.is_symlink():
                hash_value = self.get_file_hash(file_path)
                file_info[f'{self.hash_algorithm}_hash'] = hash_value
            else:
                file_info[f'{self.hash_algorithm}_hash'] = None
            
            # Extended attributes
            extended_attrs = self.get_extended_attributes(file_path)
            file_info['extended_attributes'] = str(extended_attrs) if extended_attrs else None
            file_info['has_extended_attributes'] = bool(extended_attrs)
            
            # Text file encoding detection
            if file_path.is_file() and mime_info['mime_type'].startswith('text/'):
                file_info['text_encoding'] = self.get_file_encoding(file_path)
            else:
                file_info['text_encoding'] = None
            
            # Analysis metadata
            file_info.update({
                'analysis_timestamp': datetime.now(),
                'analysis_successful': True,
                'analysis_errors': None,
                'platform': self.system,
            })
            
            return file_info
            
        except (OSError, IOError, PermissionError) as e:
            # Return minimal info for files we can't fully analyze
            return {
                'file_path': str(file_path.absolute()),
                'file_name': file_path.name,
                'analysis_successful': False,
                'analysis_errors': str(e),
                'analysis_timestamp': datetime.now(),
                'platform': self.system,
            }

    def scan_directory_efficient(self, directory_path: Union[str, Path], 
                                recursive: bool = True, 
                                include_hidden: bool = False,
                                follow_symlinks: bool = False) -> List[Dict]:
        """
        Efficiently scan directory using os.scandir for optimal performance
        
        Args:
            directory_path: Directory to scan
            recursive: Whether to scan subdirectories
            include_hidden: Whether to include hidden files
            follow_symlinks: Whether to follow symbolic links
            
        Returns:
            List of file analysis dictionaries
        """
        directory = Path(directory_path)
        
        if not directory.exists():
            raise FileNotFoundError(f"Directory not found: {directory_path}")
        
        if not directory.is_dir():
            raise NotADirectoryError(f"Path is not a directory: {directory_path}")
        
        logger.info(f"Scanning directory: {directory.absolute()}")
        logger.info(f"Recursive: {recursive}, Include hidden: {include_hidden}")
        
        file_paths = []
        
        def should_include(path: Path) -> bool:
            """Determine if a file should be included in analysis"""
            if not include_hidden and any(part.startswith('.') for part in path.parts[len(directory.parts):]):
                return False
            return True
        
        # Use os.scandir for performance (2-20x faster than pathlib)
        def scan_recursive(scan_dir: Path):
            try:
                with os.scandir(scan_dir) as entries:
                    for entry in entries:
                        entry_path = Path(entry.path)
                        
                        if not should_include(entry_path):
                            continue
                            
                        file_paths.append(entry_path)
                        
                        # Recurse into directories
                        if recursive and entry.is_dir(follow_symlinks=follow_symlinks):
                            scan_recursive(entry_path)
                            
            except (OSError, PermissionError) as e:
                logger.warning(f"Cannot access directory {scan_dir}: {e}")
        
        # Start scanning
        start_time = time.time()
        scan_recursive(directory)
        scan_time = time.time() - start_time
        
        logger.info(f"Directory scan completed in {scan_time:.2f} seconds")
        logger.info(f"Found {len(file_paths)} files/directories")
        
        # Analyze files
        if self.use_parallel and len(file_paths) > 10:
            return self._analyze_files_parallel(file_paths)
        else:
            return self._analyze_files_sequential(file_paths)

    def _analyze_files_sequential(self, file_paths: List[Path]) -> List[Dict]:
        """Analyze files sequentially"""
        results = []
        total = len(file_paths)
        
        for i, file_path in enumerate(file_paths, 1):
            if i % 100 == 0:
                logger.info(f"Analyzed {i}/{total} files ({i/total*100:.1f}%)")
            
            results.append(self.analyze_file(file_path))
        
        return results

    def _analyze_files_parallel(self, file_paths: List[Path]) -> List[Dict]:
        """Analyze files in parallel using ProcessPoolExecutor"""
        results = []
        total = len(file_paths)
        completed = 0
        
        logger.info(f"Starting parallel analysis with {self.max_workers or 'auto'} workers")
        
        with ProcessPoolExecutor(max_workers=self.max_workers) as executor:
            # Submit all tasks
            future_to_path = {
                executor.submit(analyze_file_worker, file_path, self.hash_algorithm, 
                               self.hash_large_files, self.large_file_threshold): file_path 
                for file_path in file_paths
            }
            
            # Collect results as they complete
            for future in as_completed(future_to_path):
                try:
                    result = future.result()
                    results.append(result)
                    completed += 1
                    
                    if completed % 100 == 0:
                        logger.info(f"Analyzed {completed}/{total} files ({completed/total*100:.1f}%)")
                        
                except Exception as e:
                    file_path = future_to_path[future]
                    logger.error(f"Error analyzing {file_path}: {e}")
                    results.append({
                        'file_path': str(file_path),
                        'analysis_successful': False,
                        'analysis_errors': str(e),
                        'analysis_timestamp': datetime.now(),
                    })
        
        return results

    def create_dataframe(self, results: List[Dict]) -> pd.DataFrame:
        """Create and enhance pandas DataFrame from analysis results"""
        df = pd.DataFrame(results)
        
        if df.empty:
            return df
        
        # Add computed columns
        now = datetime.now()
        
        # Age calculations (only for files with creation time)
        if 'created_datetime' in df.columns:
            df['age_days'] = (now - pd.to_datetime(df['created_datetime'], errors='coerce')).dt.days
        
        if 'modified_datetime' in df.columns:
            df['last_modified_days_ago'] = (now - pd.to_datetime(df['modified_datetime'], errors='coerce')).dt.days
        
        if 'accessed_datetime' in df.columns:
            df['last_accessed_days_ago'] = (now - pd.to_datetime(df['accessed_datetime'], errors='coerce')).dt.days
        
        # File size categories
        if 'size_bytes' in df.columns:
            df['size_category'] = pd.cut(df['size_bytes'], 
                                       bins=[0, 1024, 1024*1024, 100*1024*1024, float('inf')],
                                       labels=['Small (<1KB)', 'Medium (1KB-1MB)', 
                                              'Large (1MB-100MB)', 'Very Large (>100MB)'],
                                       include_lowest=True)
        
        return df

def analyze_file_worker(file_path: Path, hash_algorithm: str, 
                       hash_large_files: bool, large_file_threshold: int) -> Dict:
    """Worker function for parallel file analysis"""
    tracker = EnhancedFileTracker(
        use_parallel=False,  # Avoid nested parallelization
        hash_algorithm=hash_algorithm,
        hash_large_files=hash_large_files,
        large_file_threshold=large_file_threshold
    )
    return tracker.analyze_file(file_path)

def generate_enhanced_summary(df: pd.DataFrame) -> str:
    """Generate comprehensive summary statistics from the enhanced DataFrame"""
    if df.empty:
        return "No files found to analyze."
    
    summary = []
    summary.append("ENHANCED FILE ANALYSIS SUMMARY")
    summary.append("=" * 60)
    
    # Basic counts
    total_entries = len(df)
    successful_analyses = len(df[df.get('analysis_successful', True) == True])
    failed_analyses = total_entries - successful_analyses
    
    if 'is_file' in df.columns:
        actual_files = len(df[df['is_file'] == True])
        directories = len(df[df.get('is_directory', False) == True])
        symlinks = len(df[df.get('is_symlink', False) == True])
    else:
        actual_files = directories = symlinks = 0
    
    summary.append(f"Total entries: {total_entries}")
    summary.append(f"Successful analyses: {successful_analyses}")
    summary.append(f"Failed analyses: {failed_analyses}")
    summary.append(f"Files: {actual_files}")
    summary.append(f"Directories: {directories}")
    summary.append(f"Symbolic links: {symlinks}")
    
    # Size analysis
    if 'size_mb' in df.columns and actual_files > 0:
        file_df = df[df['is_file'] == True]
        total_size_gb = file_df['size_mb'].sum() / 1024
        avg_size_mb = file_df['size_mb'].mean()
        median_size_mb = file_df['size_mb'].median()
        max_size_mb = file_df['size_mb'].max()
        
        summary.append(f"\nSIZE STATISTICS:")
        summary.append(f"Total size: {total_size_gb:.2f} GB")
        summary.append(f"Average file size: {avg_size_mb:.2f} MB")
        summary.append(f"Median file size: {median_size_mb:.2f} MB")
        summary.append(f"Largest file: {max_size_mb:.2f} MB")
        
        # Size categories
        if 'size_category' in df.columns:
            size_dist = df['size_category'].value_counts()
            summary.append("\nSize distribution:")
            for category, count in size_dist.items():
                summary.append(f"  {category}: {count}")
    
    # File types and extensions
    if 'file_extension' in df.columns:
        extensions = df['file_extension'].value_counts().head(10)
        summary.append(f"\nTOP 10 FILE EXTENSIONS:")
        for ext, count in extensions.items():
            summary.append(f"  {ext or '(no extension)'}: {count}")
    
    if 'mime_type' in df.columns:
        mime_types = df['mime_type'].value_counts().head(5)
        summary.append(f"\nTOP 5 MIME TYPES:")
        for mime_type, count in mime_types.items():
            summary.append(f"  {mime_type}: {count}")
    
    # Ownership analysis
    if 'owner_name' in df.columns:
        owners = df['owner_name'].value_counts().head(5)
        summary.append(f"\nTOP 5 FILE OWNERS:")
        for owner, count in owners.items():
            summary.append(f"  {owner}: {count}")
    
    # Age analysis
    if 'age_days' in df.columns:
        valid_ages = df['age_days'].dropna()
        if not valid_ages.empty:
            summary.append(f"\nAGE STATISTICS:")
            summary.append(f"Average age: {valid_ages.mean():.1f} days")
            summary.append(f"Oldest file: {valid_ages.max():.0f} days")
            summary.append(f"Newest file: {valid_ages.min():.0f} days")
    
    # Platform-specific features
    creation_time_available = df.get('creation_time_available', pd.Series(dtype=bool)).sum()
    extended_attrs_count = df.get('has_extended_attributes', pd.Series(dtype=bool)).sum()
    
    summary.append(f"\nPLATFORM FEATURES:")
    summary.append(f"Files with creation time: {creation_time_available}")
    summary.append(f"Files with extended attributes: {extended_attrs_count}")
    
    # Hash algorithm used
    hash_cols = [col for col in df.columns if col.endswith('_hash')]
    if hash_cols:
        hash_algorithm = hash_cols[0].replace('_hash', '')
        hash_count = df[hash_cols[0]].notna().sum()
        summary.append(f"Files hashed ({hash_algorithm.upper()}): {hash_count}")
    
    return "\n".join(summary)

def main():
    """Enhanced main function with advanced options"""
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Enhanced File Statistics Tracker - Comprehensive file analysis tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s /home/user --output analysis.csv --summary
  %(prog)s /path/to/dir --recursive --parallel --hash-algorithm sha256
  %(prog)s . --include-hidden --no-hash-large --workers 4
        """
    )
    
    parser.add_argument("directory", help="Directory to analyze")
    parser.add_argument("--output", "-o", help="Output CSV file path")
    parser.add_argument("--recursive", "-r", action="store_true", default=True,
                       help="Scan recursively (default: True)")
    parser.add_argument("--no-recursive", dest="recursive", action="store_false",
                       help="Don't scan recursively")
    parser.add_argument("--include-hidden", action="store_true",
                       help="Include hidden files and directories")
    parser.add_argument("--follow-symlinks", action="store_true",
                       help="Follow symbolic links")
    parser.add_argument("--summary", "-s", action="store_true",
                       help="Show detailed summary statistics")
    parser.add_argument("--parallel", action="store_true", default=True,
                       help="Use parallel processing (default: True)")
    parser.add_argument("--no-parallel", dest="parallel", action="store_false",
                       help="Don't use parallel processing")
    parser.add_argument("--workers", "-w", type=int,
                       help="Number of worker processes (default: auto)")
    parser.add_argument("--hash-algorithm", choices=['md5', 'sha1', 'sha256', 'sha512', 'blake2b'],
                       default='sha256', help="Hash algorithm to use (default: sha256)")
    parser.add_argument("--hash-large-files", action="store_true",
                       help="Hash files larger than threshold (slower)")
    parser.add_argument("--large-file-threshold", type=int, default=100*1024*1024,
                       help="Large file threshold in bytes (default: 100MB)")
    parser.add_argument("--verbose", "-v", action="store_true",
                       help="Enable verbose logging")
    
    args = parser.parse_args()
    
    # Configure logging
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    try:
        # Initialize enhanced tracker
        tracker = EnhancedFileTracker(
            use_parallel=args.parallel,
            max_workers=args.workers,
            hash_algorithm=args.hash_algorithm,
            hash_large_files=args.hash_large_files,
            large_file_threshold=args.large_file_threshold
        )
        
        # Scan directory
        logger.info("Starting enhanced file analysis...")
        start_time = time.time()
        
        results = tracker.scan_directory_efficient(
            args.directory,
            recursive=args.recursive,
            include_hidden=args.include_hidden,
            follow_symlinks=args.follow_symlinks
        )
        
        # Create DataFrame
        df = tracker.create_dataframe(results)
        
        analysis_time = time.time() - start_time
        logger.info(f"Analysis completed in {analysis_time:.2f} seconds")
        
        # Show summary if requested
        if args.summary:
            print("\n" + generate_enhanced_summary(df))
        
        # Save to CSV if output path provided
        if args.output:
            df.to_csv(args.output, index=False)
            logger.info(f"Data saved to: {args.output}")
            logger.info(f"DataFrame shape: {df.shape}")
        
        return df
        
    except Exception as e:
        logger.error(f"Error: {e}")
        if args.verbose:
            import traceback
            traceback.print_exc()
        sys.exit(1)

# Example usage functions
def quick_scan(directory: str, output_file: Optional[str] = None) -> pd.DataFrame:
    """Quick scan function for programmatic use"""
    tracker = EnhancedFileTracker()
    results = tracker.scan_directory_efficient(directory)
    df = tracker.create_dataframe(results)
    
    if output_file:
        df.to_csv(output_file, index=False)
    
    return df

def detailed_scan(directory: str, **kwargs) -> pd.DataFrame:
    """Detailed scan with full options"""
    tracker = EnhancedFileTracker(**kwargs)
    results = tracker.scan_directory_efficient(directory, **kwargs)
    return tracker.create_dataframe(results)

if __name__ == "__main__":
    # Check for required dependencies
    missing_deps = []
    try:
        import pandas as pd
    except ImportError:
        missing_deps.append('pandas')
    
    if missing_deps:
        print(f"Missing required dependencies: {', '.join(missing_deps)}")
        print("Install with: pip install pandas")
        sys.exit(1)
    
    # Show info about optional dependencies
    optional_info = []
    if not HAS_PYTHON_MAGIC:
        optional_info.append("python-magic (for better MIME detection)")
    if not HAS_XATTR:
        optional_info.append("xattr (for extended attributes)")
    if not HAS_CHARDET:
        optional_info.append("chardet (for encoding detection)")
    
    if optional_info:
        print(f"Optional dependencies not installed: {', '.join(optional_info)}")
        print("Install with: pip install python-magic xattr chardet")
        print()
    
    # Run main function if called as script
    if len(sys.argv) > 1:
        main()
    else:
        # Example usage when imported
        print("Enhanced File Statistics Tracker")
        print("Usage examples:")
        print("  df = quick_scan('/path/to/directory')")
        print("  df = detailed_scan('/path/to/directory', hash_algorithm='sha256')")
        print("  print(generate_enhanced_summary(df))")
        print("  df.to_csv('enhanced_file_stats.csv')")