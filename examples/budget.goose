// Runs `sleep 5` with a 1 second budget. The budget runs out, so the whole process group is killed.
// Build and run: goose build examples/budget.goose && ./examples/budget
import unixd from "../";

import unixd;
import unixd.spawn;
import os;

fn main() {
    let t0 = unixd::now_ms();
    let child = spawn::start(str("sleep\0", "5\0"), "", "", [], 1000);
    var out: u8[>..] = [];
    let code, timed_out = spawn::wait_child(child, 1000, out);
    let took = unixd::now_ms() - t0;
    write_stdout(str("exit code ", code, ", timed out ", timed_out, ", after ", took, " ms\n"));
}
