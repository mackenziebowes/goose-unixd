// goose-unixd: what a small Unix service needs and Goose's standard library lacks.
// Linux x86_64 only. Libc externs only, no C shim. Goose pinned at e0b1225 (pre-1.0).
//
//   unix_listen(path)  a Unix stream socket, bound and listening, non-blocking
//   listen_fds()       the socket systemd passed in (socket activation), or -1
//   sigterm_fd()       SIGTERM and SIGINT as bytes on a descriptor (signalfd), or -1
//   now_ms()           a clock in milliseconds
namespace unixd;

import std;
import os;

struct Sun { family: u16, path: u8[108] }              // struct sockaddr_un

extern "c" {
    fn socket(domain: i32, kind: i32, proto: i32) -> i32;
    fn bind(fd: i32, addr: Sun&, len: u32) -> i32;
    fn listen(fd: i32, backlog: i32) -> i32;
    fn close(fd: i32) -> i32;
    fn unlink(path: const u8&) -> i32;
    fn getpid() -> i32;
    fn sigprocmask(how: i32, set: u64&, old: u64) -> i32;
    fn signalfd(fd: i32, mask: u64&, flags: i32) -> i32;
}

// Milliseconds on the monotonic clock std gives (time_ns).
fn now_ms() -> i64 { time_ns() / 1000000 }

// Binds a Unix stream socket at `path` and listens (backlog 64). An old socket file at `path` is removed first.
// The descriptor is non-blocking and close-on-exec (SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC).
// Returns -1 when it cannot: the path is 107 bytes or longer, the folder does not exist, or it is not yours.
fn unix_listen(path: const u8[:]) -> i32 {
    if path.len >= 107 { return -1; }
    let zp = str(path, "\0");
    unlink(zp[0]);
    var a = Sun { family: 1, path: [0; 108] };
    for i in path.len { a.path[i] = path[i]; }
    let fd = socket(1, 1 | 2048 | 524288, 0);
    if fd < 0 { return -1; }
    if bind(fd, a, 110) != 0 || listen(fd, 64) != 0 { close(fd); return -1; }
    return fd;
}

// systemd socket activation: when LISTEN_FDS is 1 and LISTEN_PID is this process, the socket is descriptor 3.
// Returns 3 then, and -1 otherwise (started by hand, or LISTEN_PID names another process: a forked child
// must not take its parent's socket). Only one passed socket is supported; with more, it returns -1.
fn listen_fds() -> i32 {
    var lf: u8[>..] = [];
    var lp: u8[>..] = [];
    if env("LISTEN_FDS", lf) && env("LISTEN_PID", lp) && lf == "1" && lp == str(getpid()) { return 3; }
    return -1;
}

// SIGTERM and SIGINT arrive as 128-byte records on the returned descriptor, since Goose cannot install a handler.
// Blocks both signals for this process, so call it before you start children that should keep the default
// (spawn.start clears the mask in the child). Returns -1 when signalfd fails.
fn sigterm_fd() -> i32 {
    var mask: u64[16] = [0; 16];
    mask[0] = 2 | 16384;                   // bit for SIGINT (2) and SIGTERM (15)
    sigprocmask(0, mask[0], 0);            // SIG_BLOCK
    return signalfd(-1, mask[0], 2048 | 524288);
}
