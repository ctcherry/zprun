const std = @import("std");
const Procfile = @import("procfile.zig").Procfile;
const MultiProcessRunner = @import("runner.zig").MultiProcessRunner;
const MultiProcessRunnerMemoryNeeds = @import("runner.zig").totalMemoryNeeded;

const DEBUG = false;
const MAX_ARGS = 100;
const MAX_PARALLEL_PROCESSES = 32;
const DEFAULT_PROCFILE_NAME = "Procfile";

const Options = struct {
    selfName: []const u8,
    procfileName: []const u8,
    targetLabels: std.ArrayList([]const u8),
};

pub fn main() !u8 {
    const stderr = std.io.getStdErr().writer();

    var allocSpace: [MultiProcessRunnerMemoryNeeds(MAX_PARALLEL_PROCESSES)]u8 = undefined;
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

    var procfile = Procfile.open(opts.procfileName) catch |err| {
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

    const commands = procfile.cmdsForLabels(alloc, opts.targetLabels.items) catch |err| {
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

    var runner = try MultiProcessRunner.initCapacity(alloc, commands.items.len);
    for (0..commands.items.len) |i| {
        try runner.addProcessAssumeCapacity(opts.targetLabels.items[i], commands.items[i]);
    }
    try runner.run();

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

// test "getCmdFromProcfile errors" {
//     const alloc = std.testing.allocator;
//
//     const tests = .{
//         .{ "cmd is empty, end of file", "label3", "label1: ls -la\nlabel2: less\nlabel3:", error.EmptyCmd },
//         .{ "cmd is empty, middle file", "label2", "label1: ls -la\nlabel2:\nlabel3: grep\n", error.EmptyCmd },
//         .{ "empty procfile", "label1", "", error.LabelNotFound },
//     };
//
//     std.debug.print("\n", .{});
//     inline for (tests, 0..) |t, i| {
//         std.debug.print("Test {d} {s}: start...", .{ i, t[0] });
//
//         const targetLabel = try alloc.dupe(u8, t[1]);
//         defer alloc.free(targetLabel);
//
//         const procfile = t[2];
//         const expectedError = t[3];
//         var fbs = std.io.fixedBufferStream(procfile);
//         const r = fbs.reader();
//
//         const result = getCmdFromProcfile(alloc, r, targetLabel);
//         try std.testing.expectError(expectedError, result);
//         std.debug.print("done\n", .{});
//     }
// }

// test "getCmdFromProcfile simple" {
//     const alloc = std.testing.allocator;
//
//     const tests = .{
//         .{ "one profile entry", "label1", "label1: ls -la\n", "ls -la\n" },
//         .{ "match in middle of file", "label2", "label1: ls -la\nlabel2: less\nlabel3: grep\n", "less\n" },
//         .{ "match on last line", "label3", "label1: ls -la\nlabel2: less\nlabel3: grep\n", "grep\n" },
//         .{ "no ending newline", "label3", "label1: ls -la\nlabel2: less\nlabel3: grep", "grep\n" },
//         .{ "label with dash", "label-3", "label1: ls -la\nlabel2: less\nlabel-3: grep\n", "grep\n" },
//         .{ "label with space", "label 2", "label1: ls -la\nlabel 2: less\nlabel3: grep\n", "less\n" },
//         .{ "label with symbol", "label*2", "label1: ls -la\nlabel*2: less\nlabel3: grep\n", "less\n" },
//     };
//
//     std.debug.print("\n", .{});
//     inline for (tests, 0..) |t, i| {
//         std.debug.print("Test {d} {s}: start...", .{ i, t[0] });
//
//         const targetLabel = try alloc.dupe(u8, t[1]);
//         defer alloc.free(targetLabel);
//
//         const procfile = t[2];
//         const expectedResult = t[3];
//         var fbs = std.io.fixedBufferStream(procfile);
//         const r = fbs.reader();
//
//         const result = try getCmdFromProcfile(alloc, r, targetLabel);
//         try std.testing.expectEqualStrings(expectedResult, result);
//         alloc.free(result);
//         std.debug.print("done\n", .{});
//     }
// }

// test "cmdToArgPtrs table of tests" {
//     const alloc = std.testing.allocator;
//
//     const tests = .{
//         .{ "make\n", .{"make"} },
//         .{ "make test\n", .{ "make", "test" } },
//         .{ "ls -la\n", .{ "ls", "-la" } },
//         .{ "/bin/bash\n", .{"/bin/bash"} },
//         .{ "/bin/bash -c 'ls'\n", .{ "/bin/bash", "-c", "ls" } },
//         .{ "/bin/bash -c \"ls\"\n", .{ "/bin/bash", "-c", "ls" } },
//         .{ "/bin/bash -c \"ls -la\"\n", .{ "/bin/bash", "-c", "ls -la" } },
//         .{ "/bin/bash -c \"ls -la | cut -d' '\"\n", .{ "/bin/bash", "-c", "ls -la | cut -d' '" } },
//     };
//
//     inline for (tests) |t| {
//         const tlen = t[0].len;
//         var buffer: [10240]u8 = undefined;
//         var offset: usize = 0;
//         var cmd: []u8 = buffer[offset..tlen];
//         offset += tlen + 1;
//         std.mem.copy(u8, cmd, t[0]);
//
//         var expResult: [t[1].len][]u8 = undefined;
//         inline for (t[1], 0..) |word, i| {
//             const w: []u8 = buffer[offset .. offset + word.len];
//             offset += word.len + 1;
//             std.mem.copy(u8, w, word);
//             expResult[i] = w;
//         }
//         var resultRaw = cmdToArgPtrs(cmd[0..tlen]);
//
//         var result: [t[1].len][]u8 = undefined;
//
//         inline for (resultRaw.args[0..t[1].len], 0..) |word, i| {
//             result[i] = std.mem.span(word.?);
//         }
//
//         const exp: []u8 = try std.mem.join(alloc, "_", &expResult);
//         defer alloc.free(exp);
//
//         const res: []u8 = try std.mem.join(alloc, "_", &result);
//         defer alloc.free(res);
//
//         try std.testing.expectEqualStrings(exp, res);
//     }
// }
