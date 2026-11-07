#!/usr/bin/env python3
"""Report actual Swift line coverage. Optional --minimum fails below a requested gate.
No source files are excluded: compiler-generated coverage entries are filtered by
whether their source path belongs to Sources/BarKeep.
"""
import argparse
import json
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('report',type=Path)
parser.add_argument('--minimum',type=float,default=0)
args = parser.parse_args()
report = json.loads(args.report.read_text())
files = [file for data in report['data'] for file in data['files'] if '/Sources/BarKeep/' in file['filename']]
if not files:
    sys.exit('No BarKeep production sources found in coverage report')
covered = sum(f['summary']['lines']['covered'] for f in files)
count = sum(f['summary']['lines']['count'] for f in files)
percent = 100 * covered / count if count else 0
for file in sorted(files,key=lambda f:f['filename']):
    lines=file['summary']['lines']
    print(f"{Path(file['filename']).name:38} {lines['covered']:5}/{lines['count']:<5} {lines['percent']:6.2f}%")
print(f"TOTAL {covered}/{count} lines: {percent:.2f}%")
if percent < args.minimum:
    sys.exit(f'Coverage is below the requested {args.minimum:g}% gate')
