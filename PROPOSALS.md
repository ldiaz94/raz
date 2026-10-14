# raz: proposals

What the language or the library might have, met while writing raz.
None is built while the freeze holds; each waits for a later thaw, by
the owner's word, and goes into the report before any code.

## A `const` parameter

`proc what(const x: Item): []U8;`: the callee may not change `x` (nor
take its address), so the caller may pass the address of a record or
array without a copy, and the program means the same.

Met in porting the compiler to raz, where the seed's `const x: TItem`
(about 130 bytes) became a value parameter, copied at every call.
Measured once the port built: not what stands out, the compiler's
profile is flat (`Scan.tokPos` is 9%).

## A UDP socket that serves

`proc listenUdp*(addr: []U8; port: INT): INT;`, a socket of datagrams
bound to `port` at `addr`, with `receive*(fd: INT; buf: []U8): (INT,
Peer)` and `reply*(fd: INT; to: Peer; s: []U8): INT` to answer whoever
sent each one. `connectUdp` talks to one server; nothing lets a program
be one.

Met in rnet, whose `Dns` test serves a name server on the loopback:
`test/Nameserver.raz` binds and answers with `SYSCALL`s of its own,
which tie it to Linux.

## A socket's own port

`proc localPort*(fd: INT): INT;` (getsockname), so that a program can
listen on port 0, take the port the system chose, and tell it to its
client. Without it, a test picks a port and tries again while one is
taken.

Met in rnet's tests, which pick ports from the process id and retry.

## Connecting with a timeout

`proc connectTcpWithin*(addr: []U8; port, ms: INT): INT;`: a
connection that fails with -110 (ETIMEDOUT) after `ms` milliseconds,
by a non-blocking connect and a wait for the socket to be writable.
`connectTcp` waits as long as the kernel does, minutes for a host that
drops the connection's first packet.

Met in rnet: `Conn.dial`, and `Dns` over TCP to a name server that has
gone, can hold a program up that long.

## Thread in a program with C

`Thread` says `link static`, so a program with C can't have it, and
makes its threads with `C.pthread_create`, whose start procedure has
another signature. A library that starts threads, and may be used by
programs with C and without, can't name either: `Thread` could have a
second file, over `pthread_create` and `pthread_join`, chosen when the
program uses C, with the same `spawn` and `join`.

Met in rnet: `Http`'s server is used with `Tls`, which is C, and
without; it takes a `spawn` procedure from the program instead.
