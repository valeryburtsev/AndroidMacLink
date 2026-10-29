#!/usr/bin/env python3
"""Write our own .proto files from field names and numbers recovered from the clients.

Input is a compiled descriptor set (no comments, no original formatting), so the output is our
rendering of the wire schema, not a copy of Microsoft's source files.

  protoc -I protocol/recovered/android --descriptor_set_out=/tmp/x.desc $(find ... -name '*.proto')
  render_protos.py /tmp/x.desc app/Protos
"""
import sys
from pathlib import Path
from google.protobuf import descriptor_pb2 as d
sys.path.insert(0, str(Path(__file__).parent))
import recover_protos as R

HEADER = """// Wire schema used by Phone Link and Link to Windows.
// Field names and numbers recovered from Link to Windows 1.26082.130.0 and cross-checked against
// Phone Link 1.26072.257.0. Rendered by tools/catalog/render_protos.py from a descriptor set.
"""

def main():
    fds = d.FileDescriptorSet.FromString(Path(sys.argv[1]).read_bytes()); dest = Path(sys.argv[2])
    n = 0
    for fd in fds.file:
        if fd.name.startswith("google/"): continue
        fd.options.ClearField("java_package"); fd.options.ClearField("csharp_namespace")
        text = R.render(fd, "descriptor")
        body = "\n".join(l for l in text.split("\n") if not l.startswith("// "))
        out = dest / fd.name; out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(HEADER + body.lstrip("\n")); n += 1
    print("rendered", n, "files")

if __name__ == "__main__":
    main()
