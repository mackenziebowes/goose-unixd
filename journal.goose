// journal: appends and whole-file replacements that survive a power cut.
// Linux. Libc externs only (stdio and fsync; nothing variadic). Goose pinned at e0b1225.
namespace journal;

import std;
import os;

extern "c" {
    fn fopen(path: const u8&, mode: const u8&) -> u64;
    fn fwrite(buf: const u8&, size: u64, n: u64, f: u64) -> u64;
    fn fflush(f: u64) -> i32;
    fn fileno(f: u64) -> i32;
    fn fsync(fd: i32) -> i32;
    fn fclose(f: u64) -> i32;
    fn rename(from: const u8&, to: const u8&) -> i32;
}

// Adds `line` to the end of the file at `path` (created if missing). The caller puts the '\n' in `line`.
// With sync = true, the bytes are on disk when this returns true (fsync). A NEW file's directory entry is
// not synced here: create the file once with write_atomic, or call sync_dir on its folder, if a crash
// must not lose the file itself. Returns false when it could not open, write or sync.
fn append_line(path: const u8[:], line: const u8[:], sync: bool) -> bool {
    let p = str(path, "\0");
    let m = "a\0";
    let f = fopen(p[0], m[0]);
    if f == 0 { return false; }
    let wrote = fwrite(line[0], 1, line.len as u64, f);
    fflush(f);
    var ok = wrote == line.len as u64;
    if sync { if fsync(fileno(f)) != 0 { ok = false; } }
    fclose(f);
    return ok;
}

// fsync of a folder, so a rename or a new file inside it is itself durable. glibc's fopen opens a folder
// for reading without complaint, and fsync works on that descriptor.
fn sync_dir(dir: const u8[:]) -> bool {
    let d = str(dir, "\0");
    let m = "r\0";
    let f = fopen(d[0], m[0]);
    if f == 0 { return false; }
    let ok = fsync(fileno(f)) == 0;
    fclose(f);
    return ok;
}

// The folder part of a path: everything before the last '/', "." when there is none, "/" for "/x".
fn dir_of(path: const u8[:]) -> u8[>..] {
    var j = path.len - 1;
    while j >= 0 && path[j] != '/' { j -= 1; }
    if j < 0 { return str("."); }
    if j == 0 { return str("/"); }
    return str(path[0..j]);
}

// Replaces the file at `path` with `text` in one step: a reader sees the old file or the new one, never
// half. Writes <path>.tmp, fsyncs it, renames it over `path`, then fsyncs the folder. Without that last
// step the rename can be lost in a power cut and the old file comes back. Returns false at the first
// step that fails; the old file is untouched until the rename.
fn write_atomic(path: const u8[:], text: const u8[:]) -> bool {
    let tmp = str(path, ".tmp\0");
    let m = "w\0";
    let f = fopen(tmp[0], m[0]);
    if f == 0 { return false; }
    let wrote = fwrite(text[0], 1, text.len as u64, f);
    fflush(f);
    var ok = wrote == text.len as u64;
    if fsync(fileno(f)) != 0 { ok = false; }
    fclose(f);
    if !ok { return false; }
    let dst = str(path, "\0");
    if rename(tmp[0], dst[0]) != 0 { return false; }
    return sync_dir(dir_of(path));
}
