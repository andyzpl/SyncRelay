import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'analysis/python-libs'))
import lief

SOURCE = ROOT / 'analysis/rootfs/Library/MobileSubstrate/DynamicLibraries/MikotoHelper.dylib'
OUT = ROOT / 'analysis/reports'
binary = lief.MachO.parse(SOURCE.read_bytes()).at(0)
sections = list(binary.sections)

def read(addr, size):
    for section in sections:
        if section.virtual_address <= addr < section.virtual_address + section.size:
            offset = addr - section.virtual_address
            return bytes(section.content[offset:offset + size])
    return b''

def cstr(addr):
    return read(addr, 4096).split(b'\0')[0].decode('utf-8', 'replace')

def u64(addr):
    data = read(addr, 8)
    return struct.unpack('<Q', data)[0] if len(data) == 8 else 0

inventory = [{'segment': s.segment_name, 'name': s.name, 'address': hex(s.virtual_address), 'size': s.size} for s in sections]
(OUT / 'sections.json').write_text(json.dumps(inventory, indent=2), encoding='utf-8')
for name in ['__cstring', '__objc_methname', '__objc_classname']:
    lines = []
    for s in sections:
        if s.name == name:
            offset = 0
            for item in bytes(s.content).split(b'\0'):
                if item:
                    lines.append(f'{s.virtual_address + offset:#x}\t{item.decode("utf-8", "replace")}')
                offset += len(item) + 1
    (OUT / (name + '.txt')).write_text('\n'.join(lines), encoding='utf-8')

cfstrings = []
for s in sections:
    if s.name != '__cfstring':
        continue
    for offset in range(0, s.size, 32):
        data = bytes(s.content[offset:offset + 32])
        if len(data) != 32:
            continue
        isa, flags, ptr, length = struct.unpack('<QQQQ', data)
        if length > 100000:
            continue
        wide = bool(flags & 0x10)
        text = read(ptr, length * (2 if wide else 1)).decode('utf-16-le' if wide else 'utf-8', 'replace')
        cfstrings.append({'address': hex(s.virtual_address + offset), 'text': text})
(OUT / 'cfstrings.json').write_text(json.dumps(cfstrings, ensure_ascii=False, indent=2), encoding='utf-8')

methods = []
def method_list(ptr, cls, kind):
    header = read(ptr, 8)
    if len(header) < 8:
        return
    flags, count = struct.unpack('<II', header)
    entry_size = flags & 0xffff
    relative = bool(flags & 0x80000000)
    if count > 100000 or entry_size < 12:
        return
    for i in range(count):
        addr = ptr + 8 + i * entry_size
        if relative:
            data = read(addr, 12)
            if len(data) < 12:
                continue
            name, types, imp = struct.unpack('<iii', data)
            name_ptr = addr + name
            if not flags & 0x40000000:
                name_ptr = u64(name_ptr)
            name, imp = cstr(name_ptr), addr + 8 + imp
        else:
            name, imp = cstr(u64(addr)), u64(addr + 16)
        methods.append({'class': cls, 'kind': kind, 'selector': name, 'imp': hex(imp)})

for s in sections:
    if s.name != '__objc_classlist':
        continue
    for offset in range(0, s.size, 8):
        cls = u64(s.virtual_address + offset)
        ro = u64(cls + 32) & ~7
        name = cstr(u64(ro + 24))
        method_list(u64(ro + 32), name, '-')
        meta = u64(cls)
        meta_ro = u64(meta + 32) & ~7
        method_list(u64(meta_ro + 32), name, '+')
(OUT / 'methods.json').write_text(json.dumps(methods, ensure_ascii=False, indent=2), encoding='utf-8')
(OUT / 'methods.tsv').write_text('\n'.join(f'{m["imp"]}\t{m["kind"]}[{m["class"]} {m["selector"]}]' for m in methods), encoding='utf-8')
(OUT / 'symbols.tsv').write_text('\n'.join(f'{s.value:#x}\t{s.name}' for s in binary.symbols), encoding='utf-8')
print(f'Sections: {len(sections)}; CFStrings: {len(cfstrings)}; methods: {len(methods)}')
