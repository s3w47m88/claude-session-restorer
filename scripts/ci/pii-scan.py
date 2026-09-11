#!/usr/bin/env python3
"""
PII Scanner for CI/CD pipelines.
Scans tracked files for sensitive personal information.
"""

import re
import subprocess
import sys
from pathlib import Path

# Patterns to detect
PII_PATTERNS = [
    ("/Users/spencerhill", "home_path_spencer"),
    (r"[Ss]pencer [Hh]ill", "name_spencer_hill"),
    ("spencerhill", "username_spencerhill"),
    (r"\+1503\d{7}", "phone_plus1503"),
    (r"503-\d{3}-\d{4}", "phone_503_dash"),
    ("5036108759", "phone_5036108759"),
    ("5034336772", "phone_5034336772"),
    (r"[a-zA-Z0-9._%+-]+@protonmail\.com", "email_protonmail"),
    ("spencerdhill", "username_spencerdhill"),
    (r"/Users/[a-z][a-z0-9]*(?:/|['\"])", "generic_home_path"),
]

# Allow-list paths (relative to repo root)
ALLOW_LIST = [
    "scripts/ci/pii-scan.py",
    ".github/workflows/security.yml",
    ".gitleaks.toml",
]

def get_tracked_files():
    """Get all git-tracked files."""
    try:
        result = subprocess.run(
            ["git", "ls-files"],
            capture_output=True,
            text=True,
            check=True,
        )
        return [f for f in result.stdout.strip().split("\n") if f]
    except subprocess.CalledProcessError as e:
        print(f"Error running git ls-files: {e}", file=sys.stderr)
        sys.exit(1)

def is_allowed(filepath):
    """Check if file is in allow-list."""
    return filepath in ALLOW_LIST

def scan_file(filepath):
    """Scan a single file for PII patterns."""
    findings = []
    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            for line_num, line in enumerate(f, 1):
                for pattern, pattern_name in PII_PATTERNS:
                    if re.search(pattern, line):
                        findings.append({
                            "file": filepath,
                            "line": line_num,
                            "pattern": pattern_name,
                            "content": line.strip(),
                        })
    except (IOError, OSError) as e:
        print(f"Warning: Could not read {filepath}: {e}", file=sys.stderr)
    return findings

def main():
    """Main scanner function."""
    files = get_tracked_files()
    all_findings = []

    for filepath in files:
        if is_allowed(filepath):
            continue

        findings = scan_file(filepath)
        all_findings.extend(findings)

    # Report findings
    if all_findings:
        print("PII Scanner Results:")
        print("=" * 80)
        for finding in all_findings:
            print(
                f"{finding['file']}:{finding['line']}: {finding['pattern']} "
                f"('{finding['content'][:60]}...')"
                if len(finding['content']) > 60
                else f"{finding['file']}:{finding['line']}: {finding['pattern']} "
                f"('{finding['content']}')"
            )
        print("=" * 80)
        print(f"\nTotal findings: {len(all_findings)}")
        sys.exit(1)
    else:
        print("PII Scanner: No findings detected.")
        sys.exit(0)

if __name__ == "__main__":
    main()
