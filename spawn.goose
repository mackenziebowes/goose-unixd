// spawn: start a program, give it a time budget, kill its whole process group when the budget runs out.
// Linux x86_64. Libc externs only. Goose pinned at e0b1225.
//
// start() returns at once, so a poll loop that serves other things keeps serving: poll the child's
// out_fd for readability, and when it closes (read gives 0) call reap(). For a program that has nothing
// else to do, wait_child() does that loop for you, on poll, and enforces the budget.
namespace spawn;

import std;
import os;

struct PollFd { fd: i32, events: i16, revents: i16 }   // struct pollfd

extern "c" {
    fn poll(fds: PollFd&, n: u64, timeout_ms: i32) -> i32;
    fn read(fd: i32, buf: u8&, n: u64) -> i64;
    fn write(fd: i32, buf: const u8&, n: u64) -> i64;
    fn close(fd: i32) -> i32;
    fn pipe2(fds: i32&, flags: i32) -> i32;
    fn fork() -> i32;
    fn dup2(a: i32, b: i32) -> i32;
    fn execvp(file: const u8&, argv: u64&) -> i32;
    fn strdup(s: const u8&) -> u64;
    fn free(p: u64);
    fn waitpid(pid: i32, status: i32&, options: i32) -> i32;
    fn putenv(entry: const u8&) -> i32;
    fn kill(pid: i32, sig: i32) -> i32;
    fn setpgid(pid: i32, pgid: i32) -> i32;
    fn sigprocmask(how: i32, set: u64&, old: u64) -> i32;
    fn _exit(code: i32);
}

let ARGV_MAX = 60;      // arguments after the `timeout -s KILL <secs>` prefix

// pid is -1 when the child could not start. out_fd is the read end of its stdout (close-on-exec, so no
// later child inherits it); close it when you are done with the child.
struct Child { pid: i32, out_fd: i32 }

// Starts argv[0] with the rest as its arguments, and returns without waiting.
//   argv         NUL-terminated strings, back to back: "sleep\0" "5\0". At most 60 of them.
//   env          NUL-terminated NAME=value strings added to the child's environment; "" adds none.
//   stdin        bytes written to the child's stdin, which is then closed; "" gives it an empty stdin.
//                At most 60000 bytes (a pipe holds 64 KB and start writes before it returns); more gives pid -1.
//   close_fds    descriptors of yours the child must not keep (a listening socket, for one).
//   backstop_ms  0 for none. Above 0, the program runs under `timeout -s KILL <secs>` with secs =
//                backstop_ms / 1000 + 2, a kill that works even if this process is SIGKILLed. Give it the
//                budget you will enforce yourself: your own kill_group at the budget then comes first.
// The child is its own process group leader, so kill_group reaches the program's children too. The child
// starts with an empty signal mask, since a service that reads SIGTERM from a signalfd has blocked it.
fn start(argv: const u8[:], env: const u8[:], stdin: const u8[:], close_fds: const i32[:], backstop_ms: i64) -> Child {
    // stdin is written with one blocking write before start returns. A pipe holds 64 KB on Linux, so more than that
    // could block here for good if the child never reads, and no budget would apply. Refuse it instead.
    if stdin.len > 60000 { return Child { pid: -1, out_fd: -1 }; }
    var inp: i32[2] = [0; 2];
    var outp: i32[2] = [0; 2];
    if pipe2(inp[0], 524288) != 0 { return Child { pid: -1, out_fd: -1 }; }
    if pipe2(outp[0], 524288) != 0 { close(inp[0]); close(inp[1]); return Child { pid: -1, out_fd: -1 }; }
    var av: u64[66] = [0; 66];
    var n = 0;
    if backstop_ms > 0 {
        av[0] = strdup("timeout\0"[0]);
        av[1] = strdup("-s\0"[0]);
        av[2] = strdup("KILL\0"[0]);
        let secs = str(backstop_ms / 1000 + 2, "\0");
        av[3] = strdup(secs[0]);
        n = 4;
    }
    var at = 0;
    var given = 0;
    while at < argv.len && given < ARGV_MAX {
        av[n] = strdup(argv[at]);
        n += 1;
        given += 1;
        while at < argv.len && argv[at] != 0 { at += 1; }
        at += 1;
    }
    if given == 0 {
        for k in n { free(av[k]); }
        close(inp[0]); close(inp[1]); close(outp[0]); close(outp[1]);
        return Child { pid: -1, out_fd: -1 };
    }
    let pid = fork();
    if pid == 0 {
        setpgid(0, 0);
        dup2(inp[0], 0);
        dup2(outp[1], 1);
        for f in close_fds { close(f); }
        var e = 0;
        while e < env.len {
            putenv(env[e]);
            while e < env.len && env[e] != 0 { e += 1; }
            e += 1;
        }
        var none: u64[16] = [0; 16];
        sigprocmask(2, none[0], 0);   // SIG_SETMASK to empty
        if backstop_ms > 0 { execvp("timeout\0"[0], av[0]); }
        else { execvp(argv[0], av[0]); }
        _exit(127);
    }
    if pid > 0 { setpgid(pid, pid); }   // in the parent too: kill(-pid) must not miss a child that has not run its own setpgid yet
    for k in n { free(av[k]); }
    close(inp[0]);
    close(outp[1]);
    if pid < 0 { close(inp[1]); close(outp[0]); return Child { pid: -1, out_fd: -1 }; }
    if stdin.len > 0 { write(inp[1], stdin[0], stdin.len as u64); }
    close(inp[1]);
    return Child { pid: pid, out_fd: outp[0] };
}

// SIGKILL to the child's whole process group, and to the child itself in case its group is not set yet.
fn kill_group(child: Child) {
    if child.pid > 0 { kill(0 - child.pid, 9); kill(child.pid, 9); }
}

fn exit_code(st: i32) -> i64 {
    if (st & 127) != 0 { return 128 + (st & 127); }   // killed by signal n: 128 + n, as a shell reports it
    return (st >> 8) & 255;
}

// Without waiting: has the child ended? Returns done, exit code. A child that closed its stdout but runs on
// gives done = false, so never use a blocking wait on one.
fn reap_now(child: Child) -> bool, i64 {
    var st: i32 = 0;
    if waitpid(child.pid, st, 1) == child.pid { return true, exit_code(st); }
    return false, 0;
}

// Waits for the child to end and returns its exit code. Only after kill_group, or when the child is known to
// be finishing: it blocks.
fn reap(child: Child) -> i64 {
    var st: i32 = 0;
    waitpid(child.pid, st, 0);
    return exit_code(st);
}

// The standalone loop: reads the child's stdout into `out` until it closes, on poll, for at most budget_ms.
// When the budget is up, kills the process group, reaps it, and returns 137, true. Otherwise returns the
// exit code, false. Closes child.out_fd either way.
fn wait_child(child: Child, budget_ms: i64, out: u8[>..]&) -> i64, bool {
    if child.pid < 0 { return -1, false; }
    let t0 = time_ns() / 1000000;
    var buf: u8[4096] = [0; 4096];
    var open = true;
    while open {
        let left = budget_ms - (time_ns() / 1000000 - t0);
        if left <= 0 {
            close(child.out_fd);
            kill_group(child);
            reap(child);
            return 137, true;
        }
        var p: PollFd[1] = [PollFd { fd: child.out_fd, events: 1, revents: 0 }; 1];
        let r = poll(p[0], 1, left as i32);
        if r > 0 {
            let got = read(child.out_fd, buf[0], 4096);
            if got <= 0 { open = false; }
            else { for i in got { out.push(buf[i]); } }
        }
    }
    close(child.out_fd);
    // stdout closed, but the program may run on: keep the budget for the exit too.
    while true {
        let done, code = reap_now(child);
        if done { return code, false; }
        if time_ns() / 1000000 - t0 >= budget_ms {
            kill_group(child);
            reap(child);
            return 137, true;
        }
        var nap: PollFd[1] = [PollFd { fd: -1, events: 0, revents: 0 }; 1];
        poll(nap[0], 1, 5);   // a poll on no descriptor is a 5 ms sleep
    }
    return -1, false;
}
