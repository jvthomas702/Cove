#!/usr/bin/env python3
"""Sign nested Sparkle helpers before the containing framework. Preserve helper entitlements."""
import pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]);identity=sys.argv[2]
magic={b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf'}
for path in sorted(root.rglob('*'), key=lambda p:len(p.parts),reverse=True):
 if path.is_symlink():continue
 if path.is_file():
  with path.open('rb') as f: binary=f.read(4) in magic
  if binary:subprocess.run(['codesign','--force','--sign',identity,'--preserve-metadata=entitlements',str(path)],check=True)
 if path.is_dir() and path.suffix in ['.app','.xpc']:
  subprocess.run(['codesign','--force','--sign',identity,'--preserve-metadata=entitlements',str(path)],check=True)
subprocess.run(['codesign','--force','--sign',identity,str(root)],check=True)
