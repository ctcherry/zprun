const std = @import("std");

const DEBUG = false;
const MAX_ARGS = 100;
const DEFAULT_PROCFILE_NAME = "Procfile";

const Options = struct {
    selfName: []const u8,
    procfileName: []const u8,
    targetLabels: std.ArrayList([]const u8),
};

pub fn main() !u8 {
    const stderr = std.io.getStdErr().writer();

    var allocSpace: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocSpace);
    var alloc = fba.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var opts = Options{
        .selfName = args[0],
        .procfileName = try alloc.dupe(u8, DEFAULT_PROCFILE_NAME),
        .targetLabels = std.ArrayList([]const u8).init(alloc),
    };

    var optsErrs = try OptionErrors.initCapacity(alloc, 2);
    defer optsErrs.deinit();
    getOptions(alloc, args, &opts, &optsErrs) catch {
        for (optsErrs.items) |err| {
            defer alloc.free(optsErrs.items[0]);
            try stderr.print("{s}\n", .{err});
        }
        return 1;
    };

    var procfile = std.fs.cwd().openFile(opts.procfileName, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try stderr.print("Error: File '{s}' for procfile not found\n", .{opts.procfileName});
            },
            else => {
                try stderr.print("Error opening file '{s}' {s}\n", .{ opts.procfileName, @errorName(err) });
            },
        }
        return 1;
    };
    defer procfile.close();

    if (opts.targetLabels.items.len == 0) {
        try stderr.print("Usage: {s} [options] <label>\n\tlabel    Label of the command to run in Procfile\n\t-f path  Use file other than Procfile", .{opts.selfName});
        return 1;
    }

    var procfileBufReader_ = std.io.bufferedReader(procfile.reader());
    const procfileBufReader = procfileBufReader_.reader();

    const commands = getCmdsFromProcfile(alloc, procfileBufReader, opts.targetLabels.items) catch |err| {
        switch (err) {
            error.LabelNotFound => {
                try stderr.print("Error: Unable to find all labels in procfile '{s}'\n", .{opts.procfileName});
            },
            error.EmptyCmd => {
                try stderr.print("Error: Unable to find command for all labels in procfile '{s}'\n", .{opts.procfileName});
            },
            else => {
                try stderr.print("Error: Extracting command from procfile '{s}'\n", .{@errorName(err)});
            },
        }
        return 1;
    };

    var out_pipe_fds = std.ArrayList(std.posix.fd_t).initCapacity(alloc, commands.items.len) catch |err| {
        try stderr.print("Error initializing stdout pipes list '{s}'\n", .{@errorName(err)});
        return 1;
    };

    var err_pipe_fds = std.ArrayList(std.posix.fd_t).initCapacity(alloc, commands.items.len) catch |err| {
        try stderr.print("Error initializing stderr pipes list '{s}'\n", .{@errorName(err)});
        return 1;
    };

    var children = std.ArrayList(std.ChildProcess).initCapacity(alloc, commands.items.len) catch |err| {
        try stderr.print("Error initializing children list '{s}'\n", .{@errorName(err)});
        return 1;
    };

    for (commands.items) |command| {
        var cmd_args = try cmdToArgs(alloc, command);
        const cmd_args_owned = try cmd_args.toOwnedSlice();
        var child_proc = std.ChildProcess.init(cmd_args_owned, alloc);
        child_proc.stdout_behavior = .Pipe;
        child_proc.stderr_behavior = .Pipe;
        child_proc.stdin_behavior = .Ignore;

        child_proc.spawn() catch |err| {
            try stderr.print("Error spawning child process '{s}'\n", .{@errorName(err)});
            return 1;
        };

        children.appendAssumeCapacity(child_proc);

        if (child_proc.stdout) |f| {
            out_pipe_fds.appendAssumeCapacity(f.handle);
        }

        if (child_proc.stderr) |f| {
            err_pipe_fds.appendAssumeCapacity(f.handle);
        }
    }

    const epoller = std.posix.epoll_create1(0) catch |err| {
        try stderr.print("Error creating epoll '{s}'\n", .{@errorName(err)});
        return 1;
    };

    for (out_pipe_fds.items, 0..) |fd, i| {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN, // let us know when we can read from the pipe
            .data = std.os.linux.epoll_data{ .u64 = i + 1 },
        };
        std.posix.epoll_ctl(epoller, std.os.linux.EPOLL.CTL_ADD, fd, &event) catch |err| {
            try stderr.print("Error adding stdout pipe to epoll '{s}'\n", .{@errorName(err)});
            return 1;
        };
    }

    for (err_pipe_fds.items, 0..) |fd, i| {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN, // let us know when we can read from the pipe
            .data = std.os.linux.epoll_data{ .u64 = (i + 1) << 32 },
        };
        std.posix.epoll_ctl(epoller, std.os.linux.EPOLL.CTL_ADD, fd, &event) catch |err| {
            try stderr.print("Error adding stderr pipe to epoll '{s}'\n", .{@errorName(err)});
            return 1;
        };
    }

    var buffers = std.ArrayList(std.io.FixedBufferStream([]u8)).initCapacity(alloc, commands.items.len * 2) catch |err| {
        try stderr.print("Error initializing buffers list '{s}'\n", .{@errorName(err)});
        return 1;
    };
    // create all of the buffers
    for (0..commands.items.len * 2) |_| {
        const buf = std.io.fixedBufferStream(try alloc.alloc(u8, 4096));
        buffers.appendAssumeCapacity(buf);
    }

    var events = std.ArrayList(std.os.linux.epoll_event).initCapacity(alloc, commands.items.len * 2) catch |err| {
        try stderr.print("Error initializing epoll events list '{s}'\n", .{@errorName(err)});
        return 1;
    };

    for (0..commands.items.len * 2) |_| {
        const e: std.os.linux.epoll_event = undefined;
        events.appendAssumeCapacity(e);
    }

    var line_buffer = std.io.fixedBufferStream(try alloc.alloc(u8, 4096));
    var line_writer = line_buffer.writer();
    var closed_pipes: [64]u8 = undefined;
    @memset(&closed_pipes, 0);

    const orig_event_len = events.items.len;
    var current_event_len = orig_event_len;

    whileepoll: while (true) {
        events.resize(current_event_len) catch |err| {
            stderr.print("Error resizing events list '{s}'\n", .{@errorName(err)}) catch unreachable;
        };
        const event_count = std.posix.epoll_wait(epoller, events.items, 5000);

        if (event_count == 0) {
            continue :whileepoll;
        }

        events.resize(event_count) catch |err| {
            try stderr.print("Error resizing events list '{s}'\n", .{@errorName(err)});
            return 1;
        };

        forevents: for (events.items) |e| {
            var idx = e.data.u64;
            var out_type: u8 = 0;
            var buf: std.io.FixedBufferStream([]u8) = undefined;
            var fd: std.posix.fd_t = 0;
            if (idx >= std.math.maxInt(u32)) {
                // stderr
                idx >>= 32;
                idx -= 1;
                out_type = 1;
                buf = buffers.items[(idx * 2) + 1];
                fd = err_pipe_fds.items[idx];
            } else {
                // stdout
                idx -= 1;
                out_type = 2;
                buf = buffers.items[idx];
                fd = out_pipe_fds.items[idx];
            }
            const label = opts.targetLabels.items[idx];
            std.debug.print("label: {s} idx: {d} out_type: {d} event type: {d}\n", .{ label, idx, out_type, e.events });
            if (e.events & std.os.linux.EPOLL.HUP != 0) {
                closed_pipes[idx] += out_type;
                // pipe closed so remove epoll monitoring of it
                std.posix.epoll_ctl(epoller, std.os.linux.EPOLL.CTL_DEL, fd, null) catch |err| {
                    try stderr.print("Error removing pipe from epoll '{s}'\n", .{@errorName(err)});
                    return 1;
                };
            }

            var tmp: [4096]u8 = undefined;
            const read_count = std.posix.read(fd, &tmp) catch 0;

            if (read_count == 0) {
                // this means EOF, so pipe is closed and no more data will be coming
                if (closed_pipes[idx] == 3) {
                    // we are about to act on the child process, lets only do it once both stdout and stderr are closed
                    current_event_len -= 2;
                    var child = children.items[idx];
                    if (child.term) |term| {
                        std.debug.print("child '{s}' already terminated {any}\n", .{ label, term });
                    } else {
                        const term = child.wait() catch |err| {
                            try stderr.print("Error waiting for child '{s}'\n", .{@errorName(err)});
                            return 1;
                        };
                        switch (term) {
                            .Exited => |exit_code| {
                                try stderr.print("{s}:exit: exited with code {d}\n", .{ label, exit_code });
                            },
                            .Signal => |signal| {
                                try stderr.print("{s}:sig: terminated with signal {d} ({s})\n", .{ label, signal, signalToString(signal) });
                            },
                            .Stopped => |signal| {
                                try stderr.print("{s}:sig: stopped with signal {d} ({s})\n", .{ label, signal, signalToString(signal) });
                            },
                            .Unknown => |signal| {
                                try stderr.print("{s}:sig: unknown happened with signal {d} ({s})\n", .{ label, signal, signalToString(signal) });
                            },
                        }
                    }
                }
                std.debug.print("current_event_len: {d}", .{current_event_len});
                if (current_event_len == 0) {
                    break :whileepoll;
                }
            } else {
                // does tmp contain a newline? or more than one?
                var start: u16 = 0;
                var out_lines: u16 = 0;
                defer line_buffer.reset();
                while (true) {
                    const new_line_pos = std.mem.indexOf(u8, tmp[start..read_count], "\n");
                    if (new_line_pos == null) {
                        // no newline store in buffer for now
                        const write_count = buf.write(tmp[start..read_count]) catch |err| {
                            try stderr.print("Error writing to fd buffer '{s}'\n", .{@errorName(err)});
                            return 1;
                        };
                        if (write_count != tmp[start..read_count].len) {
                            try stderr.print("Error writing to fd buffer, wrote {d} of {d} bytes\n", .{ write_count, read_count - start });
                            return 1;
                        }
                        break;
                    }
                    const abs_new_line_pos = new_line_pos.? + start;

                    out_lines += 1;
                    const out_name = if (out_type == 2) "out" else "err";
                    line_writer.print("{s}:{s}: {s}{s}\n", .{ label, out_name, buf.getWritten(), tmp[start..abs_new_line_pos] }) catch |err| {
                        try stderr.print("Error formatting line '{s}'\n", .{@errorName(err)});
                        return 1;
                    };
                    buf.reset();

                    start = @as(u16, @intCast(abs_new_line_pos)) + 1;
                }

                if (out_lines == 0) {
                    continue :forevents;
                }

                if (out_type == 0) {
                    const lb = line_buffer.getWritten();
                    const written_count = std.os.linux.write(std.os.linux.STDOUT_FILENO, lb.ptr, lb.len);
                    if (written_count != lb.len) {
                        try stderr.print("Error writing to stdout, wrote {d} of {d} bytes\n", .{ written_count, lb.len });
                        return 1;
                    }
                } else {
                    const lb = line_buffer.getWritten();
                    const written_count = std.os.linux.write(std.os.linux.STDERR_FILENO, lb.ptr, lb.len);
                    if (written_count != lb.len) {
                        try stderr.print("Error writing to stderr, wrote {d} of {d} bytes\n", .{ written_count, lb.len });
                        return 1;
                    }
                }
            }
        }
    }

    return 0;
}

const OptionErrors = std.ArrayList([]const u8);

fn getOptions(alloc: std.mem.Allocator, args: anytype, opts: *Options, optsErrors: *OptionErrors) !void {
    var argi: usize = 1;
    while (argi < args.len) : (argi += 1) {
        const arg = args[argi];
        if (arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-f")) {
                if (args.len - 1 >= argi + 1) {
                    opts.procfileName = args[argi + 1];
                    argi += 1;
                    continue;
                } else {
                    const message = try std.fmt.allocPrint(
                        alloc,
                        "Missing argument for {s}",
                        .{"-f"},
                    );

                    try optsErrors.append(message);
                }
            } else {
                const message = try std.fmt.allocPrint(
                    alloc,
                    "Unknown argument '{s}'",
                    .{arg},
                );

                try optsErrors.append(message);
            }
        } else {
            opts.targetLabels.append(arg) catch |err| {
                const message = try std.fmt.allocPrint(
                    alloc,
                    "Error adding target label '{s}', '{s}'",
                    .{ arg, @errorName(err) },
                );

                try optsErrors.append(message);
            };
        }
    }
    if (optsErrors.items.len > 0) {
        return error.OptionErrors;
    }
    return void{};
}

pub fn signalToString(signal: u32) []const u8 {
    return switch (signal) {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        9 => "SIGKILL",
        10 => "SIGUSR1",
        11 => "SIGSEGV",
        12 => "SIGUSR2",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        16 => "SIGSTKFLT",
        17 => "SIGCHLD",
        18 => "SIGCONT",
        19 => "SIGSTOP",
        20 => "SIGTSTP",
        21 => "SIGTTIN",
        22 => "SIGTTOU",
        23 => "SIGURG",
        24 => "SIGXCPU",
        25 => "SIGXFSZ",
        26 => "SIGVTALRM",
        27 => "SIGPROF",
        28 => "SIGWINCH",
        29 => "SIGIO",
        30 => "SIGPWR",
        31 => "SIGSYS",
        34 => "SIGRTMIN",
        35 => "SIGRTMIN+1",
        36 => "SIGRTMIN+2",
        37 => "SIGRTMIN+3",
        38 => "SIGRTMIN+4",
        39 => "SIGRTMIN+5",
        40 => "SIGRTMIN+6",
        41 => "SIGRTMIN+7",
        42 => "SIGRTMIN+8",
        43 => "SIGRTMIN+9",
        44 => "SIGRTMIN+10",
        45 => "SIGRTMIN+11",
        46 => "SIGRTMIN+12",
        47 => "SIGRTMIN+13",
        48 => "SIGRTMIN+14",
        49 => "SIGRTMIN+15",
        50 => "SIGRTMAX-14",
        51 => "SIGRTMAX-13",
        52 => "SIGRTMAX-12",
        53 => "SIGRTMAX-11",
        54 => "SIGRTMAX-10",
        55 => "SIGRTMAX-9",
        56 => "SIGRTMAX-8",
        57 => "SIGRTMAX-7",
        58 => "SIGRTMAX-6",
        59 => "SIGRTMAX-5",
        60 => "SIGRTMAX-4",
        61 => "SIGRTMAX-3",
        62 => "SIGRTMAX-2",
        63 => "SIGRTMAX-1",
        64 => "SIGRTMAX",
        else => "Unknown Signal",
    };
}

fn execCmd(cmd: []u8) !void {
    var argsPtrs = cmdToArgPtrs(cmd);

    if (DEBUG) {
        for (argsPtrs.args[0..argsPtrs.len]) |argstring| {
            std.debug.print("args: {s}\n", .{argstring.?});
        }
    }

    const env = [_:null]?[*:0]u8{null};

    // Execute command, replacing this process!
    return std.posix.execvpeZ(argsPtrs.args[0].?, &argsPtrs.args, &env);
}

// caller is responsible for freeing returned []u8
fn getCmdFromProcfile(alloc: std.mem.Allocator, reader: anytype, targetLabel: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, 1024);
    defer alloc.free(buf);

    var bufStream = std.io.fixedBufferStream(buf);

    const reading = true;

    while (reading) {
        bufStream.reset();
        reader.streamUntilDelimiter(bufStream.writer(), ':', null) catch |err| switch (err) {
            error.EndOfStream => {
                return error.LabelNotFound;
            },
            else => {
                return err;
            },
        };

        const labelRaw = bufStream.getWritten();
        const label = std.mem.trim(u8, labelRaw, &std.ascii.whitespace);

        if (std.mem.eql(u8, label, targetLabel)) {
            // label match found
            bufStream.reset();
            var bufWriter = bufStream.writer();
            // Skip whitespace
            while (true) {
                const b = reader.readByte() catch |err| {
                    // HACK: We arent using a switch here becuase `zig test src/main.zig` would say:
                    // src/main.zig:147:26: error: unreachable else prong; all cases already handled
                    // If I then removed the else, then zig build-exe src/main.zig would say:
                    // src/main.zig:143:55: error: switch must handle all possibilities
                    if (err == error.EndOfStream) {
                        return error.EmptyCmd;
                    } else {
                        return err;
                    }
                };
                if (b == '\n') {
                    return error.EmptyCmd;
                }
                if (!std.ascii.isWhitespace(b)) {
                    try bufWriter.writeByte(b);
                    break;
                }
            }

            // Read the rest until end of line
            reader.streamUntilDelimiter(bufWriter, '\n', null) catch |err| switch (err) {
                error.EndOfStream => {
                    // this is ok, continue on
                },
                else => {
                    return err;
                },
            };
            try bufWriter.writeByte('\n');
            const procCmd = bufStream.getWritten();

            const cmd = try alloc.dupe(u8, procCmd);
            return cmd;
        } else {
            try reader.skipUntilDelimiterOrEof('\n');
        }
    }

    return error.LabelNotFound;
}

fn getCmdsFromProcfile(alloc: std.mem.Allocator, reader: anytype, targetLabels: [][]const u8) !std.ArrayList([]u8) {
    const buf = try alloc.alloc(u8, 1024);
    defer alloc.free(buf);

    var cmds = std.ArrayList([]u8).initCapacity(alloc, targetLabels.len) catch |err| {
        return err;
    };
    cmds.resize(targetLabels.len) catch |err| {
        return err;
    };
    var found: u8 = 0;

    var bufStream = std.io.fixedBufferStream(buf);

    const reading = true;

    readingFile: while (reading) {
        bufStream.reset();
        reader.streamUntilDelimiter(bufStream.writer(), ':', null) catch |err| switch (err) {
            error.EndOfStream => {
                return error.LabelNotFound;
            },
            else => {
                return err;
            },
        };

        const labelRaw = bufStream.getWritten();
        const label = std.mem.trim(u8, labelRaw, &std.ascii.whitespace);

        var labelMatched = false;
        checkLabels: for (0.., targetLabels) |targetIndex, item| {
            // print
            if (std.mem.eql(u8, label, item)) {
                labelMatched = true;
                found += 1;
                // label match found
                bufStream.reset();
                var bufWriter = bufStream.writer();
                // Skip whitespace
                while (true) {
                    const b = reader.readByte() catch |err| {
                        switch (err) {
                            error.EndOfStream => {
                                return error.EmptyCmd;
                            },
                            else => {
                                return err;
                            },
                        }
                    };
                    if (b == '\n') {
                        return error.EmptyCmd;
                    }
                    if (!std.ascii.isWhitespace(b)) {
                        try bufWriter.writeByte(b);
                        break;
                    }
                }

                // Read the rest until end of line
                reader.streamUntilDelimiter(bufWriter, '\n', null) catch |err| switch (err) {
                    error.EndOfStream => {
                        // this is ok, continue on
                    },
                    else => {
                        return err;
                    },
                };
                try bufWriter.writeByte('\n');
                const procCmd = bufStream.getWritten();

                const cmd = try alloc.dupe(u8, procCmd);
                cmds.items[targetIndex] = cmd;
                break :checkLabels;
            }
        }

        if (!labelMatched) {
            try reader.skipUntilDelimiterOrEof('\n');
        }

        if (found == targetLabels.len) {
            break :readingFile;
        }
    }

    if (found != targetLabels.len) {
        return error.LabelNotFound;
    }

    return cmds;
}

const ArgPtrsStruct = struct { args: [MAX_ARGS:null]?[*:0]u8, len: usize };

// cmd must end with \n
fn cmdToArgPtrs(cmd: []u8) ArgPtrsStruct {
    var args_ptrs: [MAX_ARGS:null]?[*:0]u8 = undefined;

    var inQuotes = false;
    var openQuote: ?u8 = null;
    var argStart: usize = 0;
    var argIndex: u8 = 0;
    var arg: ?[*:0]u8 = null;

    for (cmd, 0..) |char, i| {
        if (char == '"' or char == '\'') {
            if (inQuotes) {
                if (char == openQuote) {
                    // end quote
                    cmd[i] = 0;
                    arg = @as(*align(1) const [*:0]u8, @ptrCast(&cmd[argStart..i :0])).*;
                    args_ptrs[argIndex] = arg;
                    argStart = i + 1;
                    argIndex += 1;

                    inQuotes = false;
                    openQuote = null;
                    continue;
                } else {
                    // quote inside quote, continue
                    continue;
                }
            } else {
                inQuotes = true;
                openQuote = char;
                argStart = i + 1;
                continue;
            }
        }

        if (std.ascii.isWhitespace(char)) {
            if (inQuotes) {
                continue;
            } else {
                if (argStart == i) {
                    // we are at the space after a quoted section, bump arg start and move on
                    argStart = i + 1;
                } else {
                    cmd[i] = 0;
                    arg = @as(*align(1) const [*:0]u8, @ptrCast(&cmd[argStart..i :0])).*;
                    args_ptrs[argIndex] = arg;
                    argStart = i + 1;
                    argIndex += 1;
                }
            }
        }
    }
    args_ptrs[argIndex] = null;

    return ArgPtrsStruct{
        .args = args_ptrs,
        .len = argIndex - 1,
    };
}

fn cmdToArgs(alloc: std.mem.Allocator, cmd: []const u8) !std.ArrayList([]const u8) {
    var inQuotes = false;
    var openQuote: ?u8 = null;
    var argStart: usize = 0;
    var argIndex: u8 = 0;

    var args: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(alloc);

    for (cmd, 0..) |char, i| {
        if (char == '"' or char == '\'') {
            if (inQuotes) {
                if (char == openQuote) {
                    // end quote
                    const arg = cmd[argStart..i];
                    args.append(arg) catch |err| {
                        std.debug.print("Error adding arg '{s}'\n", .{@errorName(err)});
                        return error.OutOfMemory;
                    };
                    argStart = i + 1;
                    argIndex += 1;

                    inQuotes = false;
                    openQuote = null;
                    continue;
                } else {
                    // quote inside quote, continue
                    continue;
                }
            } else {
                inQuotes = true;
                openQuote = char;
                argStart = i + 1;
                continue;
            }
        }

        if (std.ascii.isWhitespace(char)) {
            if (inQuotes) {
                continue;
            } else {
                if (argStart == i) {
                    // we are at the space after a quoted section, bump arg start and move on
                    argStart = i + 1;
                } else {
                    const arg = cmd[argStart..i];
                    args.append(arg) catch |err| {
                        std.debug.print("Error adding arg '{s}'\n", .{@errorName(err)});
                        return error.OutOfMemory;
                    };
                    argStart = i + 1;
                    argIndex += 1;
                }
            }
        }
    }

    return args;
}

test "getOptions" {
    const alloc = std.testing.allocator;

    const base_opts = Options{
        .selfName = "initial value",
        .procfileName = "initial value",
        .targetLabels = .{"initial value"},
    };

    const tests = .{
        .{ "normal options", "cmd -f Procfiletest label0", "", "Procfiletest", "label0" },
        .{ "reverse options", "cmd label0 -f Procfiletest", "", "Procfiletest", "label0" },
        .{ "missing -f arg", "cmd label1 -f", "Missing argument for -f", "initial value", "label1" },
        .{ "missing label", "cmd -f Procfiletest", "", "Procfiletest", "initial value" },
        .{ "no params", "cmd", "Missing argument for -f", "initial value", "initial value" },
        .{ "wrong param", "cmd -f Procfiletest -a", "Unknown argument '-a'", "Procfiletest", "initial value" },
        .{ "wrong param 2", "cmd -a -f Procfiletest", "Unknown argument '-a'", "Procfiletest", "initial value" },
        .{ "wrong param 3", "cmd -a", "Unknown argument '-a'", "initial value", "initial value" },
    };

    std.debug.print("\n", .{});
    inline for (tests, 0..) |t, i| {
        std.debug.print("Test {d} {s}: start...", .{ i, t[0] });
        var opts = base_opts;
        const cmdString = t[1];

        var argBuffer = try std.ArrayList([]const u8).initCapacity(alloc, 5);

        var argSeq = std.mem.splitSequence(u8, cmdString, " ");
        var reading = true;
        while (reading) {
            const item = argSeq.next();
            if (item) |ai| {
                try argBuffer.append(ai);
            } else {
                reading = false;
            }
        }
        const args = try argBuffer.toOwnedSlice();

        const expected_procfilename: []const u8 = t[3];
        const expected_label: []const u8 = t[4];

        var optsErrs = try OptionErrors.initCapacity(alloc, 2);
        defer optsErrs.deinit();
        getOptions(alloc, args, &opts, &optsErrs) catch {
            defer alloc.free(optsErrs.items[0]);
            try std.testing.expectEqualStrings(t[2], optsErrs.items[0]);
        };

        // std.debug.print("XXXXXXX {any} '{s}' {any} '{s}'\n", .{ @TypeOf(expected_procfilename), expected_procfilename, @TypeOf(opts.procfileName), opts.procfileName });
        try std.testing.expectEqualStrings(expected_procfilename, opts.procfileName);
        try std.testing.expectEqualStrings(.{expected_label}, opts.targetLabels);
        std.debug.print("done\n", .{});
        alloc.free(args);
    }
}

test "getCmdFromProcfile errors" {
    const alloc = std.testing.allocator;

    const tests = .{
        .{ "cmd is empty, end of file", "label3", "label1: ls -la\nlabel2: less\nlabel3:", error.EmptyCmd },
        .{ "cmd is empty, middle file", "label2", "label1: ls -la\nlabel2:\nlabel3: grep\n", error.EmptyCmd },
        .{ "empty procfile", "label1", "", error.LabelNotFound },
    };

    std.debug.print("\n", .{});
    inline for (tests, 0..) |t, i| {
        std.debug.print("Test {d} {s}: start...", .{ i, t[0] });

        const targetLabel = try alloc.dupe(u8, t[1]);
        defer alloc.free(targetLabel);

        const procfile = t[2];
        const expectedError = t[3];
        var fbs = std.io.fixedBufferStream(procfile);
        const r = fbs.reader();

        const result = getCmdFromProcfile(alloc, r, targetLabel);
        try std.testing.expectError(expectedError, result);
        std.debug.print("done\n", .{});
    }
}

test "getCmdFromProcfile simple" {
    const alloc = std.testing.allocator;

    const tests = .{
        .{ "one profile entry", "label1", "label1: ls -la\n", "ls -la\n" },
        .{ "match in middle of file", "label2", "label1: ls -la\nlabel2: less\nlabel3: grep\n", "less\n" },
        .{ "match on last line", "label3", "label1: ls -la\nlabel2: less\nlabel3: grep\n", "grep\n" },
        .{ "no ending newline", "label3", "label1: ls -la\nlabel2: less\nlabel3: grep", "grep\n" },
        .{ "label with dash", "label-3", "label1: ls -la\nlabel2: less\nlabel-3: grep\n", "grep\n" },
        .{ "label with space", "label 2", "label1: ls -la\nlabel 2: less\nlabel3: grep\n", "less\n" },
        .{ "label with symbol", "label*2", "label1: ls -la\nlabel*2: less\nlabel3: grep\n", "less\n" },
    };

    std.debug.print("\n", .{});
    inline for (tests, 0..) |t, i| {
        std.debug.print("Test {d} {s}: start...", .{ i, t[0] });

        const targetLabel = try alloc.dupe(u8, t[1]);
        defer alloc.free(targetLabel);

        const procfile = t[2];
        const expectedResult = t[3];
        var fbs = std.io.fixedBufferStream(procfile);
        const r = fbs.reader();

        const result = try getCmdFromProcfile(alloc, r, targetLabel);
        try std.testing.expectEqualStrings(expectedResult, result);
        alloc.free(result);
        std.debug.print("done\n", .{});
    }
}

test "cmdToArgPtrs table of tests" {
    const alloc = std.testing.allocator;

    const tests = .{
        .{ "make\n", .{"make"} },
        .{ "make test\n", .{ "make", "test" } },
        .{ "ls -la\n", .{ "ls", "-la" } },
        .{ "/bin/bash\n", .{"/bin/bash"} },
        .{ "/bin/bash -c 'ls'\n", .{ "/bin/bash", "-c", "ls" } },
        .{ "/bin/bash -c \"ls\"\n", .{ "/bin/bash", "-c", "ls" } },
        .{ "/bin/bash -c \"ls -la\"\n", .{ "/bin/bash", "-c", "ls -la" } },
        .{ "/bin/bash -c \"ls -la | cut -d' '\"\n", .{ "/bin/bash", "-c", "ls -la | cut -d' '" } },
    };

    inline for (tests) |t| {
        const tlen = t[0].len;
        var buffer: [10240]u8 = undefined;
        var offset: usize = 0;
        var cmd: []u8 = buffer[offset..tlen];
        offset += tlen + 1;
        std.mem.copy(u8, cmd, t[0]);

        var expResult: [t[1].len][]u8 = undefined;
        inline for (t[1], 0..) |word, i| {
            const w: []u8 = buffer[offset .. offset + word.len];
            offset += word.len + 1;
            std.mem.copy(u8, w, word);
            expResult[i] = w;
        }
        var resultRaw = cmdToArgPtrs(cmd[0..tlen]);

        var result: [t[1].len][]u8 = undefined;

        inline for (resultRaw.args[0..t[1].len], 0..) |word, i| {
            result[i] = std.mem.span(word.?);
        }

        const exp: []u8 = try std.mem.join(alloc, "_", &expResult);
        defer alloc.free(exp);

        const res: []u8 = try std.mem.join(alloc, "_", &result);
        defer alloc.free(res);

        try std.testing.expectEqualStrings(exp, res);
    }
}
