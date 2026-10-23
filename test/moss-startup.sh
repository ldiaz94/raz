#!/bin/sh
# Host checks for explicit Moss code generation. Run argument-copy fixtures in Moss.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/moss-startup
cat > build/moss-startup/Guard.raz <<'RAZ'
module Guard;
proc main*: INT;
begin
    if (ARGC() # 0) or (ARGV() # nil) then return 1; end;
    return 0;
end;
end Guard.
RAZ
./raz -Werror -bare -o build/moss-startup/bare build/moss-startup/Guard.raz
./raz -Werror -moss -o build/moss-startup/moss build/moss-startup/Guard.raz
build/moss-startup/bare
python3 - <<'PY'
import struct
from pathlib import Path

def entry(name):
    data = Path('build/moss-startup/' + name).read_bytes()
    start, phoff = struct.unpack_from('<QQ', data, 24)
    size, count = struct.unpack_from('<HH', data, 54)
    for i in range(count):
        kind, flags, offset, address, _, length = struct.unpack_from('<IIQQQQ', data, phoff + i * size)
        if kind == 1 and address <= start < address + length:
            return data[offset + start - address:offset + start - address + 16]
    raise AssertionError('entry not mapped')

# Version discovery is a Moss interrupt; the old bare entry remains untouched.
assert entry('moss').startswith(bytes.fromhex('b81400000031ffcd804883f8010f85'))
assert not entry('bare').startswith(bytes.fromhex('b81400000031ffcd80'))
PY
printf '%s\n' 'Moss startup: PASS explicit interrupt/version guard; legacy bare arguments remain zero'
