const std = @import("std");
const Io = std.Io;

const vault = @import("vault.zig");
const embed = @import("embed.zig");
const bm25 = @import("bm25.zig");
const index = @import("index.zig");
const search_mod = @import("search.zig");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();

    _ = args.next(); // argv0

    var vault_path: ?[]const u8 = null;
    var top_k: usize = 5;
    var json_out = false;
    var query: ?[]const u8 = null;
    var saw_ask = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "ask")) {
            saw_ask = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--vault")) {
            vault_path = args.next() orelse {
                std.debug.print("usage: diamond ask --vault PATH QUERY [--top-k N] [--json]\n", .{});
                std.process.exit(2);
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--top-k")) {
            const v = args.next() orelse {
                std.debug.print("--top-k requires a value\n", .{});
                std.process.exit(2);
            };
            top_k = std.fmt.parseInt(usize, v, 10) catch {
                std.debug.print("invalid --top-k\n", .{});
                std.process.exit(2);
            };
            if (top_k < 1 or top_k > 50) {
                std.debug.print("--top-k must be 1..50\n", .{});
                std.process.exit(2);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json_out = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
        if (query != null) {
            std.debug.print("unexpected argument: {s}\n", .{arg});
            std.process.exit(2);
        }
        query = arg;
    }

    if (!saw_ask or vault_path == null or query == null or query.?.len == 0) {
        std.debug.print("usage: diamond ask --vault PATH QUERY [--top-k N] [--json]\n", .{});
        std.process.exit(2);
    }

    const canonical = try canonicalize(gpa, io, vault_path.?);
    defer gpa.free(canonical);

    const t0 = std.Io.Clock.Timestamp.now(io, .real);
    const loaded = try index.loadOrBuild(gpa, io, init.minimal.environ, canonical);
    var idx = loaded.index;
    defer idx.deinit();

    switch (loaded.status) {
        .hit => {},
        .rebuild => |reason| {
            const t1 = std.Io.Clock.Timestamp.now(io, .real);
            const elapsed_ms = t0.durationTo(t1).raw.toMilliseconds();
            std.debug.print("rebuilding index ({s}) in {d}ms\n", .{ reason, elapsed_ms });
            gpa.free(reason);
        },
    }

    const results = try search_mod.search(gpa, &idx, query.?, top_k);
    defer gpa.free(results);

    if (json_out) {
        try writeJson(io, results);
    } else {
        try writeHuman(io, results);
    }
}

fn canonicalize(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch {
        if (std.fs.path.isAbsolute(path)) return try gpa.dupe(u8, path);
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        return std.fs.path.join(gpa, &.{ cwd, path });
    };
    defer dir.close(io);
    const n = try dir.realPath(io, &buf);
    return try gpa.dupe(u8, buf[0..n]);
}

fn writeHuman(io: Io, results: []const search_mod.Result) !void {
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    if (results.len == 0) {
        try w.writeAll("(no results)\n");
        try w.flush();
        return;
    }
    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll("\n");
        try w.print("{s}\n", .{r.path});
        if (r.breadcrumb.len > 0) try w.print("  {s}\n", .{r.breadcrumb});
        try w.print("  lines {d}-{d}\n", .{ r.start_line, r.end_line });
        const snippet = snippetOf(r.body, 200);
        try w.print("  {s}\n", .{snippet});
    }
    try w.flush();
}

fn writeJson(io: Io, results: []const search_mod.Result) !void {
    var buf: [8192]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("{\"results\":[");
    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"path\":");
        try jsonString(w, r.path);
        try w.writeAll(",\"breadcrumb\":");
        try jsonString(w, r.breadcrumb);
        try w.print(",\"start_line\":{d},\"end_line\":{d},\"score\":{d:.6},\"snippet\":", .{
            r.start_line,
            r.end_line,
            r.score,
        });
        try jsonString(w, snippetOf(r.body, 240));
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
    try w.flush();
}

fn jsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn snippetOf(body: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len <= max) return trimmed;
    return trimmed[0..max];
}

// Keep modules referenced for `zig build test`
comptime {
    _ = vault;
    _ = embed;
    _ = bm25;
    _ = index;
    _ = search_mod;
}
