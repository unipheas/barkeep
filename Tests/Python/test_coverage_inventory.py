"""Coverage inventory must not silently lose production sources."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / 'scripts/check-coverage.py'

class CoverageInventoryTests(unittest.TestCase):
    def run_gate(self, sources, reported):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'Sources/BarKeep'
            root.mkdir(parents=True)
            for name, text in sources.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            report = Path(temp) / 'report.json'
            report.write_text(json.dumps({'data': [{'files': [
                {'filename': str(root / name), 'summary': {'lines':
                 {'covered': 1, 'count': 1, 'percent': 100}}} for name in reported]}]}))
            return subprocess.run([sys.executable, str(CHECK), str(report),
                '--source-root', str(root), '--minimum', '100'], capture_output=True, text=True)

    def test_complete_nested_inventory_passes(self):
        self.assertEqual(self.run_gate({'Nested/A.swift': 'func a() {}'}, ['Nested/A.swift']).returncode, 0)

    def test_missing_nested_source_fails(self):
        result = self.run_gate({'A.swift': '', 'Nested/B.swift': ''}, ['A.swift'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Nested/B.swift', result.stderr)

    def test_unexpected_and_duplicate_reports_fail(self):
        self.assertNotEqual(self.run_gate({'A.swift': ''}, ['A.swift', 'B.swift']).returncode, 0)
        self.assertNotEqual(self.run_gate({'A.swift': ''}, ['A.swift', 'A.swift']).returncode, 0)

    def test_generated_exception_requires_exact_content(self):
        name = 'StatusSchema.generated.swift'
        exact = (ROOT / 'Sources/BarKeep' / name).read_text()
        self.assertEqual(self.run_gate({'A.swift': '', name: exact}, ['A.swift']).returncode, 0)
        self.assertNotEqual(self.run_gate({'A.swift': '', name: exact + '\nfunc added() {}'}, ['A.swift']).returncode, 0)

    def test_empty_source_inventory_fails(self):
        self.assertNotEqual(self.run_gate({}, ['A.swift']).returncode, 0)
