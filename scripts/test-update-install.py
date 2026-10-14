#!/usr/bin/env python3
"""Install a signed update into an isolated throwaway app, then verify its relaunch marker."""
import functools,http.server,pathlib,plistlib,shutil,subprocess,sys,tempfile,threading,time,uuid
root=pathlib.Path(__file__).resolve().parents[1]
stage=pathlib.Path(tempfile.mkdtemp(prefix='cove-update-install-'))
framework=pathlib.Path(subprocess.check_output(['python3',str(root/'scripts/sparkle-path.py'),sys.argv[1]],text=True).strip())
def tool(name):return subprocess.check_output(['python3',str(root/'scripts/sparkle-path.py'),sys.argv[1],name],text=True).strip()
class QuietHandler(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
web=stage/'web';web.mkdir()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(QuietHandler,directory=str(web)))
threading.Thread(target=server.serve_forever,daemon=True).start()
port=server.server_address[1]
key=stage/'private';public=subprocess.check_output(['swift',str(root/'scripts/create-test-update-key.swift'),str(key)],text=True).strip()
identifier='app.cove.update-fixture.'+uuid.uuid4().hex
marker=stage/'installed-version';binary=stage/'UpdateHost'
subprocess.run(['swiftc','-parse-as-library','-target',subprocess.check_output(['uname','-m'],text=True).strip()+'-apple-macosx14.0','-F',str(framework.parent),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks','-o',str(binary),str(root/'Tests/Updates/UpdateHost.swift')],check=True)
def app(path,version):
 (path/'Contents/MacOS').mkdir(parents=True)
 (path/'Contents/Frameworks').mkdir()
 shutil.copy2(binary,path/'Contents/MacOS/UpdateHost')
 subprocess.run(['ditto',str(framework),str(path/'Contents/Frameworks/Sparkle.framework')],check=True)
 subprocess.run(['python3',str(root/'scripts/sign-sparkle.py'),str(path/'Contents/Frameworks/Sparkle.framework'),'-'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 info={'CFBundleIdentifier':identifier,'CFBundleExecutable':'UpdateHost','CFBundleName':'Cove Update Test','CFBundlePackageType':'APPL','CFBundleVersion':version,'CFBundleShortVersionString':'1.1.'+('0' if version=='110' else '1'),'LSMinimumSystemVersion':'14.0','LSUIElement':True,'SUFeedURL':f'http://127.0.0.1:{port}/appcast.xml','SUPublicEDKey':public,'SUEnableAutomaticChecks':True,'SUAutomaticallyUpdate':True,'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,'CoveTestMarker':str(marker),'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
 (path/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 subprocess.run(['codesign','--force','--sign','-',str(path)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 subprocess.run(['codesign','--verify','--deep','--strict',str(path)],check=True)
installed=stage/'Installed/Cove Update Test.app';installed.parent.mkdir()
new=stage/'New/Cove Update Test.app';new.parent.mkdir()
app(installed,'110');app(new,'111')
archive=web/'Cove-test.zip';subprocess.run(['ditto','-c','-k','--keepParent',str(new),str(archive)],check=True)
subprocess.run([tool('generate_appcast'),'--ed-key-file',str(key),'--download-url-prefix',f'http://127.0.0.1:{port}/','--maximum-deltas','0',str(web)],check=True)
log=stage/'update.log'
try:
 with log.open('wb') as output:
  process=subprocess.Popen([str(installed/'Contents/MacOS/UpdateHost')],stdout=output,stderr=subprocess.STDOUT)
  deadline=time.monotonic()+50
  while time.monotonic()<deadline:
   if marker.exists() and marker.read_text()=='111':break
   time.sleep(0.25)
  else:raise RuntimeError('Update did not relaunch version 111: '+log.read_text())
  subprocess.run(['codesign','--verify','--deep','--strict',str(installed)],check=True)
  assert plistlib.loads((installed/'Contents/Info.plist').read_bytes())['CFBundleVersion']=='111'
  print('PASS signed update downloaded, installed and relaunched version 111')
finally:
 server.shutdown()
 if 'process' in locals() and process.poll() is None:process.terminate();process.wait(timeout=5)
 key.unlink(missing_ok=True)
 print('Update fixture diagnostics:',stage)
