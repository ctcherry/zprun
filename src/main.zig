const std = @import("std");

const DEBUG = false;

pub fn main() !u8 {
    const max_args = 100;

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

            var args_ptrs: [max_args:null]?[*:0]u8 = undefined;

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

            if (DEBUG) {
                for (args_ptrs[0..argIndex]) |argstring| {
                    std.debug.print("args: {s}\n", .{argstring.?});
                }
            }

            const env = [_:null]?[*:0]u8{null};

            // Execute command, replacing child process!
            var err = std.os.execvpeZ(args_ptrs[0].?, &args_ptrs, &env);
            try stderr.print("Error: {s}\n", .{@errorName(err)});
            return 1;
        } else {
            try in_stream.skipUntilDelimiterOrEof('\n');
        }
    }

    return 1;
}
