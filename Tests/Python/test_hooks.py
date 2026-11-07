import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('agent_hook',ROOT/'hooks/agent_hook.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)

class HookTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.directory = Path(self.folder.name)/'private'
        self.env = patch.dict(os.environ,{'BARKEEP_HOOK_STATE_DIR':str(self.directory),'BARKEEP_AGENT':'Test agent','BARKEEP_CLI':'/fixture/cli','BARKEEP_AGENT_THRESHOLD':'60'})
        self.env.start()
    def tearDown(self):
        self.env.stop(); self.folder.cleanup()

    def test_prompt_and_stop_use_private_hashed_paths(self):
        data={'session_id':'../../escape/test'}
        with patch.object(h.time,'time',return_value=100): h.run('prompt',data)
        stamp=h.stamp_path('Test agent',data['session_id'])
        self.assertEqual(stamp.parent,self.directory)
        self.assertEqual(len(stamp.name),64)
        self.assertEqual(stamp.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777,0o700)
        with patch.object(h.time,'time',return_value=230), patch.object(h,'spawn_delivery') as send:
            h.run('stop',data)
            commands=send.call_args.args[0]
            self.assertEqual(commands[0][2],'Test agent finished (2m task)')
            self.assertEqual(commands[1],['/fixture/cli','sound'])
            self.assertFalse(stamp.exists())
            h.run('stop',data); self.assertEqual(send.call_count,1)
        with patch.object(h.time,'time',return_value=100): h.run('prompt',data)
        with patch.object(h.time,'time',return_value=101), patch.object(h,'spawn_delivery') as send:
            h.run('stop',data); send.assert_not_called()

    def test_state_rejects_symlinks_and_public_directories(self):
        self.directory.mkdir(mode=0o755)
        self.directory.chmod(0o755)
        with self.assertRaises(ValueError): h.stamp_path('agent','session')
        self.directory.chmod(0o700)
        stamp=h.stamp_path('Test agent','session')
        target=Path(self.folder.name)/'keep'; target.write_text('untouched')
        stamp.symlink_to(target)
        with patch('sys.stdin',io.StringIO('{"session_id":"session"}')):
            self.assertEqual(h.main(['prompt']),0)
        self.assertEqual(target.read_text(),'untouched')
        self.assertEqual(h.payload('[]'),{}); self.assertEqual(h.payload('invalid'),{})
        self.assertEqual(h.payload('{"message":"hello"}'),{'message':'hello'})

    def test_notifications_and_codex_fanout(self):
        with patch.object(h,'spawn_delivery') as send:
            for data,expected in [({},'needs your input'),({'reason':'Reason'},'Reason'),({'tool_name':'Build'},'Build'),({'message':'Message'},'Message')]:
                h.run('notify',data)
                self.assertEqual(send.call_args.args[0][0][2],'Test agent: '+expected)
            h.run('notify',{'message':'x'*150})
            self.assertEqual(len(send.call_args.args[0][0][2]),len('Test agent: ')+120)
        with patch.object(h.os,'access',return_value=True), patch.object(h.subprocess,'Popen') as popen:
            h.run('codex',{'type':'approval-requested'})
            self.assertEqual(popen.call_count,2)
            self.assertEqual(popen.call_args_list[0].args[0][1],'turn-ended')
            self.assertIn('needs your approval',popen.call_args_list[1].args[0][-1])
        with patch.object(h.os,'access',return_value=True), patch.object(h.subprocess,'Popen',side_effect=OSError('missing')), patch.object(h,'spawn_delivery') as send:
            h.run('codex',{})
            self.assertIn('waiting for your response',send.call_args.args[0][0][2])
        with patch.object(h.os,'access',return_value=False), patch.object(h,'find_cli',return_value=None), patch.object(h,'spawn_delivery') as send:
            h.run('codex',{}); send.assert_not_called()

    def test_entrypoints_delivery_and_lookup(self):
        self.assertEqual(h.find_cli(),'/fixture/cli')
        with patch.dict(os.environ,{'BARKEEP_CLI':''}):
            self.assertEqual(h.find_cli(),str(ROOT/'bin/barkeep'))
            with patch.object(Path,'is_file',return_value=False), patch.object(h.shutil,'which',return_value=None):
                self.assertIsNone(h.find_cli())
        self.assertEqual(h.main([]),0)
        with patch.object(h.subprocess,'run') as run:
            self.assertEqual(h.main(['deliver',json.dumps([['/fixture/cli','sound']])]),0)
            self.assertEqual(run.call_args.args[0],['/fixture/cli','sound'])
        with patch.object(h.subprocess,'run',side_effect=subprocess.TimeoutExpired('cli',12)):
            self.assertEqual(h.main(['deliver','[["/fixture/cli"]]']),0)
        with patch.object(h,'run') as run, patch('sys.stdin',io.StringIO('{"message":"stdin"}')):
            self.assertEqual(h.main(['notify']),0)
            self.assertEqual(run.call_args.args,('notify',{'message':'stdin'}))
            self.assertEqual(h.main(['codex','{"type":"approval-requested"}']),0)
            self.assertEqual(run.call_args.args[1],{'type':'approval-requested'})
        with patch('sys.argv',['agent_hook.py']), self.assertRaises(SystemExit) as result:
            runpy.run_path(str(ROOT/'hooks/agent_hook.py'),run_name='__main__')
        self.assertEqual(result.exception.code,0)

    def test_codex_wrapper_preserves_exact_json_argument(self):
        import shutil
        folder=Path(self.folder.name)/'wrapper'; folder.mkdir()
        script=folder/'codex-notify.sh'
        shutil.copy2(ROOT/'hooks/codex-notify.sh',script)
        (folder/'agent_hook.py').write_text('import json,sys; print(json.dumps(sys.argv[1:]))')
        for arguments,expected in [([],"{}"),(['{"type":"approval-requested"}'],'{"type":"approval-requested"}')]:
            result=subprocess.run([str(script)]+arguments,capture_output=True,text=True,timeout=3)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout),['codex',expected])

    def test_compatibility_wrappers_record_without_device_actions(self):
        for name,agent in [('claude-prompt-submit.sh','Claude'),('agent-prompt-submit.sh','Test agent')]:
            env=dict(os.environ)
            if agent=='Claude': env.pop('BARKEEP_AGENT',None)
            result=subprocess.run([str(ROOT/'hooks'/name)],input='{"session_id":"wrapper"}',text=True,capture_output=True,env=env,timeout=3)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(h.stamp_path(agent,'wrapper').is_file())

if __name__=='__main__': unittest.main()
