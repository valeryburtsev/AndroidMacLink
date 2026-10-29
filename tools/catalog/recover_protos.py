#!/usr/bin/env python3
"""Recover .proto files from protobuf descriptors embedded in decompiled C# (*Reflection.cs).

Google's C# generator embeds each file's serialized FileDescriptorProto as base64. This reads that
data as text, decodes it, and prints an equivalent .proto. Nothing from the target is executed.

Usage: recover_protos.py corpus/windows/decompiled protocol/recovered/windows
"""
import base64, re, sys
from pathlib import Path
from google.protobuf import descriptor_pb2 as d

F = d.FieldDescriptorProto
SCALARS = {F.TYPE_DOUBLE: "double", F.TYPE_FLOAT: "float", F.TYPE_INT64: "int64", F.TYPE_UINT64: "uint64",
           F.TYPE_INT32: "int32", F.TYPE_FIXED64: "fixed64", F.TYPE_FIXED32: "fixed32", F.TYPE_BOOL: "bool",
           F.TYPE_STRING: "string", F.TYPE_BYTES: "bytes", F.TYPE_UINT32: "uint32", F.TYPE_SFIXED32: "sfixed32",
           F.TYPE_SFIXED64: "sfixed64", F.TYPE_SINT32: "sint32", F.TYPE_SINT64: "sint64"}


def type_name(field, pkg):
    if field.type in SCALARS:
        return SCALARS[field.type]
    name = field.type_name.lstrip(".")
    return name[len(pkg) + 1:] if pkg and name.startswith(pkg + ".") else name


def emit_enum(e, ind, out):
    out.append(f"{ind}enum {e.name} {{")
    if e.options.allow_alias: out.append(f"{ind}  option allow_alias = true;")
    for v in e.value: out.append(f"{ind}  {v.name} = {v.number};")
    out.append(f"{ind}}}")


def emit_message(m, ind, out, pkg, proto3):
    out.append(f"{ind}message {m.name} {{")
    maps = {n.name: n for n in m.nested_type if n.options.map_entry}
    for e in m.enum_type: emit_enum(e, ind + "  ", out)
    for n in m.nested_type:
        if not n.options.map_entry: emit_message(n, ind + "  ", out, pkg, proto3)
    real_oneofs = {i for i, _ in enumerate(m.oneof_decl)
                   if not all(f.proto3_optional for f in m.field if f.HasField("oneof_index") and f.oneof_index == i)}

    def line(f, pad):
        entry = maps.get(f.type_name.split(".")[-1]) if f.type == F.TYPE_MESSAGE else None
        if entry:
            k, v = entry.field[0], entry.field[1]
            return f"{pad}map<{type_name(k, pkg)}, {type_name(v, pkg)}> {f.name} = {f.number};"
        label = ""
        if f.label == F.LABEL_REPEATED: label = "repeated "
        elif f.proto3_optional or (not proto3 and f.label == F.LABEL_OPTIONAL): label = "optional "
        elif f.label == F.LABEL_REQUIRED: label = "required "
        opts = " [deprecated = true]" if f.options.deprecated else ""
        return f"{pad}{label}{type_name(f, pkg)} {f.name} = {f.number}{opts};"

    for f in m.field:
        if not (f.HasField("oneof_index") and f.oneof_index in real_oneofs): out.append(line(f, ind + "  "))
    for i in sorted(real_oneofs):
        out.append(f"{ind}  oneof {m.oneof_decl[i].name} {{")
        for f in m.field:
            if f.HasField("oneof_index") and f.oneof_index == i: out.append(line(f, ind + "    ").replace("optional ", ""))
        out.append(f"{ind}  }}")
    for r in m.reserved_range: out.append(f"{ind}  reserved {r.start}" + (f" to {r.end - 1};" if r.end - 1 > r.start else ";"))
    out.append(f"{ind}}}")


def render(fd, source):
    proto3 = fd.syntax == "proto3"
    out = [f"// Recovered from {source}", f"// Embedded descriptor name: {fd.name}",
           f'syntax = "{fd.syntax or "proto2"}";', ""]
    if fd.package: out += [f"package {fd.package};", ""]
    for dep in fd.dependency: out.append(f'import "{dep}";')
    if fd.dependency: out.append("")
    if fd.options.csharp_namespace: out += [f'option csharp_namespace = "{fd.options.csharp_namespace}";', ""]
    if fd.options.java_package: out += [f'option java_package = "{fd.options.java_package}";', ""]
    for e in fd.enum_type: emit_enum(e, "", out); out.append("")
    for m in fd.message_type: emit_message(m, "", out, fd.package, proto3); out.append("")
    for s in fd.service:
        out.append(f"service {s.name} {{")
        for m in s.method: out.append(f"  rpc {m.name}({m.input_type.lstrip('.')}) returns ({m.output_type.lstrip('.')});")
        out += ["}", ""]
    return "\n".join(out)


def main():
    src, dest = Path(sys.argv[1]), Path(sys.argv[2])
    done = failed = 0
    for cs in sorted(src.rglob("*.cs")):
        text = cs.read_text(encoding="utf-8", errors="replace")
        if "FileDescriptor.FromGeneratedCode" not in text: continue
        # The base64 chunks sit between the static constructor's opening and FromGeneratedCode, as
        # "a" + "b", string.Concat("a", "b") or buffer[i] = "a" assignments. Order is source order.
        for m in re.finditer(r"static \w+Reflection\(\)(.*?)FileDescriptor\.FromGeneratedCode", text, re.S):
            b64 = "".join(re.findall(r'"([A-Za-z0-9+/=]+)"', m.group(1)))
            try:
                fd = d.FileDescriptorProto.FromString(base64.b64decode(b64))
                if not fd.name: raise ValueError("no file name")
            except Exception as exc:
                failed += 1; print(f"FAIL {cs.relative_to(src)}: {exc}"); continue
            asm = cs.relative_to(src).parts[0]
            target = dest / asm / fd.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(render(fd, f"{asm}.dll ({cs.name})"))
            done += 1
            print(f"ok   {asm}/{fd.name}: {len(fd.message_type)} messages, {len(fd.enum_type)} enums")
    print(f"DONE recovered={done} failed={failed}")


if __name__ == "__main__":
    main()
