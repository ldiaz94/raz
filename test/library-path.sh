#!/bin/sh
# Exercises the compiler's library lookup in an isolated environment:
# the default library in $HOME/.raz/lib, RAZ_PATH, -I, the files a module
# has for other targets, and modules of one name found twice.
# Usage: test/library-path.sh path/to/raz
# Each case runs in a subshell with its own scratch directory and HOME.

raz=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
top=$(mktemp -d "${TMPDIR:-/tmp}/raz-path-XXXXXX") || exit 1
trap 'rm -rf "$top"' EXIT
pass=0
fail=0

# Sets up a fresh scratch directory $root, with HOME in it (its name has a
# space), the default library directory $default and the main program.
setup() {
    root=$top/$1
    mkdir -p "$root/src" "$root/home space"
    unset RAZ_PATH RAZ_PROFILE RUN
    HOME="$root/home space"
    export HOME
    default=$HOME/.raz/lib
    main=$root/src/Main.raz
    cat >"$main" <<'END'
module Main;
import Out, PathLib;
proc main*;
begin Out.int(PathLib.value); Out.ln; end;
end Main.
END
}

# library DIR [VALUE [SUFFIX]] writes DIR/PathLib<SUFFIX>.raz.
library() {
    mkdir -p "$1"
    echo "module PathLib; const value* = ${2:-42}; end PathLib." >"$1/PathLib$3.raz"
}

# compile FLAGS... builds the program, its messages in $root/err. With
# RUN set it runs it by "raz run" instead, its output in $root/out.
compile() {
    if [ -n "$RUN" ]; then
        (cd "$root" && "$raz" run -Werror "$@" "$main") >"$root/out" 2>"$root/err"
    else
        (cd "$root" && "$raz" -o "$root/app" -Werror "$@" "$main") >"$root/out" 2>"$root/err"
    fi
}

# succeeds FLAGS...: it compiles, and the program prints 42.
succeeds() {
    compile "$@" || { echo "compile failed:"; cat "$root/err"; return 1; }
    [ -n "$RUN" ] || "$root/app" >"$root/out" || return 1
    [ "$(cat "$root/out")" = 42 ] || { echo "printed: $(cat "$root/out")"; return 1; }
}

# fails MESSAGE FLAGS...: compiling gives status 1 and MESSAGE in its errors.
fails() {
    msg=$1
    shift
    compile "$@"
    [ $? = 1 ] || { echo "expected status 1"; cat "$root/err"; return 1; }
    grep -F -q -- "$msg" "$root/err" || { echo "no '$msg' in:"; cat "$root/err"; return 1; }
}

# runcase NAME runs the function NAME in a subshell and counts it.
runcase() {
    if (setup "$1"; "$1"); then pass=$((pass + 1))
    else echo "FAIL library-path: $1"; fail=$((fail + 1)); fi
}

t_default() {
    library "$default"
    succeeds || return 1
    RUN=1 succeeds
}

t_colon_in_home() {   # unlike RAZ_PATH, HOME is one path, not a list
    HOME="$root/home : space"
    export HOME
    library "$HOME/.raz/lib"
    succeeds
}

t_empty_disables_default() {
    library "$default"
    RAZ_PATH=; export RAZ_PATH
    fails "can't find module PathLib" || return 1
    succeeds -I "$default"   # explicit directories still work
}

t_list_replaces_default() {
    library "$default" 99
    library "$root/second directory"
    RAZ_PATH="$root/first directory:$root/second directory"; export RAZ_PATH
    succeeds || return 1
    RUN=1 succeeds || return 1
    RAZ_PATH="$root/first directory"
    fails "can't find module PathLib"
}

t_relative_and_empty_entries() {
    library "$root/relative"
    library "$root" 99   # a module in the cwd must not be found by an empty entry
    RAZ_PATH=:relative::missing:; export RAZ_PATH
    succeeds || return 1
    RAZ_PATH=:::
    fails "can't find module PathLib"
}

t_missing_home() {
    unset HOME
    fails "can't find module PathLib" || return 1
    HOME=; export HOME
    fails "can't find module PathLib" || return 1
    library "$root/explicit"
    RAZ_PATH=explicit; export RAZ_PATH
    succeeds
}

t_no_recursion() {
    library "$default/package"
    fails "can't find module PathLib" || return 1
    RAZ_PATH=$default/package; export RAZ_PATH
    succeeds
}

t_missing_module_lists_all_search_directories() {
    RAZ_PATH=first:second; export RAZ_PATH
    compile -I explicit
    [ $? = 1 ] || return 1
    grep -F -q "explicit, first, second," "$root/err" || { cat "$root/err"; return 1; }
    grep -F -q "$(dirname "$raz")/lib" "$root/err" || { cat "$root/err"; return 1; }
}

t_no_path_expansion() {
    library "$default"
    for p in '~/.raz/lib' '$HOME/.raz/lib'; do
        RAZ_PATH=$p; export RAZ_PATH
        fails "can't find module PathLib" || return 1
    done
}

t_target_file_and_interface() {
    library "$default" 42 .linux-x86_64
    library "$default" 99
    succeeds || return 1
    echo "module PathLib; const other* = 42; end PathLib." >"$default/PathLib.raz"
    fails "isn't exported"
}

t_duplicate_main_and_include() {
    library "$default"
    for dir in "$root/src" "$root/include"; do
        library "$dir"
        flags=
        [ "$dir" = "$root/src" ] || flags="-I $dir"
        fails "module PathLib is in" $flags || return 1
        rm "$dir/PathLib.raz"
        ln -s "$default/PathLib.raz" "$dir/PathLib.raz"   # a link to the chosen file is no duplicate
        succeeds $flags || return 1
        rm "$dir/PathLib.raz"
    done
}

t_duplicate_user_directories() {
    library "$default"
    library "$root/other"
    RAZ_PATH=$default:$root/other; export RAZ_PATH
    fails "module PathLib is in" || return 1
    RAZ_PATH=$default:$default
    succeeds
}

t_duplicate_standard_library() {
    library "$default"
    echo "module Out; end Out." >"$default/Out.raz"
    fails "module Out is in"
}

t_user_paths_do_not_consume_include_slots() {
    library "$default"
    flags=
    p=
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do flags="$flags -I missing"; done
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
        p=${p}missing:
    done
    succeeds $flags || return 1
    RAZ_PATH=$p$default; export RAZ_PATH
    succeeds $flags
}

# Module identity is the file's device and inode: a hard link to the
# chosen file is the same file.
t_hard_link_chooses_same_module() {
    library "$default"
    ln "$default/PathLib.raz" "$root/src/PathLib.raz"
    succeeds
}

# ... and equal contents in another file are not.
t_equal_contents_do_not_choose_distinct_module() {
    library "$default"
    cp "$default/PathLib.raz" "$root/src/PathLib.raz"
    fails "module PathLib is in"
}

# ... and a link to some other file is not the chosen one.
t_symbolic_link_to_distinct_module_does_not_choose() {
    library "$default"
    library "$root/elsewhere"
    ln -s "$root/elsewhere/PathLib.raz" "$root/src/PathLib.raz"
    fails "module PathLib is in"
}

for t in t_default t_colon_in_home t_empty_disables_default \
    t_list_replaces_default t_relative_and_empty_entries t_missing_home \
    t_no_recursion t_missing_module_lists_all_search_directories \
    t_no_path_expansion t_target_file_and_interface \
    t_duplicate_main_and_include t_duplicate_user_directories \
    t_duplicate_standard_library \
    t_user_paths_do_not_consume_include_slots \
    t_hard_link_chooses_same_module \
    t_equal_contents_do_not_choose_distinct_module \
    t_symbolic_link_to_distinct_module_does_not_choose; do
    runcase $t
done

echo "library-path: $pass passed, $fail failed"
[ $fail = 0 ]
