"""Bounded offline ARM64 analysis of the supplied MikotoHelper; never loads it into a host process.

Imports are intercepted with synthetic values. Unsupported calls stop the model.
The text-route mode stops at AddMsg and does not invoke any real messaging API.
The session-source mode models empty home sessions and stops at a local username getter.
The settings-strings mode only decodes four audited local string ranges, with no imported calls.
The image-strings mode decodes one audited message-library string range, stopping before host calls.
The image-route mode models one synthetic UIImage and stops before AddMsg.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE_HASH = '0a11bacae2a0131b0ccbdf20ce49f9374bcd50c0d054fc290e9ba9e3b725eb43'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--entry', required=True, type=lambda value: int(value, 0))
    parser.add_argument('--mode', choices=('registration', 'text-route', 'image-route', 'session-source', 'settings-strings', 'image-strings'), default='registration')
    parser.add_argument('--binary', type=Path, default=ROOT / 'analysis/rootfs/Library/MobileSubstrate/DynamicLibraries/MikotoHelper.dylib')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--image-long-selector', choices=('present', 'absent'), default='present',
                        help='Synthetic image extension capability; used only by image-route')
    args = parser.parse_args()
    data = args.binary.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_HASH:
        parser.error('This evidence model is pinned to the supplied 2.5.0 ARM64 dylib hash')
    if args.mode == 'text-route' and args.entry != 0x272D588:
        parser.error('Synthetic text-route inputs are defined only for entry 0x272d588')
    if args.mode == 'image-route' and args.entry != 0x2733A40:
        parser.error('Synthetic image-route inputs are defined only for entry 0x2733a40')
    if args.mode == 'session-source' and args.entry != 0x32CD560:
        parser.error('Synthetic session-source inputs are defined only for entry 0x32cd560')
    settings_ranges = {
        0x5B823C8: (None, {'legacySettingsClass': 0x60FFDD0, 'otherSettingsClass': 0x60FFE20,
                         'managerSettingsClass': 0x60FFE60}),
        0x5BC1BC8: (0x5BC1DAC, {'legacyTableIvar': 0x6100E80}),
        0x5BC3BFC: (0x5BC3D34, {'managerTableIvar': 0x6100F5F}),
        0x5BC4238: (0x5BC436C, {'managerTableIvar': 0x6100F9B}),
    }
    if args.mode == 'settings-strings' and args.entry not in settings_ranges:
        parser.error('Settings decoding is restricted to four audited string-initialization entries')
    if args.mode == 'image-strings' and args.entry != 0x3652694:
        parser.error('Image string decoding is restricted to the audited message-library decoder')
    decoding_strings = args.mode in ('settings-strings', 'image-strings')
    if args.mode == 'image-strings':
        settings_ranges = {0x3652694: (0x3652D90, {'imageSourceClass': 0x5F62111})}
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
    stopped_at_session = False
    stopped_at_settings_strings = False
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

    def object_label(address):
        if address in labels:
            return labels[address]
        try:
            _isa, flags, pointer, length = struct.unpack('<QQQQ', machine.mem_read(address, 32))
            if flags == 0x7C8 and length < 512:
                return bytes(machine.mem_read(pointer, length)).decode('utf-8', 'replace')
        except UcError:
            pass
        return hex(address)

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
    elif args.mode == 'session-source':
        machine.reg_write(UC_ARM64_REG_X0, object_token('synthetic-galaxy-controller'))
        machine.reg_write(UC_ARM64_REG_X1, string_pointer('candidateItemsFromHomeSessions'))
    elif args.mode == 'image-route':
        for register, value in ((UC_ARM64_REG_X0, object_token('PJHelper')),
                                (UC_ARM64_REG_X1, string_pointer('sendMsgWithImage:WithToUserName:')),
                                (UC_ARM64_REG_X2, object_token('synthetic-image')),
                                (UC_ARM64_REG_X3, object_token('synthetic-target@chatroom'))):
            machine.reg_write(register, value)

    def imported_call(uc, pc, _size, _data):
        nonlocal stopped_at_send, stopped_at_session, stopped_at_settings_strings
        if decoding_strings and pc == settings_ranges[args.entry][0]:
            stopped_at_settings_strings = True
            uc.emu_stop()
            return
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
        if decoding_strings:
            # Decode only; stop before the constructor's first Objective-C call.
            if args.entry == 0x5B823C8 and name == '_objc_msgSend' and caller == 0x5BA9E04:
                stopped_at_settings_strings = True
            else:
                problems.append({'unexpectedImportInStringDecoder': name, 'caller': hex(caller)})
            uc.emu_stop()
            return
        elif name in ('_objc_getClass', '_objc_getMetaClass', '_sel_registerName'):
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
        elif name == '_memset' and args.mode == 'session-source':
            if x2 > 4096 or not stack <= x0 <= stack + 0x400000 - x2:
                raise RuntimeError('memset is outside the bounded synthetic stack')
            uc.mem_write(x0, bytes([x1 & 255]) * x2)
            result = x0
        elif name == '_objc_msgSend' and args.mode == 'session-source':
            selector, receiver = cstring(x1), object_label(x0)
            messages.append({'caller': hex(caller), 'receiver': receiver, 'selector': selector,
                             'arg1': object_label(x2), 'arg2': object_label(x3)})
            if selector == 'GetUserNamesOnSessionList':
                stopped_at_session = True
                uc.emu_stop()
                return
            if not x0:
                result = 0
            elif selector == 'getMMContextWithServiceName:':
                result = object_token('service:' + object_label(x2))
            elif selector in ('array', 'dictionary', 'arrayWithObjects:count:', 'topSessions', 'normalSessions'):
                result = object_token('synthetic-empty-collection')
            elif selector in ('count', 'countByEnumeratingWithState:objects:count:'):
                result = 0
            elif selector == 'respondsToSelector:':
                result = 0
            else:
                problems.append({'unsupportedSelector': selector, 'receiver': receiver, 'caller': hex(caller)})
                uc.emu_stop()
                return
        elif name == '_UIImageJPEGRepresentation' and args.mode == 'image-route':
            if object_label(x0) != 'synthetic-image':
                problems.append({'unexpectedImageInput': object_label(x0), 'caller': hex(caller)})
                uc.emu_stop()
                return
            result = object_token('synthetic-jpeg-data')
        elif name == '_objc_msgSend' and args.mode == 'image-route':
            selector, receiver = cstring(x1), object_label(x0)
            messages.append({'caller': hex(caller), 'receiver': receiver, 'selector': selector,
                             'arg1': object_label(x2), 'arg2': object_label(x3),
                             'arg3': object_label(uc.reg_read(UC_ARM64_REG_X4))})
            if selector == 'AddMsg:MsgWrap:':
                stopped_at_send = True
                uc.emu_stop()
                return
            if selector == 'alloc' and receiver == 'CMessageWrap':
                result = object_token('synthetic-image-wrap')
            elif selector == 'initWithMsgType:' and receiver == 'synthetic-image-wrap' and x2 == 3:
                result = x0
            elif selector == 'getLocalUsrName:':
                result = object_token('synthetic-account')
            elif selector == 'valueForKey:' and receiver == 'synthetic-image-wrap' and object_label(x2) == 'm_extendInfoWithMsgType':
                result = object_token('synthetic-image-extend-info')
            elif selector == 'respondsToSelector:' and receiver == 'synthetic-image-extend-info' and cstring(x2) == 'setImage:withData:isLongOriginImage:':
                result = int(args.image_long_selector == 'present')
            elif selector == 'respondsToSelector:' and receiver == 'synthetic-image-extend-info' and cstring(x2) == 'setImage:withData:isOriginImage:':
                result = 1
            elif receiver == 'synthetic-image-wrap' and selector in (
                    'setM_nsFromUsr:', 'setM_nsToUsr:', 'setM_uiCreateTime:', 'setM_uiStatus:'):
                result = 0
            elif receiver == 'synthetic-image-extend-info' and selector in (
                    'setImage:withData:isLongOriginImage:', 'setImage:withData:isOriginImage:'):
                result = 0
            elif selector == 'getTimetempSystem' and x0 == 0x5D0A9F8:
                result = 1700000000
            elif selector == 'currentContext' and receiver == 'MMContext':
                result = object_token('MMContext-instance')
            elif selector == 'getService:' and receiver == 'MMContext-instance' and object_label(x2) == 'CMessageMgr':
                result = object_token('service:CMessageMgr')
            else:
                problems.append({'unsupportedSelector': selector, 'receiver': receiver, 'caller': hex(caller)})
                uc.emu_stop()
                return
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
        if args.mode == 'session-source':
            machine.emu_start(0x32E4740, sentinel, timeout=15000000, count=1000000)
            if machine.reg_read(UC_ARM64_REG_PC) != sentinel or problems:
                raise RuntimeError('Galaxy string/registration initializer did not complete')
            machine.reg_write(UC_ARM64_REG_SP, stack + 0x3F0000)
            machine.reg_write(UC_ARM64_REG_LR, sentinel)
            machine.reg_write(UC_ARM64_REG_X0, object_token('synthetic-galaxy-controller'))
            machine.reg_write(UC_ARM64_REG_X1, string_pointer('candidateItemsFromHomeSessions'))
        machine.emu_start(args.entry, sentinel, timeout=15000000, count=1000000)
    except (UcError, RuntimeError) as error:
        problems.append({'error': str(error), 'pc': hex(machine.reg_read(UC_ARM64_REG_PC))})
    end_pc = machine.reg_read(UC_ARM64_REG_PC)
    completed = (end_pc == sentinel or stopped_at_send or stopped_at_session or stopped_at_settings_strings) and not problems
    table_class_strings = []
    if args.entry in (0x34F8D0C, 0x33D8EA0) and args.mode == 'registration':
        for section in sections:
            if section.name != '__data':
                continue
            content = bytes(machine.mem_read(section.virtual_address, section.size))
            for match in re.finditer(rb'(?:MM|WC)TableView[A-Za-z]{1,60}\x00', content):
                table_class_strings.append({'address': hex(section.virtual_address + match.start()),
                                            'text': match[0][:-1].decode('ascii')})
    report = {'sourceSHA256': SOURCE_HASH, 'entry': hex(args.entry), 'mode': args.mode,
              'completedModel': completed, 'endPC': hex(end_pc), 'stoppedAtSendBoundary': stopped_at_send,
              'stoppedAtSessionReadBoundary': stopped_at_session,
              'stoppedAtSettingsStringBoundary': stopped_at_settings_strings and args.mode == 'settings-strings',
              'stoppedAtImageStringBoundary': stopped_at_settings_strings and args.mode == 'image-strings',
              'settingsStrings': ({key: {'address': hex(address), 'text': cstring(address)}
                                   for key, address in settings_ranges[args.entry][1].items()}
                                  if stopped_at_settings_strings and args.mode == 'settings-strings' else {}),
              'decodedTableClasses': table_class_strings,
              'decodedImageSourceClass': ({'address': '0x5f62111', 'text': cstring(0x5F62111)}
                                          if args.mode == 'image-strings' and completed else {}),
              'calls': dict(calls), 'registrations': registrations, 'messages': messages, 'problems': problems,
              'model': ('Offline string decoding only; stops before the first imported call or at an audited decoder boundary. No gates or host methods run.'
                        if decoding_strings else
                        'Offline ARM64 emulation; imports stubbed and classes assumed present. No real iOS, networking, registration or sending.'),
              'assumptions': (['Initializer 0x32e4740 decodes local strings; registration imports are inert.',
                               'Home session collections are synthetic empty collections; service objects are tokens.',
                               'Execution stops before GetUserNamesOnSessionList returns; no group contents or completeness modeled.']
                              if args.mode == 'session-source' else
                              ['Inputs are one synthetic UIImage and target; JPEG data and extension are tokens.',
                               'Extension long selector is assumed ' + args.image_long_selector + '.',
                               'Getter valueForKey:m_extendInfoWithMsgType returns a synthetic extension.',
                               'Image setters are inert; no real image encoding, construction or iOS ABI is modeled.']
                              if args.mode == 'image-route' else []),
              'limits': {'instructionCountPerPhase': 1000000, 'timeoutSecondsPerPhase': 15, 'imageMiB': 128}}
    output = args.output or ROOT / 'analysis/reports' / f'offline-{args.mode}-{args.entry:x}.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'report': str(output), 'completedModel': completed, 'registrations': len(registrations),
                      'messages': len(messages), 'problems': problems}, ensure_ascii=True))
    return 0 if completed else 1


if __name__ == '__main__':
    raise SystemExit(main())
