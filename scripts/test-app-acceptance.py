#!/usr/bin/env python3
"""Build and launch the real app with isolated external-service fixtures."""
import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

login = os.environ.get('BARKEEP_ACCEPTANCE_LOGIN') == '1'
normal = os.environ.get('BARKEEP_ACCEPTANCE_NORMAL') == '1'
if login and normal:
    raise SystemExit('Login mode must use fixture dependencies, not normal services')
ui_mode = login or normal or os.environ.get('BARKEEP_ACCEPTANCE_XCUITEST') == '1'
root = Path(__file__).resolve().parents[1]
if not shutil.which('xcodegen'):
    raise SystemExit('xcodegen is required; no tools were installed')
work = Path(tempfile.mkdtemp(prefix='barkeep-app-acceptance-'))
print(f'Acceptance artifacts: {work}', flush=True)
source_hash = hashlib.sha256()
for source in sorted((root / 'Sources/BarKeep').glob('*.swift')):
    source_hash.update(str(source.relative_to(root)).encode() + b'\0' + source.read_bytes())
(work / 'source-sha256.txt').write_text(source_hash.hexdigest() + '\n')
print(f'Production source SHA256: {source_hash.hexdigest()}', flush=True)
suite = 'dev.barkeep.acceptance.' + str(uuid.uuid4())
(work / 'fixture.tgz').write_bytes(bytes([31,139,8,0,1,2,3]))
spec = {
    'name': 'BarKeepAcceptance',
    'targets': {'BarKeepAcceptance': {
        'type': 'application', 'platform': 'macOS', 'deploymentTarget': '14.0',
        'sources': [str(root / 'Sources/BarKeep'), str(root / 'Tests/AppAcceptance')],
        'settings': {'base': {
            'PRODUCT_BUNDLE_IDENTIFIER': 'dev.barkeep.acceptance-host',
            'PRODUCT_MODULE_NAME': 'BarKeep',
            'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_KEY_LSUIElement': 'YES',
            'SWIFT_VERSION': '5.0', 'CODE_SIGN_IDENTITY': '-',
            'CURRENT_PROJECT_VERSION': '1', 'MARKETING_VERSION': '1.1.0',
            'CODE_SIGN_STYLE': 'Manual', 'ENABLE_DEBUG_DYLIB': 'NO',
            'OTHER_LDFLAGS': ['-fprofile-instr-generate'],
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG BARKEEP_APP_ACCEPTANCE',
            'OTHER_SWIFT_FLAGS': ['-profile-generate', '-profile-coverage-mapping'],
        }}
    }}
}
if login:
    settings = spec['targets']['BarKeepAcceptance']['settings']['base']
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'dev.barkeep.acceptance-login.' + str(uuid.uuid4())
    settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'BarKeep Login Acceptance'
    (work / 'fresh-login-identity').write_text(settings['PRODUCT_BUNDLE_IDENTIFIER'])
server = None
if normal:
    class FixtureHandler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def reply(self):
            length = int(self.headers.get('Content-Length', 0))
            if length:
                self.rfile.read(length)
            path = urlsplit(self.path).path
            with (work / 'normal-requests.log').open('a') as log:
                log.write(self.command + ' ' + path + '\n')
            fixtures = {
                '/api/status': b'{"power":{"state":"charging","battery_charge":90},"firmware":{"version":"1.3.1"}}',
                '/api/busy/snapshot': b'{"snapshot":{"type":"NOT_STARTED"}}',
            }
            data = fixtures.get(path, b'')
            self.send_response(200 if path in fixtures else 503)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        do_GET = reply
        do_POST = reply
        do_DELETE = reply
    server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    target = spec['targets']['BarKeepAcceptance']
    target['sources'] = [str(root / 'Sources/BarKeep')]
    target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
    target['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER'] = 'dev.barkeep.acceptance-normal.' + uuid.uuid4().hex
    target['settings']['base']['INFOPLIST_KEY_CFBundleDisplayName'] = 'BarKeep Normal Acceptance'
    target['settings']['base']['INFOPLIST_KEY_NSLocalNetworkUsageDescription'] = 'Isolated BarKeep acceptance test startup.'
if ui_mode:
    spec['targets']['BarKeepAcceptanceUI'] = {
        'type': 'bundle.ui-testing', 'platform': 'macOS', 'deploymentTarget': '14.0',
        'sources': [str(root / 'Tests/AppAcceptanceUI')],
        'dependencies': [{'target': 'BarKeepAcceptance'}],
        'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'dev.barkeep.acceptance-ui',
            'GENERATE_INFOPLIST_FILE': 'YES', 'CODE_SIGN_IDENTITY': '-',
            'CODE_SIGN_STYLE': 'Manual', 'TEST_TARGET_NAME': 'BarKeepAcceptance'}}}
    spec['schemes'] = {'BarKeepAcceptance': {
        'build': {'targets': {'BarKeepAcceptance': 'all', 'BarKeepAcceptanceUI': ['test']}},
        'test': {'targets': ['BarKeepAcceptanceUI'], 'environmentVariables': {'BARKEEP_ACCEPTANCE_SUITE': suite, 'BARKEEP_ACCEPTANCE_ARTIFACTS': str(work), 'BARKEEP_ACCEPTANCE_NORMAL': '1' if normal else '0', 'BARKEEP_ACCEPTANCE_LOGIN': '1' if login else '0', 'BARKEEP_ACCEPTANCE_BUNDLE_ID': spec['targets']['BarKeepAcceptance']['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER'], 'BARKEEP_ACCEPTANCE_HOST': f'127.0.0.1:{server.server_port}' if server else ''}}}}
(work / 'project.json').write_text(json.dumps(spec))
subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.json'), '--project', str(work)], check=True)
subprocess.run(['xcodebuild', '-project', str(work / 'BarKeepAcceptance.xcodeproj'),
    '-scheme', 'BarKeepAcceptance', '-configuration', 'Debug', '-derivedDataPath', str(work / 'build'), 'build'],
    stdout=(work / 'build.log').open('w'), stderr=subprocess.STDOUT, check=True)
binary = work / 'build/Build/Products/Debug/BarKeepAcceptance.app/Contents/MacOS/BarKeepAcceptance'
if login:
    # Register only this standard packaged test app with LaunchServices; not a login registration.
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(binary.parents[2])], check=True)
if ui_mode:
    try:
        with (work / 'ui-test.log').open('w') as output:
            subprocess.run(['xcodebuild', '-project', str(work / 'BarKeepAcceptance.xcodeproj'),
                '-scheme', 'BarKeepAcceptance', '-configuration', 'Debug',
                '-derivedDataPath', str(work / 'build'), '-destination', 'platform=macOS',
                '-resultBundlePath', str(work / 'ui-results.xcresult'), 'test'],
                stdout=output, stderr=subprocess.STDOUT, timeout=120, check=True)
    finally:
        if login:
            cleanup = work / 'login-cleanup.json'
            cleanup_env = dict(os.environ, BARKEEP_ACCEPTANCE_UI='1',
                BARKEEP_ACCEPTANCE_SUITE=suite, BARKEEP_ACCEPTANCE_LOGIN_CLEANUP='1',
                BARKEEP_ACCEPTANCE_LOGIN_STATUS=str(cleanup),
                BARKEEP_ACCEPTANCE_EXPECTED_ID=spec['targets']['BarKeepAcceptance']['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER'],
                LLVM_PROFILE_FILE=str(work / 'ui-app-cleanup-%p.profraw'))
            subprocess.run([str(binary)], env=cleanup_env, timeout=20, check=True)
            result = json.loads(cleanup.read_text())
            expected_id = spec['targets']['BarKeepAcceptance']['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER']
            absent_without_mutation = (result.get('status') == 'notFound'
                and result.get('initialStatus') == 'notFound'
                and result.get('cleanupAction') == 'none' and 'error' not in result)
            if result.get('bundleID') != expected_id or (result.get('status') != 'notRegistered' and not absent_without_mutation):
                raise RuntimeError(f'Login cleanup is uncertain; preserve app artifact: {result}')
            print(f'Verified isolated service final status (notFound means no service found): {result}', flush=True)
            subprocess.run(['/usr/bin/defaults', 'delete', expected_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if server:
            server.shutdown()
            server.server_close()
            subprocess.run(['/usr/bin/defaults', 'delete', spec['targets']['BarKeepAcceptance']['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['/usr/bin/defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if normal and not (work / 'normal-requests.log').exists():
        raise SystemExit('Normal app did not reach the loopback fixture')
    profiles = list(work.glob('ui-app-*.profraw'))
    if not profiles or not all(p.stat().st_size for p in profiles):
        raise SystemExit('UI test did not flush a nonempty app profile')
    subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, profiles), '-o', str(work / 'ui-app.profdata')], check=True)
    print(f'UI acceptance passed with flushed profile: {work}')
    raise SystemExit(0)
binary = work / 'build/Build/Products/Debug/BarKeepAcceptance.app/Contents/MacOS/BarKeepAcceptance'
env = dict(os.environ, BARKEEP_ACCEPTANCE_SUITE=suite, LLVM_PROFILE_FILE=str(work / 'app-%p.profraw'),
           BARKEEP_ACCEPTANCE_RESULT=str(work / 'result.json'))
try:
    subprocess.run([str(binary), '--show-window'], env=env, timeout=25, check=True)
finally:
    # Only the UUID suite created for this child; also cleans abnormal exits.
    subprocess.run(['/usr/bin/defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
result = json.loads((work / 'result.json').read_text())
profiles = list(work.glob('*.profraw'))
if not result['passed'] or not profiles or not all(p.stat().st_size for p in profiles):
    raise SystemExit(f'Acceptance failed: {result}; profiles={profiles}')
subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, profiles), '-o', str(work / 'app.profdata')], check=True)
with (work / 'coverage.json').open('w') as output:
    subprocess.run(['xcrun', 'llvm-cov', 'export', str(binary), '-instr-profile', str(work / 'app.profdata')], stdout=output, check=True)
print(json.dumps(result, indent=2))
print(f'PASS: clean app exit and coverage export at {work}')
