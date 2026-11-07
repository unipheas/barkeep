#!/usr/bin/env python3
"""Report actual Swift line coverage. Optional --minimum fails below a requested gate.
No source files are excluded: compiler-generated coverage entries are filtered by
whether their source path belongs to Sources/BarKeep.
"""
import hashlib
import argparse
import json
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('report',type=Path)
parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1] / 'Sources/BarKeep')
parser.add_argument('--minimum',type=float,default=0)
args = parser.parse_args()
report = json.loads(args.report.read_text())
files = [file for data in report['data'] for file in data['files'] if '/Sources/BarKeep/' in file['filename']]
if not files:
    sys.exit('No BarKeep production sources found in coverage report')
# Swift/LLVM omits coverage mappings for these generated static JSON initializers.
# Exact-content exceptions only: edits require fresh compiler evidence and review.
UNMAPPED_STATIC_INITIALIZERS = {'APICatalog.generated.swift': '6d477ac9dfe016a0d31d48f36bbc3784b2b7d0ac460b15f3a1f92ab7c537f4e1', 'StatusSchema.generated.swift': 'c7ac5353b2fe6e76e2ff05efde17640b8c9f032e83f1a50a580c11ae4b4f5fbb'}
expected = {str(p.relative_to(args.source_root)): p for p in args.source_root.rglob('*.swift')}
if not expected:
    sys.exit('No production Swift source inventory found')
reported = [f['filename'].split('/Sources/BarKeep/', 1)[1] for f in files]
if len(reported) != len(set(reported)):
    sys.exit('Duplicate production files in coverage report')
extra = set(reported) - set(expected)
missing = set(expected) - set(reported)
unexplained = {name for name in missing if
    hashlib.sha256(expected[name].read_bytes()).hexdigest() != UNMAPPED_STATIC_INITIALIZERS.get(name)}
if extra or unexplained:
    sys.exit(f'Coverage source inventory mismatch: missing={sorted(unexplained)}, unexpected={sorted(extra)}')
for name in sorted(missing):
    print(f'No LLVM file mapping (exact reviewed static initializer): {name}')
covered = sum(f['summary']['lines']['covered'] for f in files)
count = sum(f['summary']['lines']['count'] for f in files)
percent = 100 * covered / count if count else 0
for file in sorted(files,key=lambda f:f['filename']):
    lines=file['summary']['lines']
    print(f"{Path(file['filename']).name:38} {lines['covered']:5}/{lines['count']:<5} {lines['percent']:6.2f}%")
print(f"TOTAL {covered}/{count} lines: {percent:.2f}%")
if percent < args.minimum:
    sys.exit(f'Coverage is below the requested {args.minimum:g}% gate')
