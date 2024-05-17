const std = @import("std");

pub const Procfile = struct {
    file: std.fs.File,

    pub fn open(filePath: []const u8) !Procfile {
        const file = try std.fs.cwd().openFile(filePath, .{});
        return Procfile{
            .file = file,
        };
    }

    pub fn close(self: *Procfile) void {
        return self.file.close();
    }

    pub fn cmdsForLabels(self: *Procfile, alloc: std.mem.Allocator, labels: []const []const u8) !std.ArrayList([]u8) {
        const buf = try alloc.alloc(u8, 1024);
        defer alloc.free(buf);

        var bReader = std.io.bufferedReader(self.file.reader());
        var reader = bReader.reader();

        var cmds = std.ArrayList([]u8).initCapacity(alloc, labels.len) catch |err| {
            return err;
        };
        cmds.resize(labels.len) catch |err| {
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
            checkLabels: for (0.., labels) |targetIndex, item| {
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

            if (found == labels.len) {
                break :readingFile;
            }
        }

        if (found != labels.len) {
            return error.LabelNotFound;
        }

        return cmds;
    }
};
