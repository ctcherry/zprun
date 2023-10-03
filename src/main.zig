const std = @import("std");

const DEBUG = false;
const MAX_ARGS = 100;

pub fn main() !u8 {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (std.os.argv.len < 2) {
        try stdout.print("Usage: {s} <label>\n", .{std.os.argv[0]});
        return 1;
    }

    // std.debug.print("{any}\n", .{std.os.argv});
    // std.debug.print("{any}\n", .{@TypeOf(std.os.argv[1])});

    var targetLabel = std.mem.span(std.os.argv[1]);

    var file = try std.fs.cwd().openFile("Procfile", .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var buf: [1024]u8 = undefined;
    var bufStream = std.io.fixedBufferStream(&buf);

    var reading = true;

    while (reading) {
        bufStream.reset();
        in_stream.streamUntilDelimiter(bufStream.writer(), ':', null) catch |err| switch (err) {
            error.EndOfStream => {
                reading = false;
                try stderr.print("Error: Could not find label '{s}'\n", .{targetLabel});
                return 1;
            },
            else => {
                try stderr.print("Error: {s}\n", .{@errorName(err)});
                return 1;
            },
        };

        var labelRaw = bufStream.getWritten();
        var label = std.mem.trim(u8, labelRaw, &std.ascii.whitespace);

        if (std.mem.eql(u8, label, targetLabel)) {
            // label match found
            bufStream.reset();
            // Skip whitespace
            while (true) {
                var b = try in_stream.readByte();
                if (!std.ascii.isWhitespace(b)) {
                    try bufStream.writer().writeByte(b);
                    break;
                }
            }

            var bufWriter = bufStream.writer();
            // Read the rest until end of line
            in_stream.streamUntilDelimiter(bufWriter, '\n', null) catch |err| {
                try stderr.print("Error: {s}\n", .{@errorName(err)});
                reading = false;
                return 1;
            };
            try bufWriter.writeByte('\n');
            var cmd = bufStream.getWritten();
            var argsPtrs = cmdToArgPtrs(cmd);

            if (DEBUG) {
                for (argsPtrs.args[0..argsPtrs.len]) |argstring| {
                    std.debug.print("args: {s}\n", .{argstring.?});
                }
            }

            const env = [_:null]?[*:0]u8{null};

            // Execute command, replacing child process!
            var err = std.os.execvpeZ(argsPtrs.args[0].?, &argsPtrs.args, &env);
            try stderr.print("Error: {s}\n", .{@errorName(err)});
            return 1;
        } else {
            try in_stream.skipUntilDelimiterOrEof('\n');
        }
    }

    return 1;
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

test cmdToArgPtrs {
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
