#!/bin/sh
# Runs the conformance suite, conform/check.sh, with this compiler's
# messages for it in test/msg; then compiles and runs every example
# and this compiler's own tests, and compares what each prints, and its
# exit status, with what is expected:
#   X.raz     the program
#   X.expect  its standard output
#   X.args    its arguments, one per line (optional)
#   X.status  its exit status (optional; 0 if missing), 128 and the
#             signal's number for one stopped by a signal
#   X.stderr  its standard error (optional; not compared if missing),
#             each address in it, 0x and hex digits, written 0x?
# A program without X.expect is compiled, not run. test/libc puts
# lib/Sys.raz, over the C library, before the system call one.
# Programs in test/err must not compile, and must print X.err (with
# the compiler's own version in a library's note written as N); there
# X.args holds the compiler's options. The examples, test/libc, the
# tools and the library's tests are compiled with -Werror, so warnings
# fail them. Then the version, tools/Doc.raz, the report's examples,
# the tutorial's, tools/Pretty.raz, and the library's own tests.

raz=./raz
# Fixtures use only their explicit module paths and the standard library.
# library-path.sh sets up its own HOME and RAZ_PATH for user-path checks.
RAZ_PATH=
export RAZ_PATH
out=build/check
mkdir -p $out
ulimit -c 0   # the tests stopped by a signal leave no core
ulimit -s 8192   # Linux's usual stack: StackOverflow's depth depends on it, and CI's runner gives more
pass=0
fail=0

conform/check.sh $raz test/msg > $out/conform.out
grep -v '^[0-9]* passed' $out/conform.out
set -- $(tail -1 $out/conform.out)
pass=$1; fail=$3

run() {   # run dir name
    dir=$1; name=$2
    flags=
    [ $dir = examples ] || [ $dir = test/libc ] && flags=-Werror
    if ! $raz $flags $libc -I $dir/mods -o $out/$name $dir/$name.raz 2>$out/$name.cerr; then
        echo "FAIL $dir/$name$libc: doesn't compile: $(cat $out/$name.cerr)"
        fail=$((fail + 1)); return
    fi
    if [ ! -f $dir/$name.expect ]; then pass=$((pass + 1)); return; fi
    set --
    if [ -f $dir/$name.args ]; then
        while IFS= read -r a; do set -- "$@" "$a"; done < $dir/$name.args
    fi
    # in $(...), so that what the shell says of a signal goes nowhere;
    # in ( ), since dash says it with the command's 2> still in place
    status=$( { ( exec $out/$name "$@" ) > $out/$name.out 2>$out/$name.err; echo $?; } 2>/dev/null )
    want=0
    [ -f $dir/$name.status ] && want=$(cat $dir/$name.status)
    if ! cmp -s $out/$name.out $dir/$name.expect; then
        echo "FAIL $dir/$name$libc: output differs"
        diff $out/$name.out $dir/$name.expect | head -5
        fail=$((fail + 1))
    elif [ $status != $want ]; then
        echo "FAIL $dir/$name$libc: status $status, not $want"
        fail=$((fail + 1))
    elif [ -f $dir/$name.stderr ] && ! sed 's/0x[0-9a-f]*/0x?/g' $out/$name.err |
            cmp -s - $dir/$name.stderr; then
        echo "FAIL $dir/$name$libc: standard error differs"
        diff $out/$name.err $dir/$name.stderr | head -5
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

libc=
for f in examples/*.raz test/run/*.raz test/libc/*.raz test/bench/*.raz; do
    run $(dirname $f) $(basename $f .raz)
done
# test/libc again over musl, where its loader is installed
if [ -e /lib/ld-musl-x86_64.so.1 ]; then
    libc=' -libc musl'
    for f in test/libc/*.raz; do run test/libc $(basename $f .raz); done
    libc=
fi

# raz run: a static program and one over C, from memory, with their
# arguments, output and status passed through
runs() {   # runs file status [arg]...
    f=$1; want=$2; shift 2
    $raz run -I $(dirname $f)/mods $f "$@" > $out/run.out 2>/dev/null
    status=$?
    if cmp -s $out/run.out ${f%.raz}.expect && [ $status = $want ]; then pass=$((pass + 1))
    else echo "FAIL raz run $f: status $status, not $want, or output differs"; fail=$((fail + 1)); fi
}
runs conform/run/Args.raz 4 one 'two words' é
runs test/libc/Through.raz 2
for f in test/err/*.raz; do
    name=$(basename $f .raz)
    flags=
    [ -f test/err/$name.args ] && flags=$(cat test/err/$name.args)
    if $raz $flags -I test/err/mods -I test/run/mods -o $out/$name $f 2>$out/$name.cerr; then
        echo "FAIL $f: compiles"
        fail=$((fail + 1))
    elif ! sed 's/ this is raz [^)]*)/ this is raz N)/' $out/$name.cerr | cmp -s test/err/$name.err -; then
        echo "FAIL $f: says"; diff test/err/$name.err $out/$name.cerr
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
done
# RAZ_PROFILE: a profiled run says which procedure took its time
$raz -o $out/Busy test/list/Busy.raz
if RAZ_PROFILE=1 $out/Busy 2>&1 >/dev/null | sed -n 2p | grep -q 'Busy.spin$'; then pass=$((pass + 1))
else echo "FAIL RAZ_PROFILE: Busy.spin isn't first"; fail=$((fail + 1)); fi
# the manual pages, raz-lib(3) as make made it from lib/, which groff
# and mandoc, where there, must read without a warning
for f in doc/*.[1-9] build/raz-lib.3; do
    : > $out/man.out
    command -v groff > /dev/null && groff -mdoc -ww -z $f >> $out/man.out 2>&1
    command -v mandoc > /dev/null && mandoc -Tlint -Wwarning $f >> $out/man.out 2>&1
    if [ ! -s $out/man.out ]; then pass=$((pass + 1))
    else echo "FAIL $f"; head -5 $out/man.out; fail=$((fail + 1)); fi
done
# raz -noprofile leaves the profiler out, and raz -s the places too: a
# failed check is told by its address, and the program is smaller
$raz -noprofile -o $out/BusyNo test/list/Busy.raz
if [ -z "$(RAZ_PROFILE=1 $out/BusyNo 2>&1 >/dev/null)" ]; then pass=$((pass + 1))
else echo "FAIL raz -noprofile: a profile"; fail=$((fail + 1)); fi
$raz -o $out/Index test/strip/Index.raz
$raz -s -o $out/IndexS test/strip/Index.raz
$out/IndexS > $out/IndexS.out 2>&1
if [ $? = 2 ] && grep -q '^hello$' $out/IndexS.out && grep -q '^at 0x[0-9a-f]*: index 5 is out of range' $out/IndexS.out \
    && [ $(wc -c < $out/IndexS) -lt $(wc -c < $out/Index) ]; then pass=$((pass + 1))
else echo "FAIL raz -s:"; cat $out/IndexS.out; fail=$((fail + 1)); fi
# raz -base: loaded elsewhere, a program says the same of a failed
# check, the places found as at 400000H; one for the top 2 GB, as a
# higher-half kernel's, is made, though Linux won't run it there
entry() { od -An -tx8 -j24 -N8 $1 | tr -d ' '; }
$raz -base 7FE00000H -o $out/IndexB test/strip/Index.raz
$out/Index > $out/Index.out 2>&1
$out/IndexB > $out/IndexB.out 2>&1
$raz -base 0FFFFFFFF80000000H -o $out/IndexK test/strip/Index.raz
if [ $? = 0 ] && cmp -s $out/Index.out $out/IndexB.out && grep -q 'Index.main' $out/IndexB.out \
    && entry $out/IndexB | grep -q '^000000007fe' && entry $out/IndexK | grep -q '^ffffffff800'; then pass=$((pass + 1))
else echo "FAIL raz -base:"; cat $out/IndexB.out; fail=$((fail + 1)); fi
# raz -bare: no argc read, so ARGC() is 0, and no handlers set, so a nil
# pointer stops the program by SIGSEGV with nothing said; a failed
# check is still told by its place, and nothing is profiled
$raz -bare -o $out/Bare test/bare/Bare.raz
status=$( { ( exec $out/Bare one two ) > $out/Bare.out 2>$out/Bare.err; echo $?; } 2>/dev/null )
$raz -bare -o $out/IndexBare test/strip/Index.raz
RAZ_PROFILE=1 $out/IndexBare > $out/IndexBare.out 2>&1
if [ $status = 139 ] && [ "$(cat $out/Bare.out)" = 0 ] && [ ! -s $out/Bare.err ] \
    && cmp -s $out/Index.out $out/IndexBare.out; then pass=$((pass + 1))
else echo "FAIL raz -bare: status $status"; cat $out/Bare.out $out/Bare.err $out/IndexBare.out; fail=$((fail + 1)); fi

# a program with its own Rt (doc/compiler.md): raz -lib of nothing but
# test/own/lib/Rt.raz, whose exit and fail make their system calls
# themselves; Own ends with main's 3 after saying hello, OwnFail with 2
# after Rt.fail's kind 0, an index; built without -s, with Rt having no
# places, so the ELF has its symbols
rm -rf $out/own; mkdir -p $out/own
$raz -lib test/own/lib -Werror -bare -o $out/own/Own test/own/Own.raz
status=$( { ( exec $out/own/Own ) > $out/own/Own.out 2>&1; echo $?; } 2>/dev/null )
$raz -lib test/own/lib -Werror -bare -o $out/own/OwnFail test/own/OwnFail.raz
statusFail=$( { ( exec $out/own/OwnFail ) > $out/own/OwnFail.out 2>&1; echo $?; } 2>/dev/null )
if [ $status = 3 ] && [ $statusFail = 2 ] && [ "$(cat $out/own/Own.out)" = hello ] \
    && [ "$(cat $out/own/OwnFail.out)" = 'check failed: 0' ] \
    && readelf -s $out/own/Own | grep -q ' Own.main$' && readelf --debug-dump=decodedline $out/own/Own | grep -q 'Own.raz'; then pass=$((pass + 1))
else echo "FAIL own Rt: status $status, $statusFail"; cat $out/own/Own.out $out/own/OwnFail.out; fail=$((fail + 1)); fi

# raz -q, for an editor: check's rows; the names words offers at a
# cursor after a part of a name, after a module's dot, and none in a
# comment or a string; and where def finds a local, another module's
# name, a module and a built-in, which has no place. The text is
# standard input: checking an empty one shows that the file on disk
# isn't read.
for t in "check Check.raz check" "words Words.raz:9:16 prefix" "words Words.raz:10:11 export" \
    "words Words.raz:11:10 none" "words Words.raz:12:15 none" "def Def.raz:10:15 def-local" \
    "def Def.raz:11:9 def-export" "def Def.raz:11:6 def-module" "def Def.raz:10:24 def-builtin"; do
    set -- $t
    f=test/query/${2%%:*}
    $raz -q $1 test/query/$2 < $f > $out/query.out
    if [ "$3" = none ]; then : > $out/query.expect; else cp test/query/$3.expect $out/query.expect; fi
    if cmp -s $out/query.out $out/query.expect; then pass=$((pass + 1))
    else echo "FAIL raz -q $1 $2"; diff $out/query.expect $out/query.out | head -5; fail=$((fail + 1)); fi
done
if [ -z "$($raz -q check test/query/Words.raz < /dev/null | grep 'expected "module"')" ]; then
    echo "FAIL raz -q check: read the file, not standard input"; fail=$((fail + 1))
else pass=$((pass + 1)); fi

# what src/ asks of lib/ is what doc/compiler.md lists (test/asks.sh)
if sh test/asks.sh > $out/asks.out 2>&1; then pass=$((pass + 1))
else echo "FAIL test/asks.sh:"; cat $out/asks.out; fail=$((fail + 1)); fi

# raz -S: test/list/X.raz lists as X.expect
for f in test/list/*.raz; do
    want=test/list/$(basename $f .raz).expect
    [ -f $want ] || continue
    if $raz -S $f 2>&1 | cmp -s $want -; then pass=$((pass + 1))
    else echo "FAIL raz -S $f"; $raz -S $f 2>&1 | diff $want - | head; fail=$((fail + 1)); fi
done
# raz -S's form, as raz(1) states it: every line is blank, a procedure's
# name (after a blank line), a source line (number to column 6, two spaces,
# text) or an instruction (offset to column 14, two spaces, text); a jump
# gives its target as a number
if $raz -S test/list/Listing.raz 2>&1 | awk '
    NR == 1 && $0 != "" { bad = "first line not blank" }
    $0 == "" { blank = 1; next }
    /^[A-Za-z0-9]+\.[A-Za-z0-9.]+:$/ { if (!blank) bad = "name after no blank: " $0; blank = 0; next }
    { blank = 0 }
    match($0, /^ *[0-9]+/) && (RLENGTH == 6 || RLENGTH == 14) && substr($0, RLENGTH + 1, 2) == "  " {
        if (RLENGTH == 14 && $0 ~ /^ *[0-9]+  j[a-z]* / && $0 !~ /  j[a-z]* [0-9]+$/) bad = "jump with no offset: " $0
        next }
    { bad = "no form: " $0 }
    END { if (bad != "") { print bad; exit 1 } }'; then pass=$((pass + 1))
else echo "FAIL raz -S: a line not of raz(1)'s form"; fail=$((fail + 1)); fi
# the report's version is the one the compiler says it follows
# the version the compiler follows: the report's, or one it names while
# the compiler catches up
want=$(sed -n 's/^This is version \([0-9.-]*\) of the report.*/\1/p' doc/raz.md)
lag=$(sed -n 's/^The compiler follows version \([0-9.-]*\) until.*/\1/p' doc/raz.md)
want=${lag:-$want}
if ./raz --version | grep -qF "report $want"; then pass=$((pass + 1))
else echo "FAIL raz --version: not report $want"; fail=$((fail + 1)); fi

# tools/Doc.raz: on every library module, and as test/doc expects (X.expect
# for Doc, X.man for Doc man)
if ./raz -Werror -o $out/Doc tools/Doc.raz 2>$out/Doc.cerr; then
    for f in lib/*.raz; do
        if ! $out/Doc $f > $out/doc.out; then echo "FAIL Doc $f"; fail=$((fail + 1)); fi
    done
    for f in test/doc/*.expect; do
        name=$(basename $f .expect)
        m=lib/$name.raz
        [ -f $m ] || m=lib/$name.linux-x86_64.raz
        [ -f $m ] || m=test/doc/$name.raz
        if $out/Doc $m | cmp -s - $f; then pass=$((pass + 1))
        else echo "FAIL Doc $m: output differs"; fail=$((fail + 1)); fi
    done
    # Doc man, for the modules that have a test/doc/X.man
    for f in test/doc/*.man; do
        m=test/doc/$(basename $f .man).raz
        if $out/Doc man $m | cmp -s - $f; then pass=$((pass + 1))
        else echo "FAIL Doc man $m: output differs"; fail=$((fail + 1)); fi
    done

    # the report's examples that are whole modules: each compiles, and
    # each with a main runs and ends with status 0
    rm -rf $out/report; mkdir -p $out/report
    for name in $($out/Doc examples doc/raz.md $out/report) $($out/Doc examples doc/raz-lib.md $out/report); do
        if ! $raz -o $out/report/$name $out/report/$name.raz 2>$out/report/$name.cerr; then
            echo "FAIL report example $name: $(cat $out/report/$name.cerr)"; fail=$((fail + 1))
        elif grep -q '^proc main\*' $out/report/$name.raz && ! $out/report/$name > /dev/null 2>&1; then
            echo "FAIL report example $name: status $?"; fail=$((fail + 1))
        else pass=$((pass + 1)); fi
    done

    # the tutorial's programs: each with a main runs, in the directory
    # it was written to, so that a message names it as the page does;
    # it ends with test/man/X.status, or 0, and prints, standard output
    # then standard error, the block the page shows after it, if any
    rm -rf $out/man; mkdir -p $out/man
    for name in $($out/Doc examples doc/raz-tutorial.7 $out/man); do
        grep -q '^proc main\*' $out/man/$name.raz || continue
        want=0
        [ -f test/man/$name.status ] && want=$(cat test/man/$name.status)
        if ! (cd $out/man && ../../../$raz -Werror $name.raz 2>$name.cerr); then
            echo "FAIL tutorial example $name: $(cat $out/man/$name.cerr)"; fail=$((fail + 1))
        else
            status=$( { ( cd $out/man && exec ./$name ) > $out/man/$name.out 2>$out/man/$name.err; echo $?; } 2>/dev/null )
            if [ $status != $want ]; then
                echo "FAIL tutorial example $name: status $status, not $want"; fail=$((fail + 1))
            elif [ -f $out/man/$name.shown ] &&
                    ! cat $out/man/$name.out $out/man/$name.err | sed 's/ *$//' | cmp -s - $out/man/$name.shown; then
                echo "FAIL tutorial example $name: prints other than the page shows"; fail=$((fail + 1))
            else pass=$((pass + 1)); fi
        fi
    done
else
    echo "FAIL tools/Doc.raz: $(cat $out/Doc.cerr)"; fail=$((fail + 1))
fi

# tools/Pretty.raz: each test/pretty/X.raz comes out as X.expect, which
# comes out as it is; so do the library, the examples and the tools
if ./raz -Werror -o $out/Pretty tools/Pretty.raz 2>$out/Pretty.cerr; then
    for f in test/pretty/*.raz; do
        want=test/pretty/$(basename $f .raz).expect
        if $out/Pretty $f | cmp -s - $want && $out/Pretty $want | cmp -s - $want; then
            pass=$((pass + 1))
        else echo "FAIL Pretty $f: output differs"; fail=$((fail + 1)); fi
    done
    for f in lib/*.raz examples/*.raz tools/*.raz; do
        if ! $out/Pretty $f | cmp -s - $f; then
            echo "FAIL Pretty $f: not formatted"; fail=$((fail + 1))
        fi
    done
    pass=$((pass + 1))
else
    echo "FAIL tools/Pretty.raz: $(cat $out/Pretty.cerr)"; fail=$((fail + 1))
fi

# error recovery: tools/Mutate.raz changes one symbol of each program,
# and the compiler must not crash, must exit with status 0 or 1, must
# say "error:" when it exits with 1, and must not report one place twice.
# Reproduce a failure with: build/Mutate FILE SEED > M.raz
fuzz() {   # fuzz file seed
    f=$1; seed=$2; dir=$(dirname $f)
    mkdir -p $out/fuzz; m=$out/fuzz/$(basename $f)
    $out/Mutate $f $seed > $m
    $raz -I $dir/mods -o $out/mutant $m 2>$out/mutant.err
    status=$?
    why=
    if [ $status -gt 1 ]; then why="exit status $status"
    elif grep -q 'internal error' $out/mutant.err; then why="internal error"
    elif [ $status = 1 ] && ! grep -q ': error:' $out/mutant.err; then why="status 1 without an error"
    elif [ -n "$(grep ': error:' $out/mutant.err | sed 's/: error:.*//' | sort | uniq -d)" ]; then
        why="two errors at one place"
    fi
    if [ -n "$why" ]; then
        echo "FAIL fuzz $f seed $seed: $why"; cat $out/mutant.err
        fail=$((fail + 1))
    else pass=$((pass + 1)); fi
}
if ./raz -Werror -o $out/Mutate tools/Mutate.raz 2>$out/Mutate.cerr; then
    for f in examples/*.raz conform/run/*.raz test/run/*.raz lib/Opt.raz; do
        $raz -I $(dirname $f)/mods -o $out/mutant $f 2>/dev/null || continue
        for seed in ${FUZZ_SEEDS:-1 2 3}; do fuzz $f $seed; done
    done
else
    echo "FAIL tools/Mutate.raz: $(cat $out/Mutate.cerr)"; fail=$((fail + 1))
fi

# each library module's main is its test, run by tools/Test.raz,
# raztest, which says what it counted on its last line; Sys over C is
# tested in test/libc
if $raz -Werror -o $out/raztest tools/Test.raz 2>$out/raztest.cerr; then
    RAZ=$raz $out/raztest -j $(nproc 2>/dev/null || echo 1) -o $out/lib \
        $(for f in lib/*.raz; do [ $f != lib/Sys.raz ] && grep -q '^proc main\*' $f && echo $f; done) \
        > $out/raztest.out 2>&1
    set -- $(tail -1 $out/raztest.out)   # N passed, F failed, T timed out, S
    if [ "$2" = passed, ] && [ "$6" = timed ]; then
        pass=$((pass + $1)); fail=$((fail + $3 + $5))
        [ $(($3 + $5)) = 0 ] || grep -v '^ok ' $out/raztest.out
    else
        echo "FAIL tools/Test.raz:"; cat $out/raztest.out; fail=$((fail + 1))
    fi
    # and again with the debug heap, RAZ_HEAP=debug: guards after blocks,
    # freed blocks filled and quarantined
    RAZ_HEAP=debug RAZ=$raz $out/raztest -j $(nproc 2>/dev/null || echo 1) -o $out/libdebug \
        $(for f in lib/*.raz; do [ $f != lib/Sys.raz ] && grep -q '^proc main\*' $f && echo $f; done) \
        > $out/raztest-debug.out 2>&1
    set -- $(tail -1 $out/raztest-debug.out)
    if [ "$2" = passed, ] && [ "$6" = timed ]; then
        pass=$((pass + $1)); fail=$((fail + $3 + $5))
        [ $(($3 + $5)) = 0 ] || { echo "RAZ_HEAP=debug:"; grep -v '^ok ' $out/raztest-debug.out; }
    else
        echo "FAIL tools/Test.raz, RAZ_HEAP=debug:"; cat $out/raztest-debug.out; fail=$((fail + 1))
    fi
else
    echo "FAIL tools/Test.raz: $(cat $out/raztest.cerr)"; fail=$((fail + 1))
fi

# raztest's own three reports, over the fixtures in test/raztest (a pass,
# a failed check, a build that fails, a test that outlasts -t 1): plain,
# --tap and --junit, each against its .expect, every time in them
# written T
rtreport() {   # name, then raztest's arguments after the common ones
    name=$1; shift
    RAZ=$raz $out/raztest -t 1 -o $out/rt "$@" test/raztest 2>&1 </dev/null |
        sed -e 's/[0-9][0-9]*\.[0-9][0-9]s/Ts/' -e 's/time="[0-9.]*"/time="T"/' > $out/rt.$name
    if cmp -s $out/rt.$name test/raztest/$name.expect; then pass=$((pass + 1))
    else
        echo "FAIL raztest $name:"; diff test/raztest/$name.expect $out/rt.$name
        fail=$((fail + 1))
    fi
}
if [ -x $out/raztest ]; then
    rtreport plain
    rtreport tap --tap
    RAZ=$raz $out/raztest -t 1 -o $out/rt --junit $out/rt.xml test/raztest >/dev/null 2>&1
    sed -e 's/time="[0-9.]*"/time="T"/' $out/rt.xml > $out/rt.junit
    if cmp -s $out/rt.junit test/raztest/junit.expect; then pass=$((pass + 1))
    else
        echo "FAIL raztest junit:"; diff test/raztest/junit.expect $out/rt.junit
        fail=$((fail + 1))
    fi
fi

# raztest -w: a passing test, then edited to fail, is run again by the
# watch, which ^C ends with status 130; each wait is bounded to 10 s
waitfor() {   # file, text: whether text shows in file within 10 s
    for _ in $(seq 100); do
        grep -q "$2" $1 && return 0
        sleep 0.1
    done
    return 1
}
if [ -x $out/raztest ]; then
    wd=$out/rtw; rm -rf $wd; mkdir -p $wd/t
    cp test/raztest/Pass.raz $wd/t/
    RAZ=$raz $out/raztest -w -o $wd/o $wd/t > $wd/log 2>&1 </dev/null &
    wpid=$!
    if waitfor $wd/log '1 passed'; then
        printf 'module Pass;\nimport Rt;\nproc main*;\nbegin\n    Rt.exit(1);\nend;\nend Pass.\n' > $wd/t/Pass.raz
        waitfor $wd/log '0 passed, 1 failed'; ok=$?
    else ok=1; fi
    kill -INT $wpid 2>/dev/null; wait $wpid; st=$?
    if [ $ok = 0 ] && [ $st = 130 ]; then pass=$((pass + 1))
    else
        echo "FAIL raztest -w (status $st):"; cat $wd/log
        fail=$((fail + 1))
    fi
fi

# CAbi is tools/cabi.c's output, from the C library's own headers:
# compiled with cc, and with musl-gcc, each where it is installed, it
# writes lib/'s file again
for cc in cc musl-gcc; do
    command -v $cc >/dev/null || continue
    if ! $cc -o $out/cabi tools/cabi.c 2>$out/cabi.cerr; then
        echo "FAIL tools/cabi.c with $cc: $(cat $out/cabi.cerr)"; fail=$((fail + 1))
    elif ! $out/cabi linux-x86_64 | cmp -s - lib/CAbi.linux-x86_64.raz; then
        echo "FAIL tools/cabi.c with $cc: lib/CAbi.linux-x86_64.raz differs"; fail=$((fail + 1))
    else pass=$((pass + 1)); fi
done

# Thread's test again, with too little memory for all its threads:
# spawn must fail, with Thread.Failed
if (ulimit -v 60000; $out/lib/Thread.linux-x86_64 fail) > /dev/null 2>&1; then pass=$((pass + 1))
else echo "FAIL Thread under a memory limit"; fail=$((fail + 1)); fi

# the compiler's way of going on after an error, in small: a parser
# that reads names, fails on each bad one, and goes on to the next
if $raz -Werror -I src -o $out/recover src/test/Recover.raz 2>$out/recover.cerr; then
    printf 'a bad b bad bad c\nd bad\n' >$out/rec.raz
    r=$($out/recover $out/rec.raz 2>/dev/null) || true
    if [ "$r" = "8 names, 4 failed, 4 errors" ]; then pass=$((pass + 1))
    else echo "FAIL src/test/Recover.raz: $r"; fail=$((fail + 1)); fi
else
    echo "FAIL src/test/Recover.raz: $(cat $out/recover.cerr)"; fail=$((fail + 1))
fi

# a module imported and never called leaves nothing of its own in the
# program, not even Width's tables: the same program, importing it or
# not, makes a file of the same size (the names the trace shows may
# come in another order). Width's own imports, Str and through it Heap,
# run their bodies, as every module does, so both import Str
mkdir -p $out/shake
printf 'module Shake;\nimport Out, Str, Width;\nproc main*;\nbegin\n    Out.int(1); Out.ln;\nend;\nend Shake.\n' >$out/shake/Shake.raz
$raz -o $out/shake/with $out/shake/Shake.raz 2>/dev/null
printf 'module Shake;\nimport Out, Str;\nproc main*;\nbegin\n    Out.int(1); Out.ln;\nend;\nend Shake.\n' >$out/shake/Shake.raz
$raz -o $out/shake/without $out/shake/Shake.raz 2>/dev/null
if [ $(wc -c <$out/shake/with) = $(wc -c <$out/shake/without) ]; then pass=$((pass + 1))
else echo "FAIL an unused import, Width, changes the program"; fail=$((fail + 1)); fi

# the editors' support, headless, where the editors are installed
if test/editors.sh; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

# Installed source libraries: default, explicit and isolated lookup.
if test/library-path.sh "$raz"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

# The compiler built with another host (test/host/Host.raz).
if test/compiler-host.sh "$raz"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

echo "$pass passed, $fail failed"
[ $fail = 0 ]
