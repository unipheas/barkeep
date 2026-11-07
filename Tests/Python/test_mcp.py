import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('barkeep_mcp', ROOT/'mcp/barkeep_mcp.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class MCPTests(unittest.TestCase):
    def test_tool_contracts_and_app_commands(self):
        names = [x['name'] for x in m.TOOLS]
        self.assertEqual(len(names),len(set(names)))
        for name in ['bar_apps_list','bar_api_read','bar_app_settings_get']:
            self.assertTrue(next(x for x in m.TOOLS if x['name']==name)['annotations']['readOnlyHint'])
        for name, method, path, args in [
            ('bar_apps_list','GET','/apps/list',{}),
            ('bar_app_install','POST','/apps/install',{'install_key':123}),
            ('bar_app_launch','POST','/apps/launch',{'app_id':'app.test'}),
            ('bar_app_remove','DELETE','/apps',{'app_id':'app.test'}),
            ('bar_app_stop','POST','/apps/quit',{}),
            ('bar_app_settings_get','GET','/apps/settings',{'app_id':'app.test'}),
            ('bar_app_settings_set','PUT','/apps/settings',{'app_id':'app.test','settings':{'version':1,'values':{'x':True}}}),
            ('bar_app_settings_reset','DELETE','/apps/settings',{'app_id':'app.test'}),
            ('bar_api_read','GET','/wifi/status',{'path':'/wifi/status'}),
            ('bar_api_write','POST','/input',{'method':'POST','path':'/input','query':{'key':'ok'}}),
        ]:
            with self.subTest(name=name), patch.object(m,'api',return_value={'result':'OK'}) as api:
                self.assertEqual(json.loads(m.handle_tool(name,args)),{'result':'OK'})
                self.assertEqual(api.call_args.args[:2],(method,path))

    def test_packages_and_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            file=Path(folder)/'app.tgz'; file.write_bytes(b'package')
            self.assertEqual(m.package_bytes(str(file)),b'package')
            with patch.object(m,'api',return_value={'install_key':3}) as api:
                self.assertEqual(json.loads(m.handle_tool('bar_app_stage',{'path':str(file)})),{'install_key':3})
                self.assertEqual(api.call_args.kwargs['raw'],b'package')
            file.write_bytes(b'')
            with self.assertRaises(ValueError): m.package_bytes(str(file))
            with self.assertRaises(ValueError): m.package_bytes(str(file.with_suffix('.zip')))
        for value in ['', '.app','x/y','x'*33,'🌞']:
            with self.assertRaises(ValueError): m.app_id(value)
        for doc in [{},[],{'version':True,'values':{}},{'version':1,'values':[]}]:
            with self.assertRaises(ValueError): m.settings_document(doc)
        for value in [True,-1,481,'3']:
            with self.assertRaises(ValueError): m.handle_tool('bar_start_timer',{'minutes':value})
        with self.assertRaises(ValueError): m.handle_tool('bar_set_busy',{'on':'false'})
        with self.assertRaises(ValueError): m.handle_tool('bar_send_message',{'text':'x','seconds':-1})
        with self.assertRaises(ValueError): m.handle_tool('unknown',{})
        with self.assertRaises(ValueError): m.handle_tool('bar_status',[])
        with self.assertRaises(ValueError): m.handle_tool('bar_api_write',{'method':'GET','path':'/status'})

    def test_existing_tools_and_clear_errors(self):
        with patch.object(m,'api',return_value={}) as api:
            self.assertIn('empty',m.handle_tool('bar_send_message',{'text':'🌞'}))
            self.assertIn('Displayed',m.handle_tool('bar_send_message',{'text':'hi 🌞','chime':True,'color':'red'}))
            self.assertEqual(api.call_count,2)
            self.assertIn('ON',m.handle_tool('bar_set_busy',{'on':True}))
            self.assertIn('OFF',m.handle_tool('bar_set_busy',{'on':False}))
            self.assertIn('5 minutes',m.handle_tool('bar_start_timer',{'minutes':5}))
            self.assertIn('battery',json.loads(m.handle_tool('bar_status',{})))
            self.assertEqual(m.handle_tool('bar_clear',{}),'Display cleared')
        with patch.object(m,'api',side_effect=ValueError('offline')):
            # Clear must report failure rather than claim success when the bar is offline.
            with self.assertRaises(ValueError): m.handle_tool('bar_clear',{})
        self.assertEqual(m.color_hex('unknown'),'#FFFFFFFF')
        self.assertEqual(m.color_hex('#12345678'),'#12345678')

    def test_transport_and_host_validation(self):
        self.assertEqual(m.normalized_host('http://bar.local:8080/settings'),'bar.local:8080')
        self.assertEqual(m.normalized_host('[::1]:8080'),'[::1]:8080')
        for host in ['http://user:password@host','file:///etc/passwd','']:
            with self.assertRaises(ValueError): m.normalized_host(host)
        for path in ['https://elsewhere','//elsewhere','/a/../b','/status?q=x']:
            with self.assertRaises(ValueError): m.api('GET',path)
        with self.assertRaises(ValueError): m.api('CONNECT','/status')
        with patch.object(m,'TOKEN','bad\ntoken'):
            with self.assertRaises(ValueError): m.api('GET','/status')
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self): return b'{"result":"OK"}'
        with patch('urllib.request.OpenerDirector.open',return_value=Response()) as call:
            with patch.object(m,'TOKEN','test'):
                self.assertEqual(m.api('POST','/apps/stage',query={'x':'a&b'},raw=b'abc'),{'result':'OK'})
                req=call.call_args.args[0]
                self.assertEqual(req.get_header('X-api-token'),'test')
                self.assertTrue(req.full_url.endswith('x=a%26b'))
                self.assertEqual(req.data,b'abc')
            self.assertEqual(m.api('GET','/storage/read',binary=True),b'{"result":"OK"}')
        err=urllib.error.HTTPError('http://bar',403,'Forbidden',{},io.BytesIO(b'no access'))
        with patch('urllib.request.OpenerDirector.open',side_effect=err):
            with self.assertRaisesRegex(ValueError,'HTTP 403'): m.api('GET','/status')
        self.assertIsNone(m.NoRedirect().redirect_request(None,None,302,'',{},'http://elsewhere'))

    def test_raw_responses_cli_files_and_install(self):
        class Response:
            payload=b''
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self): return self.payload
        response=Response()
        with patch('urllib.request.OpenerDirector.open',return_value=response):
            self.assertEqual(m.api('GET','/status'),{})
            response.payload=b'not json'
            self.assertEqual(m.api('GET','/log'),{'text':'not json'})
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            package=Path(folder)/'app.tgz'; package.write_bytes(b'package')
            settings=Path(folder)/'settings.json'; settings.write_text('{"version":1,"values":{}}')
            output=Path(folder)/'out.bin'
            with patch.object(m,'api',return_value={'result':'OK'}):
                self.assertEqual(m.cli(['apps','set-settings','app.test',str(settings)]),0)
                self.assertEqual(m.cli(['api','POST','/storage/write','--file',str(package)]),0)
                self.assertEqual(m.cli(['api','PUT','/name','--json','{"name":"Test"}']),0)
            with patch.object(m,'api',return_value=b'data'):
                self.assertEqual(m.cli(['api','GET','/storage/read','--output',str(output)]),0)
                self.assertEqual(output.read_bytes(),b'data')
            with patch.object(m,'handle_tool',side_effect=['{"install_key":123,"staged":{"name":"Test","version":"1"}}','{"result":"OK"}']):
                self.assertEqual(m.cli(['apps','install',str(package)]),0)
            self.assertEqual(m.cli(['api','POST','/x','--json','{}','--file',str(package)]),1)
            self.assertEqual(m.cli(['api','GET','/x','--query','[]']),1)
        with patch.object(m,'handle_tool',return_value='ok'), patch('sys.stdin',io.StringIO('{"id":1,"method":"tools/call","params":{"name":"bar_status"}}')), contextlib.redirect_stdout(io.StringIO()) as out:
            m.main()
            self.assertIn('ok',out.getvalue())
        import runpy
        with patch('sys.stdin',io.StringIO('{"id":1,"method":"ping"}')), patch('sys.argv',['barkeep_mcp.py']), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(ROOT/'mcp/barkeep_mcp.py'),run_name='__main__')
        with patch('sys.argv',['barkeep_mcp.py','--cli','apps','--help']), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                runpy.run_path(str(ROOT/'mcp/barkeep_mcp.py'),run_name='__main__')
            self.assertEqual(result.exception.code,0)

    def test_protocol_and_cli(self):
        messages=[{'id':1,'method':'initialize','params':{}},{'method':'notifications/initialized'},
                  {'id':2,'method':'tools/list'},{'id':3,'method':'tools/call','params':{'name':'nope'}},
                  {'id':4,'method':'ping'},{'id':5,'method':'unsupported'},[]]
        with patch('sys.stdin',io.StringIO('\nnot-json\n'+'\n'.join(json.dumps(x) for x in messages))), patch('sys.stdout',new_callable=io.StringIO) as out:
            m.main()
        replies=[json.loads(x) for x in out.getvalue().splitlines()]
        self.assertEqual(len(replies),6)
        self.assertEqual(replies[0]['result']['serverInfo']['name'],'barkeep')
        self.assertTrue(replies[2]['result']['isError'])
        self.assertEqual(replies[4]['error']['code'],-32601)
        with patch.object(m,'api',return_value={'apps':[]}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.cli(['apps','list']),0)
        with patch.object(m,'api',side_effect=ValueError('offline')), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(m.cli(['apps','stop']),1)
        result=subprocess.run([str(ROOT/'bin/barkeep'),'apps','--help'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0); self.assertIn('install',result.stdout)
        for args in [['timer','0'],['pomodoro','x'],['send','hi','-t','oops'],['send','hi','-f','bad']]:
            self.assertNotEqual(subprocess.run([str(ROOT/'bin/barkeep')]+args,capture_output=True).returncode,0)

if __name__ == '__main__': unittest.main()
