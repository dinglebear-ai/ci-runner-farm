#!/usr/bin/env python3
"""Generate the native daemon's immutable engine projection from authored sources."""
import gzip,io,tarfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
runtime=root/'src/usr/local/emhttp/plugins/ci-runner-farm'
paths=sorted([*runtime.glob('include/*.sh'),*runtime.glob('include/providers/*.sh'),runtime/'include/build-demand.php',runtime/'include/encoding.php',runtime/'default.github.Dockerfile'])
# Deliberately no PHP endpoints, emhttp pages, nchan publishers or classic events.
buf=io.BytesIO()
with tarfile.open(fileobj=buf,mode='w') as t:
 for p in paths:
  info=tarfile.TarInfo(str(p.relative_to(runtime)));info.size=p.stat().st_size;info.mode=0o500 if p.suffix=='.sh' else 0o400
  with p.open('rb') as source:t.addfile(info,source)
with (root/'internal/nativebackend/engine.tar.gz').open('wb') as out:
 with gzip.GzipFile(fileobj=out,mode='wb',mtime=0,filename='') as g:g.write(buf.getvalue())
