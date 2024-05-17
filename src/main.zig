const std = @import("std");
const clap = @import("clap");
const Procfile = @import("procfile.zig").Procfile;
const MultiProcessRunner = @import("runner.zig").MultiProcessRunner;
const MultiProcessRunnerMemoryNeeds = @import("runner.zig").totalMemoryNeeded;

const MAX_PARALLEL_PROCESSES = 32;
const DEFAULT_PROCFILE_NAME = "Procfile";

pub fn main() !u8 {
    const stderr = std.io.getStdErr().writer();

    var allocSpace: [MultiProcessRunnerMemoryNeeds(MAX_PARALLEL_PROCESSES)]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocSpace);
    const alloc = fba.allocator();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-p, --procfile <str>   Filename (including optional path) of the Procfile to use. Default is 'Procfile'.
        \\--debug                Debug messages
        \\<str>...               Label(s) of one or more commands to run from the specified Procfile
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| {
        // Report useful error and exit
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };

    defer res.deinit();

    const procfileName = res.args.procfile orelse DEFAULT_PROCFILE_NAME;

    var procfile = Procfile.open(procfileName) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try stderr.print("Error: File '{s}' for procfile not found\n", .{procfileName});
            },
            else => {
                try stderr.print("Error opening file '{s}' {s}\n", .{ procfileName, @errorName(err) });
            },
        }
        return 1;
    };
    defer procfile.close();

    if (res.positionals.len == 0) {
        try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        return 0;
    }

    const commands = procfile.cmdsForLabels(alloc, res.positionals) catch |err| {
        switch (err) {
            error.LabelNotFound => {
                try stderr.print("Error: Unable to find all labels in procfile '{s}'\n", .{procfileName});
            },
            error.EmptyCmd => {
                try stderr.print("Error: Unable to find command for all labels in procfile '{s}'\n", .{procfileName});
            },
            else => {
                try stderr.print("Error: Extracting command from procfile '{s}'\n", .{@errorName(err)});
            },
        }
        return 1;
    };

    var runner = try MultiProcessRunner.initCapacity(alloc, commands.items.len);
    if (res.args.debug > 0) {
        runner.debug = true;
    }
    for (0..commands.items.len) |i| {
        try runner.addProcessAssumeCapacity(res.positionals[i], commands.items[i]);
    }
    try runner.run();

    return 0;
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
