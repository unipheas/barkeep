#!/usr/bin/env python3
"""Fail-closed, single-object whole-source Swift coverage gate (macOS)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def digest():
    value = hashlib.sha256()
    for source in sorted((ROOT / 'Sources/BarKeep').glob('*.swift')):
        value.update(str(source.relative_to(ROOT)).encode() + b'\0' + source.read_bytes())
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--with-login-item-test', action='store_true',
                        help='Explicitly authorize isolated Login Items registration and cleanup')
    parser.add_argument('--output', type=Path, default=ROOT / 'coverage-artifacts')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=args.output.resolve()))
    print(f'Coverage artifacts: {output}', flush=True)
    manifest = {'source_sha256': digest(), 'status': 'running', 'commands': [],
                'acceptance': [], 'login_item_test': args.with_login_item_test}
    env = dict(os.environ)
    for key in list(env):
        if key.startswith('BARKEEP_ACCEPTANCE_') or key == 'LLVM_PROFILE_FILE':
            del env[key]

    def run(command, name, extra=None):
        record = {'command': command, 'log': name}
        manifest['commands'].append(record)
        with (output / name).open('w') as log, (output / (name + '.stderr')).open('w') as errors:
            result = subprocess.run(command, cwd=ROOT, env=dict(env, **(extra or {})),
                                    stdout=log, stderr=errors)
        record['exit_code'] = result.returncode
        if result.returncode:
            raise RuntimeError(f'{name} failed with exit {result.returncode}')
        return (output / name).read_text()

    def unchanged():
        if digest() != manifest['source_sha256']:
            raise RuntimeError('Production sources changed during coverage run')

    try:
        run(['xcodebuild', '-version'], 'xcode-version.log')
        run(['swift', '--version'], 'swift-version.log')
        run(['swift', 'test', '--enable-code-coverage'], 'unit-tests.log')
        unchanged()
        path_text = run(['swift', 'test', '--show-codecov-path'], 'codecov-path.log')
        report = Path(path_text.strip().splitlines()[-1])
        if not report.is_absolute():
            report = ROOT / report
        debugdir = report.parent.parent
        candidates = [p for p in debugdir.glob('*.xctest/Contents/MacOS/*')
                      if p.is_file() and p.name in ('BarKeepPackageTests', 'BarKeepTests')]
        if len(candidates) != 1:
            raise RuntimeError(f'Expected one ordinary XCTest executable, found {candidates}')
        binary = output / candidates[0].name
        shutil.copy2(candidates[0], binary)
        unit_profile = output / 'unit.profdata'
        shutil.copy2(report.parent / 'default.profdata', unit_profile)
        manifest['test_executable'] = str(candidates[0])
        manifest['test_executable_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        profiles = [unit_profile]
        modes = [('startup', {}), ('fixture-ui', {'BARKEEP_ACCEPTANCE_XCUITEST': '1'}),
                 ('normal-ui', {'BARKEEP_ACCEPTANCE_NORMAL': '1'})]
        if args.with_login_item_test:
            modes.append(('login-items', {'BARKEEP_ACCEPTANCE_LOGIN': '1'}))
        for mode, settings in modes:
            unchanged()
            log_name = mode + '.log'
            try:
                run([sys.executable, 'scripts/test-app-acceptance.py'], log_name, settings)
            finally:
                # Preserve diagnostics even when the harness fails. Never merge failed profiles.
                lines = (output / log_name).read_text().splitlines()
                paths = [Path(line.removeprefix('Acceptance artifacts: ')) for line in lines
                         if line.startswith('Acceptance artifacts: ')]
                if len(paths) == 1:
                    artifact = paths[0]
                    manifest['acceptance'].append({'mode': mode, 'artifacts': str(artifact)})
                    shutil.copytree(artifact, output / mode, ignore=shutil.ignore_patterns('build'))
            if len(paths) != 1:
                raise RuntimeError(f'{mode}: missing unique artifact directory')
            unchanged()
            if (artifact / 'source-sha256.txt').read_text().strip() != manifest['source_sha256']:
                raise RuntimeError(f'{mode}: production digest mismatch')
            profile = output / mode / ('app.profdata' if mode == 'startup' else 'ui-app.profdata')
            if not profile.is_file() or not profile.stat().st_size:
                raise RuntimeError(f'{mode}: missing profile')
            profiles.append(profile)
        unchanged()
        run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, profiles),
             '-o', str(output / 'combined.profdata')], 'merge.log')
        run(['xcrun', 'llvm-cov', 'export', str(binary), '-instr-profile',
             str(output / 'combined.profdata')], 'combined.json')
        run([sys.executable, 'scripts/check-coverage.py', str(output / 'combined.json'),
             '--minimum', '100'], 'coverage-summary.log')
        unchanged()
        manifest['status'] = 'passed'
        print((output / 'coverage-summary.log').read_text())
    except Exception as error:
        manifest['status'] = 'failed'
        manifest['error'] = str(error)
        print(str(error), file=sys.stderr)
        return 1
    finally:
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
