"""Gather all file paths from a specified directory."""

import os
import argparse


def gather_file_paths(directory: str, recursive: bool = True) -> list[str]:
    """Return a list of all file paths in the given directory.

    Args:
        directory: Path to the directory to scan.
        recursive: If True, include files in subdirectories.

    Returns:
        Sorted list of absolute file paths.
    """
    file_paths = []

    if recursive:
        for root, _, files in os.walk(directory):
            for filename in files:
                file_paths.append(os.path.join(root, filename))
    else:
        for entry in os.scandir(directory):
            if entry.is_file():
                file_paths.append(entry.path)

    return sorted(file_paths)


def main():
    parser = argparse.ArgumentParser(description="Gather all file paths from a directory.")
    parser.add_argument("directory", help="Path to the directory to scan")
    parser.add_argument("--no-recursive", action="store_true", help="Only scan the top-level directory")
    parser.add_argument("-o", "--output", help="Optional output file to write results to")
    args = parser.parse_args()

    directory = os.path.abspath(args.directory)

    if not os.path.isdir(directory):
        print(f"Error: '{directory}' is not a valid directory.")
        return

    file_paths = gather_file_paths(directory, recursive=not args.no_recursive)

    print(f"Found {len(file_paths)} file(s) in '{directory}':\n")
    for path in file_paths:
        print(path)

    if args.output:
        with open(args.output, "w") as f:
            f.write("\n".join(file_paths))
        print(f"\nResults written to '{args.output}'")


if __name__ == "__main__":
    main()