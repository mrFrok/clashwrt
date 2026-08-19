#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
po2lmo.py -- compile a gettext .po catalogue into LuCI's .lmo format.

LuCI ships a C tool for this, but building it needs the lemon parser
generator and the luci-base source tree, which is a lot of machinery for a
package that is otherwise pure shell and JavaScript. Since the format is
small and stable, this reimplements it so the catalogues can be built (and
regenerated in CI) with nothing but Python.

Layout, matching modules/luci-base/src/po2lmo.c:

    [string data]   every msgstr, each padded with NULs to a 4-byte boundary
    [index]         one 16-byte record per entry, sorted by key hash:
                        uint32 key_id   SuperFastHash of the msgid
                        uint32 val_id   plural count (1 for simple entries)
                        uint32 offset   where the string starts
                        uint32 length   its length in bytes
    [trailer]       uint32 total size of the string data section

All integers are big-endian. The header's "Plural-Forms:" line is stored as
a special entry with both ids set to zero.

Usage: po2lmo.py input.po output.lmo
"""

import re
import struct
import sys

MASK = 0xFFFFFFFF


def u32(x):
    return x & MASK


def get16(data, i):
    """The C reads two bytes little-endian regardless of host order."""
    return data[i] | (data[i + 1] << 8)


def signed_char(b):
    return b - 256 if b > 127 else b


def sfh_hash(data, init):
    """SuperFastHash, as used by LuCI. `init` is the string length."""
    length = len(data)
    if length <= 0:
        return 0

    hash_ = u32(init)
    rem = length & 3
    n = length >> 2
    i = 0

    while n > 0:
        hash_ = u32(hash_ + get16(data, i))
        tmp = u32((get16(data, i + 2) << 11) ^ hash_)
        hash_ = u32((hash_ << 16) ^ tmp)
        i += 4
        hash_ = u32(hash_ + (hash_ >> 11))
        n -= 1

    if rem == 3:
        hash_ = u32(hash_ + get16(data, i))
        hash_ = u32(hash_ ^ u32(hash_ << 16))
        hash_ = u32(hash_ ^ u32(signed_char(data[i + 2]) << 18))
        hash_ = u32(hash_ + (hash_ >> 11))
    elif rem == 2:
        hash_ = u32(hash_ + get16(data, i))
        hash_ = u32(hash_ ^ u32(hash_ << 11))
        hash_ = u32(hash_ + (hash_ >> 17))
    elif rem == 1:
        hash_ = u32(hash_ + signed_char(data[i]))
        hash_ = u32(hash_ ^ u32(hash_ << 10))
        hash_ = u32(hash_ + (hash_ >> 1))

    # final avalanche
    hash_ = u32(hash_ ^ u32(hash_ << 3))
    hash_ = u32(hash_ + (hash_ >> 5))
    hash_ = u32(hash_ ^ u32(hash_ << 4))
    hash_ = u32(hash_ + (hash_ >> 17))
    hash_ = u32(hash_ ^ u32(hash_ << 25))
    hash_ = u32(hash_ + (hash_ >> 6))
    return hash_


STR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')


def unquote(line):
    """
    Take the quoted part of a po line.

    Only \\" and \\\\ are unescaped -- everything else, \\n included, stays
    exactly as written. That looks wrong but matches the C tool, and LuCI
    reads the catalogues back with the same convention.
    """
    m = STR_RE.search(line)
    if not m:
        return None
    s = m.group(1)
    out = []
    esc = False
    for ch in s:
        if esc:
            if ch in ('"', '\\'):
                out.append(ch)
            else:
                out.append('\\')
                out.append(ch)
            esc = False
        elif ch == '\\':
            esc = True
        else:
            out.append(ch)
    if esc:
        out.append('\\')
    return ''.join(out)


def parse_po(path):
    """Return a list of (msgid, [msgstr, ...]); msgid is empty for the header."""
    results = []
    msgid = None
    plurals = {}
    cur = None
    cur_idx = 0

    def flush():
        nonlocal msgid, plurals, cur, cur_idx
        if msgid is not None:
            results.append((msgid, [plurals[k] for k in sorted(plurals)]))
        msgid, plurals, cur, cur_idx = None, {}, None, 0

    with open(path, encoding='utf-8') as fh:
        lines = fh.readlines()

    for line in lines + ['msgid ""\n']:      # sentinel flushes the last entry
        stripped = line.strip()
        if stripped.startswith('#') or not stripped:
            continue

        if stripped.startswith('msgid "'):
            flush()
            msgid = unquote(stripped) or ''
            cur = 'id'
        elif stripped.startswith('msgid_plural "'):
            cur = 'id_plural'
        elif stripped.startswith('msgstr['):
            cur_idx = int(stripped[7:stripped.index(']')])
            plurals[cur_idx] = unquote(stripped) or ''
            cur = 'str'
        elif stripped.startswith('msgstr "'):
            cur_idx = 0
            plurals[0] = unquote(stripped) or ''
            cur = 'str'
        elif stripped.startswith('"'):
            part = unquote(stripped) or ''
            if cur == 'id':
                msgid = (msgid or '') + part
            elif cur == 'str':
                plurals[cur_idx] = plurals.get(cur_idx, '') + part

    return results


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: po2lmo.py input.po output.lmo')

    entries = []
    blob = bytearray()

    def add(key_id, val_id, text):
        raw = text.encode('utf-8')
        offset = len(blob)
        blob.extend(raw)
        blob.extend(b'\0' * ((4 - (len(raw) % 4)) % 4))
        entries.append((key_id, val_id, offset, len(raw)))

    for msgid, vals in parse_po(sys.argv[1]):
        if msgid and vals and vals[0]:
            for i, val in enumerate(vals):
                if not val:
                    continue
                key = msgid if len(vals) == 1 else '%s\2%d' % (msgid, i)
                kb = key.encode('utf-8')
                key_id = sfh_hash(kb, len(kb))
                vb = val.encode('utf-8')
                val_id = sfh_hash(vb, len(vb))
                # the C tool skips entries whose value hashes to the key
                if key_id == val_id:
                    continue
                add(key_id, len(vals), val)
        elif not msgid and vals and vals[0]:
            # header: only the plural formula is carried over
            for field in vals[0].split('\\n'):
                if field.lower().startswith('plural-forms: '):
                    add(0, 0, field[len('plural-forms: '):])
                    break

    if not blob:
        sys.exit('nothing to write: no translated messages found')

    entries.sort(key=lambda e: e[0])

    with open(sys.argv[2], 'wb') as out:
        out.write(blob)
        for key_id, val_id, offset, length in entries:
            out.write(struct.pack('>IIII', key_id, val_id, offset, length))
        out.write(struct.pack('>I', len(blob)))

    print('%s: %d entries, %d bytes of strings' % (sys.argv[2], len(entries), len(blob)))


if __name__ == '__main__':
    main()
