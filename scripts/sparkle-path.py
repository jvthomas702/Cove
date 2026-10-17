#!/usr/bin/env python3
"""Locate the checked Sparkle binary artifact inside a SwiftPM build folder."""
import pathlib,sys
root=pathlib.Path(sys.argv[1]).resolve()/'artifacts'
kind=sys.argv[2] if len(sys.argv)>2 else 'framework'
if kind=='framework':
 matches=list(root.glob('**/Sparkle.xcframework/macos*/Sparkle.framework'))
else:
 matches=list(root.glob('**/bin/'+kind))
if not matches:
 local=pathlib.Path(__file__).resolve().parents[1]/'.vendor'
 matches=list(local.glob('Sparkle.xcframework/macos*/Sparkle.framework')) if kind=='framework' else list(local.glob('bin/'+kind))
if len(matches)!=1:raise SystemExit(f'Expected one Sparkle {kind}, found {len(matches)} under {root}')
print(matches[0])
