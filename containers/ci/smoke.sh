#!/bin/sh
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$work"
raz --version | grep '^raz 0\.21\.0, '
cat > Hello.raz <<'EOF'
module Hello;
import Out;
proc main*;
begin
    Out.str("hello, world\n");
end;
end Hello.
EOF
raz -Werror Hello.raz
test "$(./Hello)" = 'hello, world'
cat > Libc.raz <<'EOF'
module Libc;
import C;
proc main*;
const message = "libc-ok\n";
begin
    if C.write(1, PTR(message), LEN(message)) # LEN(message) then
        C.exit(1);
    end;
end;
end Libc.
EOF
raz -Werror Libc.raz
test "$(./Libc)" = libc-ok
raz -Werror -o Pretty /opt/raz/tools/Pretty.raz
./Pretty Hello.raz > formatted.raz
test -s formatted.raz
test "$(concha -c 'echo concha-ok')" = concha-ok
cat > Robfile <<'EOF'
check:
    printf 'robbie-ok\n'
EOF
robbie -q check > robbie.log
grep -qx robbie-ok robbie.log
printf 'raz CI smoke tests passed\n'
