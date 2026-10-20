"""Bounded offline ARM64 analysis of the supplied MikotoHelper; never loads it into a host process.

Imports are intercepted with synthetic values. Unsupported calls stop the model.
The text-route mode stops at AddMsg and does not invoke any real messaging API.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE_HASH = '0a11bacae2a0131b0ccbdf20ce49f9374bcd50c0d054fc290e9ba9e3b725eb43'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--entry', required=True, type=lambda value: int(value, 0))
    parser.add_argument('--mode', choices=('registration', 'text-route'), default='registration')
    parser.add_argument('--binary', type=Path, default=ROOT / 'analysis/rootfs/Library/MobileSubstrate/DynamicLibraries/MikotoHelper.dylib')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    data = args.binary.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_HASH:
        parser.error('This evidence model is pinned to the supplied 2.5.0 ARM64 dylib hash')
    if args.mode == 'text-route' and args.entry != 0x272D588:
        parser.error('Synthetic text-route inputs are defined only for entry 0x272d588')
    sys.path.insert(0, str(ROOT / 'analysis/python-libs'))
    import lief
    from unicorn import Uc, UcError, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
    from unicorn.arm64_const import (UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2,
                                   UC_ARM64_REG_X3, UC_ARM64_REG_X4, UC_ARM64_REG_SP,
                                   UC_ARM64_REG_LR, UC_ARM64_REG_PC)
    binary = lief.MachO.parse(data).at(0)
    sections = list(binary.sections)
    text = next(section for section in sections if section.name == '__text')
    if not text.virtual_address <= args.entry < text.virtual_address + text.size:
        parser.error('Entry is outside the text section')
    upper = max(section.virtual_address + section.size for section in sections)
    if upper > 0x8000000:
        parser.error('Image exceeds the bounded 128 MiB model')
    machine = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    machine.mem_map(0, (upper + 4095) & ~4095)
    for section in sections:
        if section.virtual_address and len(section.content):
            machine.mem_write(section.virtual_address, bytes(section.content))
    stack, heap, sentinel = 0x7000000000, 0x7100000000, 0x7200000000
    machine.mem_map(stack, 0x400000)
    machine.mem_map(heap, 0x400000)
    machine.mem_map(sentinel, 0x1000)
    machine.mem_write(sentinel, b'\xc0\x03\x5f\xd6')
    machine.reg_write(UC_ARM64_REG_SP, stack + 0x3F0000)
    machine.reg_write(UC_ARM64_REG_LR, sentinel)
    handlers, imported, labels, strings = {}, {}, {}, {}
    next_object, next_string = heap + 0x100000, heap + 0x200000
    calls, registrations, messages, problems = collections.Counter(), [], [], []
    stopped_at_send = False
    for binding in binary.bindings:
        if not binding.has_symbol:
            continue
        name = binding.symbol.name
        if name not in imported:
            address = heap + len(imported) * 16
            if address >= heap + 0x100000:
                parser.error('Synthetic import range exhausted')
            imported[name] = address
            handlers[address] = name
            machine.mem_write(address, b'\xc0\x03\x5f\xd6')
        machine.mem_write(binding.address, struct.pack('<Q', imported[name]))
        if name.startswith('_OBJC_CLASS_$_'):
            labels[imported[name]] = name.split('$_', 1)[1]

    def cstring(address):
        if not address:
            return ''
        try:
            return bytes(machine.mem_read(address, 512)).split(b'\0')[0].decode('utf-8', 'replace')
        except UcError:
            return '<invalid-pointer>'

    def object_token(label):
        nonlocal next_object
        for address, value in labels.items():
            if value == label:
                return address
        if next_object >= heap + 0x200000:
            raise RuntimeError('Synthetic object range exhausted')
        address = next_object
        next_object += 16
        labels[address] = label
        return address

    def string_pointer(value):
        nonlocal next_string
        if value not in strings:
            encoded = value.encode() + b'\0'
            if next_string + len(encoded) >= heap + 0x400000:
                raise RuntimeError('Synthetic string range exhausted')
            strings[value] = next_string
            machine.mem_write(next_string, encoded)
            next_string += len(encoded)
        return strings[value]

    if args.mode == 'text-route':
        for register, value in ((UC_ARM64_REG_X0, object_token('PJHelper')),
                                (UC_ARM64_REG_X1, string_pointer('sendMsgWithText:WithToUserName:WithReSourece:')),
                                (UC_ARM64_REG_X2, object_token('synthetic-text')),
                                (UC_ARM64_REG_X3, object_token('synthetic-target@chatroom')),
                                (UC_ARM64_REG_X4, 0)):
            machine.reg_write(register, value)

    def imported_call(uc, pc, _size, _data):
        nonlocal stopped_at_send
        if pc == sentinel:
            uc.emu_stop()
            return
        name = handlers.get(pc)
        if not name:
            return
        calls[name] += 1
        x0, x1, x2, x3 = (uc.reg_read(register) for register in
                          (UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3))
        caller = uc.reg_read(UC_ARM64_REG_LR)
        if name in ('_objc_getClass', '_objc_getMetaClass', '_sel_registerName'):
            prefix = 'meta:' if name == '_objc_getMetaClass' else ''
            result = object_token(prefix + cstring(x0))
        elif name in ('_class_replaceMethod', '_class_addMethod', '_MSHookMessageEx'):
            registrations.append({'class': labels.get(x0, hex(x0)), 'selector': labels.get(x1, cstring(x1)),
                                  'imp': hex(x2), 'encoding': cstring(x3) if name != '_MSHookMessageEx' else None,
                                  'api': name, 'caller': hex(caller)})
            result = int(name == '_class_addMethod')
        elif name == '_object_getClass':
            result = object_token('meta:' + labels.get(x0, hex(x0)))
        elif name == '_class_getName':
            result = string_pointer(labels.get(x0, hex(x0)))
        elif name == '_strcmp':
            left, right = cstring(x0), cstring(x1)
            result = ((left > right) - (left < right)) & 0xFFFFFFFFFFFFFFFF
        elif name == '_objc_storeStrong':
            uc.mem_write(x0, struct.pack('<Q', x1))
            result = 0
        elif name in ('_objc_retain', '_objc_autorelease', '_objc_retainAutoreleasedReturnValue', '_objc_autoreleaseReturnValue'):
            result = x0
        elif name == '_objc_release':
            result = 0
        elif name == '_objc_msgSend' and args.mode == 'text-route':
            selector = labels.get(x1, cstring(x1))
            receiver = labels.get(x0, hex(x0))
            messages.append({'caller': hex(caller), 'receiver': receiver, 'selector': selector,
                             'arg1': labels.get(x2, hex(x2)), 'arg2': labels.get(x3, hex(x3))})
            if selector == 'AddMsg:MsgWrap:':
                stopped_at_send = True
                uc.emu_stop()
                return
            if not x0:
                result = 0
            elif selector == 'currentContext':
                result = object_token('MMContext-instance')
            elif selector == 'getService:':
                result = object_token('service:' + labels.get(x2, hex(x2)))
            elif selector == 'getMySelfWxidNew':
                result = object_token('synthetic-account')
            elif selector == 'getTimetempSystem':
                result = 1700000000
            elif selector == 'getMessageWrapWithText:WithFromUsr:WithToUsr:WithSource:CreateTime:':
                result = object_token('synthetic-prepared-text-wrap')
            else:
                problems.append({'unsupportedSelector': selector, 'receiver': receiver, 'caller': hex(caller)})
                uc.emu_stop()
                return
        else:
            problems.append({'unsupportedImport': name, 'caller': hex(caller)})
            uc.emu_stop()
            return
        uc.reg_write(UC_ARM64_REG_X0, result)
        uc.reg_write(UC_ARM64_REG_PC, caller)

    machine.hook_add(UC_HOOK_CODE, imported_call)
    try:
        machine.emu_start(args.entry, sentinel, timeout=15000000, count=1000000)
    except (UcError, RuntimeError) as error:
        problems.append({'error': str(error), 'pc': hex(machine.reg_read(UC_ARM64_REG_PC))})
    end_pc = machine.reg_read(UC_ARM64_REG_PC)
    completed = (end_pc == sentinel or stopped_at_send) and not problems
    report = {'sourceSHA256': SOURCE_HASH, 'entry': hex(args.entry), 'mode': args.mode,
              'completedModel': completed, 'endPC': hex(end_pc), 'stoppedAtSendBoundary': stopped_at_send,
              'calls': dict(calls), 'registrations': registrations, 'messages': messages, 'problems': problems,
              'model': 'Offline ARM64 emulation; imports stubbed and classes assumed present. No real iOS, networking, registration or sending.',
              'limits': {'instructionCount': 1000000, 'timeoutSeconds': 15, 'imageMiB': 128}}
    output = args.output or ROOT / 'analysis/reports' / f'offline-{args.mode}-{args.entry:x}.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'report': str(output), 'completedModel': completed, 'registrations': len(registrations),
                      'messages': len(messages), 'problems': problems}, ensure_ascii=True))
    return 0 if completed else 1


if __name__ == '__main__':
    raise SystemExit(main())
