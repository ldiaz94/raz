#!/bin/sh
# The time in nanoseconds, for the timing scripts: date +%s%N is GNU's;
# BSD's date prints a literal N there, and perl, which macOS has, then
# gives the time.
n=$(date +%s%N)
case $n in
*N) perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1e9' ;;
*) echo "$n" ;;
esac
