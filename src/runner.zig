const std = @import("std");

const LINE_BUFFER_SIZE = 8192 + 1024;
const BUFFER_SIZE = 8192;
const EPOLL_WAIT = 5000;
const ARG_MAX = 128 * 1024;

fn perProcessMemoryNeeds() usize {
    const double = 2 * (BUFFER_SIZE + @sizeOf(std.io.FixedBufferStream([]u8)) + @sizeOf(std.os.linux.epoll_event) + @sizeOf(std.posix.fd_t));
    return double + @sizeOf([]u8) + @sizeOf(u2) + @sizeOf(std.ChildProcess) + ARG_MAX;
}

pub fn totalMemoryNeeded(comptime n: usize) usize {
    const variable_usage = n * perProcessMemoryNeeds();
    const fixed_usage = @sizeOf(std.io.FixedBufferStream([LINE_BUFFER_SIZE]u8));
    return variable_usage + fixed_usage;
}

pub const MultiProcessRunner = struct {
    alloc: std.mem.Allocator,

    out_fds: []std.posix.fd_t,
    err_fds: []std.posix.fd_t,

    out_buffers: []std.io.FixedBufferStream([]u8),
    err_buffers: []std.io.FixedBufferStream([]u8),

    line_buffer: std.io.FixedBufferStream([]u8),

    labels: [][]const u8,
    closed_pipes: []u2,
    children: []std.ChildProcess,

    len: usize,

    epoll_fd: i32,
    epoll_count: u8,

    debug: bool = false,

    pub fn initCapacity(alloc: std.mem.Allocator, size: usize) !MultiProcessRunner {
        const out_pipe_fds = try alloc.alloc(std.posix.fd_t, size);

        const err_pipe_fds = try alloc.alloc(std.posix.fd_t, size);

        const out_bufs = try alloc.alloc(std.io.FixedBufferStream([]u8), size);
        const err_bufs = try alloc.alloc(std.io.FixedBufferStream([]u8), size);

        const line_buffer = std.io.fixedBufferStream(try alloc.alloc(u8, LINE_BUFFER_SIZE));

        for (0..size) |b| {
            out_bufs[b] = std.io.fixedBufferStream(try alloc.alloc(u8, BUFFER_SIZE));
            err_bufs[b] = std.io.fixedBufferStream(try alloc.alloc(u8, BUFFER_SIZE));
        }

        const labels = try alloc.alloc([]u8, size);
        const closed_pipes = try alloc.alloc(u2, size);
        @memset(closed_pipes, 0);

        const children = try alloc.alloc(std.ChildProcess, size);

        const epoll_fd = try std.posix.epoll_create1(0);

        return MultiProcessRunner{
            .alloc = alloc,
            .out_fds = out_pipe_fds,
            .err_fds = err_pipe_fds,
            .out_buffers = out_bufs,
            .err_buffers = err_bufs,
            .line_buffer = line_buffer,
            .labels = labels,
            .closed_pipes = closed_pipes,
            .children = children,
            .len = 0,
            .epoll_fd = epoll_fd,
            .epoll_count = 0,
        };
    }

    pub fn addProcessAssumeCapacity(self: *MultiProcessRunner, label: []const u8, cmd: []const u8) !void {
        const args = try self.cmdToArgs(cmd);
        var child_proc = std.ChildProcess.init(args, self.alloc);
        child_proc.stdout_behavior = .Pipe;
        child_proc.stderr_behavior = .Pipe;
        child_proc.stdin_behavior = .Ignore;

        self.labels[self.len] = label;
        self.children[self.len] = child_proc;

        self.len += 1;
    }

    /// This runs all of the ChildProcesses and doesnt return until they do
    pub fn run(self: *MultiProcessRunner) !void {
        try self.spawn_and_setup_epoll();

        const events = try self.alloc.alloc(std.os.linux.epoll_event, self.len * 2); // times 2 here becuase stdout and stderr for each process

        whileepoll: while (self.epoll_is_any()) {
            const event_count = std.posix.epoll_wait(self.epoll_fd, events, EPOLL_WAIT);
            if (event_count == 0) {
                continue :whileepoll;
            }

            for (0..event_count) |i| {
                const e = self.parse_event(events[i]);
                try self.process_event(e);
            }
        }
    }

    fn debug_log(self: *MultiProcessRunner, comptime format: []const u8, params: anytype) void {
        if (self.debug) {
            std.debug.print(":debug: ", .{});
            std.debug.print(format, params);
        }
    }

    fn process_event(self: *MultiProcessRunner, event: ParsedEvent) !void {
        const idx = event.idx;
        const out_name = event.out_name;
        const out_type = event.out_type;
        var buf = event.buf;
        const fd = event.fd;

        const label = self.labels[idx];

        // If the fd has hung up we should not wait for a newline,
        // and just process what we get, also stop monitoring it with epoll
        var wait_for_newline = true;
        if (event.contains_event_hangup()) {
            self.debug_log("fd {d} hung up, not waiting for new line\n", .{fd});
            self.closed_pipes[idx] += @intCast(out_type);
            try self.epoll_del(fd);
            wait_for_newline = false;
        }

        const stderr = std.io.getStdErr().writer();
        var line_writer = self.line_buffer.writer();

        reading: while (true) {
            var tmp: [BUFFER_SIZE]u8 = undefined;
            const read_count = std.posix.read(fd, &tmp) catch 0;
            self.debug_log("read {d} bytes from fd {d}\n", .{ read_count, fd });
            if (read_count == 0) {
                break :reading;
            }

            var start: u16 = 0;
            scanning: while (true) {
                const new_line_pos_result = std.mem.indexOf(u8, tmp[start..read_count], "\n");

                if (new_line_pos_result) |new_line_pos| {
                    const abs_new_line_pos = new_line_pos + start;
                    line_writer.print("{s}:{s}: {s}{s}\n", .{ label, out_name, buf.getWritten(), tmp[start..abs_new_line_pos] }) catch |err| {
                        try stderr.print("Error formatting line '{s}'\n", .{@errorName(err)});
                        return error.WriteError;
                    };
                    start = @as(u16, @intCast(abs_new_line_pos)) + 1;

                    buf.reset();
                } else {
                    const buf_is_full = (try buf.getPos() == try buf.getEndPos());
                    if (buf_is_full) {
                        line_writer.print("{s}:{s}~: {s}{s}\n", .{ label, out_name, buf.getWritten(), tmp[start..read_count] }) catch |err| {
                            try stderr.print("Error formatting line '{s}'\n", .{@errorName(err)});
                            return error.WriteError;
                        };
                        buf.reset();
                        break :scanning;
                    }
                    const write_count = buf.write(tmp[start..read_count]) catch |err| {
                        try stderr.print("Error writing to fd buffer '{s}'\n", .{@errorName(err)});
                        return error.WriteError;
                    };
                    if (write_count != tmp[start..read_count].len) {
                        try stderr.print("Error writing to fd buffer, wrote {d} of {d} bytes\n", .{ write_count, read_count - start });
                        return error.WriteError;
                    }
                    break :scanning;
                }
            }

            if (try self.line_buffer.getPos() > 0) {
                defer self.line_buffer.reset();
                const lb = self.line_buffer.getWritten();
                const written_count = std.os.linux.write(std.os.linux.STDOUT_FILENO, lb.ptr, lb.len);
                if (written_count != lb.len) {
                    try stderr.print("Error writing to stdout, wrote {d} of {d} bytes\n", .{ written_count, lb.len });
                    return error.WriteError;
                }
            }
        }

        self.debug_log("buf.getPos() = {d} bytes\n", .{try buf.getPos()});
        if (!wait_for_newline and try buf.getPos() > 0) {
            defer self.line_buffer.reset();
            line_writer.print("{s}:{s}: {s}\n", .{ label, out_name, buf.getWritten() }) catch |err| {
                try stderr.print("Error formatting line '{s}'\n", .{@errorName(err)});
                return error.WriteError;
            };

            const lb = self.line_buffer.getWritten();
            const written_count = std.os.linux.write(std.os.linux.STDOUT_FILENO, lb.ptr, lb.len);
            if (written_count != lb.len) {
                try stderr.print("Error writing to stdout, wrote {d} of {d} bytes\n", .{ written_count, lb.len });
                return error.WriteError;
            }
        }

        if (self.closed_pipes[idx] == 3) {
            // both stderr and stdout are close for this index
            // lets shut down the child process
            try self.childShutdown(idx);
        }
    }

    const ParsedEvent = struct {
        idx: usize,
        out_name: []const u8,
        out_type: u8,
        buf: *std.io.FixedBufferStream([]u8),
        fd: std.posix.fd_t,
        events: u32,

        fn contains_event(self: ParsedEvent, event: u16) bool {
            return self.events & event != 0;
        }

        fn contains_event_hangup(self: ParsedEvent) bool {
            return self.contains_event(std.os.linux.EPOLL.HUP);
        }
    };

    fn parse_event(self: *MultiProcessRunner, event: std.os.linux.epoll_event) ParsedEvent {
        if (event.data.u64 >= std.math.maxInt(u32)) {
            // stderr
            const idx = (event.data.u64 >> 32) - 1;
            return .{ .idx = idx, .out_name = "err", .out_type = 1, .buf = &self.err_buffers[idx], .fd = self.err_fds[idx], .events = event.events };
        } else {
            // stdout
            const idx = event.data.u64 - 1;
            return .{ .idx = idx, .out_name = "out", .out_type = 2, .buf = &self.out_buffers[idx], .fd = self.out_fds[idx], .events = event.events };
        }
    }

    fn epoll_add(self: *MultiProcessRunner, fd: i32, data: u64) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN, // let us know when we can read from the pipe
            .data = std.os.linux.epoll_data{ .u64 = data },
        };
        self.epoll_count += 1;
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn epoll_del(self: *MultiProcessRunner, fd: std.posix.fd_t) !void {
        self.epoll_count -= 1;
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
    }

    fn epoll_is_any(self: *MultiProcessRunner) bool {
        return self.epoll_count > 0;
    }

    fn spawn_and_setup_epoll(self: *MultiProcessRunner) !void {
        for (0..self.len) |i| {
            var child_proc = &self.children[i];
            try child_proc.spawn();

            var setup_fds: [2]struct { fd: std.posix.fd_t, id: u64 } = undefined;

            if (child_proc.stdout) |f| {
                self.out_fds[i] = f.handle;
                setup_fds[0] = .{
                    .fd = f.handle,
                    .id = i + 1,
                };
            }

            if (child_proc.stderr) |f| {
                self.err_fds[i] = f.handle;
                setup_fds[1] = .{
                    .fd = f.handle,
                    .id = (i + 1) << 32,
                };
            }

            for (setup_fds) |d| {
                // Set fd to non blocking
                var fl_flags = try std.posix.fcntl(d.fd, std.posix.F.GETFL, 0);
                fl_flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
                _ = try std.posix.fcntl(d.fd, std.posix.F.SETFL, fl_flags);

                // monitor fd with epoll
                try self.epoll_add(d.fd, d.id);
            }
        }
    }

    fn childShutdown(self: *MultiProcessRunner, idx: usize) !void {
        const label = self.labels[idx];
        var child = &self.children[idx];
        const stderr = std.io.getStdErr().writer();
        if (child.term) |term| {
            self.debug_log("child '{s}' already terminated {any}\n", .{ label, term });
        } else {
            self.debug_log("wait terminating child '{s}'\n", .{label});
            const term = child.wait() catch |err| {
                try stderr.print("Error waiting for child '{s}'\n", .{@errorName(err)});
                return err;
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

    fn cmdToArgs(self: *MultiProcessRunner, cmd: []const u8) ![]const []const u8 {
        var inQuotes = false;
        var openQuote: ?u8 = null;
        var argStart: usize = 0;
        var argIndex: u8 = 0;

        var args: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(self.alloc);

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

        return args.toOwnedSlice();
    }
};

fn signalToString(signal: u32) []const u8 {
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
