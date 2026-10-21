import sys
from inspect_macho import OUT, binary, cstr, read, sections, u64
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

start = int(sys.argv[1], 0)
size = int(sys.argv[2], 0) if len(sys.argv) > 2 else 2048
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
bindings = {b.address: b.symbol.name for b in binary.bindings if b.has_symbol}
stubs = {}
for section in sections:
    if section.name == '__stubs':
        ins = list(md.disasm(bytes(section.content), section.virtual_address))
        for i in range(0, len(ins) - 2, 3):
            try:
                page = int(ins[i].op_str.split('#')[1], 0)
                operand = ins[i + 1].op_str
                offset = int(operand.split('#')[1].rstrip(']'), 0) if '#' in operand else 0
                stubs[ins[i].address] = bindings.get(page + offset, hex(page + offset))
            except (ValueError, IndexError):
                pass

lines = []
registers = {}
for ins in md.disasm(read(start, size), start):
    note = ''
    operands = ins.op_str.split(', ')
    if ins.mnemonic == 'adrp':
        registers[operands[0]] = int(operands[1].lstrip('#'), 0)
    elif ins.mnemonic == 'add' and len(operands) == 3 and operands[1] in registers and operands[2].startswith('#'):
        addr = registers[operands[1]] + int(operands[2][1:], 0)
        registers[operands[0]] = addr
        for s in sections:
            if s.virtual_address <= addr < s.virtual_address + s.size:
                note = f'{s.name} {addr:#x}'
                if s.name in ('__objc_methname', '__cstring', '__objc_classname'):
                    note += ' ' + cstr(addr)
                break
    elif ins.mnemonic == 'ldr' and len(operands) >= 2:
        base = operands[1].lstrip('[').rstrip(']')
        if base in registers:
            offset = int(operands[2].lstrip('#').rstrip(']'), 0) if len(operands) == 3 else 0
            addr = registers[base] + offset
            note = bindings.get(addr, '')
            for s in sections:
                if s.name == '__objc_selrefs' and s.virtual_address <= addr < s.virtual_address + s.size:
                    note = cstr(u64(addr))
    elif ins.mnemonic in ('bl', 'b') and ins.op_str.startswith('#'):
        note = stubs.get(int(ins.op_str[1:], 0), '')
        if ins.mnemonic == 'bl':
            registers = {k: v for k, v in registers.items() if k.startswith('x') and k[1:].isdigit() and int(k[1:]) >= 19}
    lines.append(f'{ins.address:#x}: {ins.mnemonic:8} {ins.op_str:48} {note}')
path = OUT / f'disasm-{start:x}.txt'
path.write_text('\n'.join(lines), encoding='utf-8')
print(path.name)
