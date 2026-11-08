// A socket-activated echo service. Each connection's bytes are sent back, then the connection is closed.
// systemd opens the socket (echo.socket) and starts this program on the first connection; run by hand,
// it makes its own socket. SIGTERM or SIGINT ends it after the connection in hand.
// Build: goose build examples/echo.goose
import unixd from "../";

import unixd;
import os;

struct PollFd { fd: i32, events: i16, revents: i16 }

extern "c" {
    fn poll(fds: PollFd&, n: u64, timeout_ms: i32) -> i32;
    fn accept4(fd: i32, addr: u64, len: u64, flags: i32) -> i32;
    fn read(fd: i32, buf: u8&, n: u64) -> i64;
    fn write(fd: i32, buf: const u8&, n: u64) -> i64;
    fn close(fd: i32) -> i32;
}

fn main() {
    var lfd = unixd::listen_fds();
    var how = "systemd gave us the socket";
    if lfd < 0 {
        lfd = unixd::unix_listen("/tmp/goose-unixd-echo.sock");
        how = "we made /tmp/goose-unixd-echo.sock";
    }
    if lfd < 0 { write_stderr("echo: cannot listen\n"); return; }
    let sfd = unixd::sigterm_fd();
    write_stderr(str("echo: ", how, "\n"));
    var buf: u8[4096] = [0; 4096];
    while true {
        var fds: PollFd[2] = [PollFd { fd: lfd, events: 1, revents: 0 }, PollFd { fd: sfd, events: 1, revents: 0 }];
        poll(fds[0], 2, -1);
        if fds[1].revents != 0 { write_stderr("echo: SIGTERM, leaving\n"); break; }
        if fds[0].revents != 0 {
            let c = accept4(lfd, 0, 0, 524288);
            if c >= 0 {
                let n = read(c, buf[0], 4096);
                if n > 0 { write(c, buf[0], n as u64); }
                close(c);
            }
        }
    }
}
