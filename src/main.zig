const std = @import("std");

const DEBUG = false;
const MAX_ARGS = 100;
const DEFAULT_PROCFILE_NAME = "Procfile";

const Options = struct {
    selfName: []const u8,
    procfileName: []const u8,
    targetLabel: []const u8,
};

pub fn main() !u8 {
    const stderr = std.io.getStdErr().writer();

    var allocSpace: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocSpace);
    var alloc = fba.allocator();

    var args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var opts = Options{
        .selfName = args[0],
        .procfileName = try alloc.dupe(u8, DEFAULT_PROCFILE_NAME),
        .targetLabel = "",
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

    if (opts.targetLabel.len == 0) {
        try stderr.print("Usage: {s} [options] <label>\n\tlabel    Label of the command to run in Procfile\n\t-f path  Use file other than Procfile", .{opts.selfName});
        return 1;
    }

    var procfileBufReader_ = std.io.bufferedReader(procfile.reader());
    var procfileBufReader = procfileBufReader_.reader();

    var command = getCmdFromProcfile(alloc, procfileBufReader, opts.targetLabel) catch |err| {
        switch (err) {
            error.LabelNotFound => {
                try stderr.print("Error: Unable to find label '{s}' in procfile '{s}'\n", .{ opts.targetLabel, opts.procfileName });
            },
            error.EmptyCmd => {
                try stderr.print("Error: Unable to find command for label '{s}' in procfile '{s}'\n", .{ opts.targetLabel, opts.procfileName });
            },
            else => {
                try stderr.print("Error: Extracting command from procfile '{s}'\n", .{@errorName(err)});
            },
        }
        return 1;
    };

    execCmd(command) catch |err| {
        try stderr.print("Error executing command: '{s}' from label '{s}' in procfile '{s}': {s}\n", .{ command, opts.targetLabel, opts.procfileName, @errorName(err) });
        return 1;
    };
    unreachable;
}

const OptionErrors = std.ArrayList([]const u8);

fn getOptions(alloc: std.mem.Allocator, args: anytype, opts: *Options, optsErrors: *OptionErrors) !void {
    var argi: usize = 1;
    while (argi < args.len) : (argi += 1) {
        var arg = args[argi];
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
            opts.targetLabel = arg;
        }
    }
    if (optsErrors.items.len > 0) {
        return error.OptionErrors;
    }
    return void{};
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
    return std.os.execvpeZ(argsPtrs.args[0].?, &argsPtrs.args, &env);
}

// caller is responsible for freeing returned []u8
fn getCmdFromProcfile(alloc: std.mem.Allocator, reader: anytype, targetLabel: []const u8) ![]u8 {
    var buf = try alloc.alloc(u8, 1024);
    defer alloc.free(buf);

    var bufStream = std.io.fixedBufferStream(buf);

    var reading = true;

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

        var labelRaw = bufStream.getWritten();
        var label = std.mem.trim(u8, labelRaw, &std.ascii.whitespace);

        if (std.mem.eql(u8, label, targetLabel)) {
            // label match found
            bufStream.reset();
            var bufWriter = bufStream.writer();
            // Skip whitespace
            while (true) {
                var b = reader.readByte() catch |err| {
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
            var procCmd = bufStream.getWritten();

            var cmd = try alloc.dupe(u8, procCmd);
            return cmd;
        } else {
            try reader.skipUntilDelimiterOrEof('\n');
        }
    }

    return error.LabelNotFound;
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

test "getOptions" {
    const alloc = std.testing.allocator;

    var base_opts = Options{
        .selfName = "initial value",
        .procfileName = "initial value",
        .targetLabel = "initial value",
    };

    var tests = .{
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
        var cmdString = t[1];

        var argBuffer = try std.ArrayList([]const u8).initCapacity(alloc, 5);

        var argSeq = std.mem.splitSequence(u8, cmdString, " ");
        var reading = true;
        while (reading) {
            var item = argSeq.next();
            if (item) |ai| {
                try argBuffer.append(ai);
            } else {
                reading = false;
            }
        }
        var args = try argBuffer.toOwnedSlice();

        var expected_procfilename: []const u8 = t[3];
        var expected_label: []const u8 = t[4];

        var optsErrs = try OptionErrors.initCapacity(alloc, 2);
        defer optsErrs.deinit();
        getOptions(alloc, args, &opts, &optsErrs) catch {
            defer alloc.free(optsErrs.items[0]);
            try std.testing.expectEqualStrings(t[2], optsErrs.items[0]);
        };

        // std.debug.print("XXXXXXX {any} '{s}' {any} '{s}'\n", .{ @TypeOf(expected_procfilename), expected_procfilename, @TypeOf(opts.procfileName), opts.procfileName });
        try std.testing.expectEqualStrings(expected_procfilename, opts.procfileName);
        try std.testing.expectEqualStrings(expected_label, opts.targetLabel);
        std.debug.print("done\n", .{});
        alloc.free(args);
    }
}

test "getCmdFromProcfile errors" {
    const alloc = std.testing.allocator;

    var tests = .{
        .{ "cmd is empty, end of file", "label3", "label1: ls -la\nlabel2: less\nlabel3:", error.EmptyCmd },
        .{ "cmd is empty, middle file", "label2", "label1: ls -la\nlabel2:\nlabel3: grep\n", error.EmptyCmd },
        .{ "empty procfile", "label1", "", error.LabelNotFound },
    };

    std.debug.print("\n", .{});
    inline for (tests, 0..) |t, i| {
        std.debug.print("Test {d} {s}: start...", .{ i, t[0] });

        var targetLabel = try alloc.dupe(u8, t[1]);
        defer alloc.free(targetLabel);

        var procfile = t[2];
        var expectedError = t[3];
        var fbs = std.io.fixedBufferStream(procfile);
        var r = fbs.reader();

        var result = getCmdFromProcfile(alloc, r, targetLabel);
        try std.testing.expectError(expectedError, result);
        std.debug.print("done\n", .{});
    }
}

test "getCmdFromProcfile simple" {
    const alloc = std.testing.allocator;

    var tests = .{
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

        var targetLabel = try alloc.dupe(u8, t[1]);
        defer alloc.free(targetLabel);

        var procfile = t[2];
        var expectedResult = t[3];
        var fbs = std.io.fixedBufferStream(procfile);
        var r = fbs.reader();

        var result = try getCmdFromProcfile(alloc, r, targetLabel);
        try std.testing.expectEqualStrings(expectedResult, result);
        alloc.free(result);
        std.debug.print("done\n", .{});
    }
}

test "cmdToArgPtrs table of tests" {
    const alloc = std.testing.allocator;

    var tests = .{
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
        var tlen = t[0].len;
        var buffer: [10240]u8 = undefined;
        var offset: usize = 0;
        var cmd: []u8 = buffer[offset..tlen];
        offset += tlen + 1;
        std.mem.copy(u8, cmd, t[0]);

        var expResult: [t[1].len][]u8 = undefined;
        inline for (t[1], 0..) |word, i| {
            var w: []u8 = buffer[offset .. offset + word.len];
            offset += word.len + 1;
            std.mem.copy(u8, w, word);
            expResult[i] = w;
        }
        var resultRaw = cmdToArgPtrs(cmd[0..tlen]);

        var result: [t[1].len][]u8 = undefined;

        inline for (resultRaw.args[0..t[1].len], 0..) |word, i| {
            result[i] = std.mem.span(word.?);
        }

        var exp: []u8 = try std.mem.join(alloc, "_", &expResult);
        defer alloc.free(exp);

        var res: []u8 = try std.mem.join(alloc, "_", &result);
        defer alloc.free(res);

        try std.testing.expectEqualStrings(exp, res);
    }
}
