# goose-unixd

Four things a small Unix service needs, and Goose's standard library does not have: a socket to listen on, systemd socket activation, a way to catch SIGTERM, and a child process with a time budget that is killed with its whole process group when the budget runs out. Plus a journal: appends and file replacements that survive a power cut.

Linux x86_64 only. Libc `extern "c"` calls only, no C shim, no C compiler needed to run. Written against Goose at commit `e0b1225` (pre-1.0; later commits may change the language). MIT licence.

It was extracted from a small service host we run (a poll loop on one Unix socket, started by systemd, which starts a child per event). There is no test suite: each piece was shown working once, by hand, and the commands are in section 4.

## 1. Use it

In your program's root file, declare the package by git URL (a ref after `@` is required; only the root file declares packages), and give your program a sidecar that maps libc:

```goose
import unixd from "mackenziebowes/goose-unixd@v0.1.0";

import unixd;
import unixd.spawn;
import unixd.journal;
```

```
// myprog.build, beside myprog.goose
dylibs_linux = ["c=libc.so.6"];
```

If your program has its own `extern "c"` block, add that line to its sidecar. The package ships the same line, so a program that only calls the package functions needs none.

## 2. What is in it

Each module has its own namespace: `unixd::`, `spawn::`, `journal::`.

### 2.1 unixd.goose

1. `unix_listen(path) -> fd`: binds and listens on a Unix stream socket (non-blocking, close-on-exec). Removes an old socket file first. Returns -1 if the path is 107 bytes or more, or the folder is missing or not yours.
2. `listen_fds() -> fd`: the socket systemd passed in. Returns 3 when `LISTEN_FDS` is 1 and `LISTEN_PID` is this process, otherwise -1.
3. `sigterm_fd() -> fd`: SIGTERM and SIGINT as readable records on a descriptor (signalfd). Goose cannot install a signal handler, so this is how a service learns it should drain. It blocks both signals for the process.
4. `now_ms() -> i64`.

### 2.2 spawn.goose

1. `start(argv, env, stdin, close_fds, backstop_ms) -> Child`: starts a program and returns at once, so your poll loop keeps serving. `argv` and `env` are NUL-terminated strings back to back (`str("sleep\0", "5\0")`). The child leads its own process group and starts with an empty signal mask. Keep `stdin` under 60000 bytes: it is written with one blocking write before `start` returns, a pipe holds 64 KB, and a child that never reads a larger input would block `start` for good with no budget applied. `start` refuses more than that and returns a child with `pid` -1.
2. `kill_group(child)`: SIGKILL to the whole group.
3. `reap_now(child) -> done, code` and `reap(child) -> code`. A child killed by signal n gives `128 + n`, as a shell reports it.
4. `wait_child(child, budget_ms, out) -> code, timed_out`: for a program with nothing else to do. Reads the child's stdout into `out` on `poll`, and when the budget is up kills the group and returns `137, true`.

The backstop: with `backstop_ms > 0` the program runs under `timeout -s KILL <backstop_ms/1000 + 2>`. Your own `kill_group` at the budget comes first. The backstop is there for the one case it covers: if your service is itself SIGKILLed, the children's group stays alive until `timeout` fires.

### 2.3 journal.goose

1. `append_line(path, line, sync) -> ok`: append, with fsync when `sync` is true.
2. `write_atomic(path, text) -> ok`: writes `<path>.tmp`, fsyncs it, renames it over `path`, then fsyncs the folder. Without the folder fsync a power cut can bring the old file back.
3. `sync_dir(dir) -> ok` and `dir_of(path)`.

## 3. Examples

1. `examples/budget.goose`: runs `sleep 5` with a 1 second budget; the group is killed.
2. `examples/echo.goose` with `echo.socket` and `echo.service`: a socket-activated echo service that leaves on SIGTERM.

Build one from a fresh clone: `goose build examples/budget.goose && ./examples/budget`.

## 4. What was shown, and how

All by hand, once, on one Linux machine:

1. `budget`: `exit code 137, timed out true, after 1002 ms`.
2. A grandchild (`sh -c 'sleep 31 & wait'`) under a 500 ms budget: the group was killed and `pgrep -fx "sleep 31"` found nothing.
3. stdin and env reach the child (`in=hello env=hi`), its exit code 3 comes back, and a child that kills itself with SIGTERM gives 143.
4. `echo` under `systemd-socket-activate -l <path> examples/echo`: it printed `systemd gave us the socket`, echoed `hello unixd`, and on `kill -TERM` printed `SIGTERM, leaving` and exited.
5. `append_line` and `write_atomic` return true on a scratch folder. Nobody has cut the power, so the durability claim rests on how fsync works, not on a test.

6. Stdin of 70000 bytes: `start` returned pid -1 and did not block. Stdin of 1000 bytes through `cat`: exit 0, 1000 bytes back.

Not shown: the `.socket` and `.service` units under a real `systemctl --user`, more than one passed socket (unsupported: `listen_fds` returns -1), and any non-Linux or non-x86_64 machine.
