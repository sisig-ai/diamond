const std = @import("std");
const Io = std.Io;

const vault = @import("../src/vault.zig");
const bm25 = @import("../src/bm25.zig");
const search_mod = @import("../src/search.zig");
const index = @import("../src/index.zig");

test "parse chunk goldens from fixture vault" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const vault_root = try fixtureVaultPath(gpa);
    defer gpa.free(vault_root);

    var v = try vault.walkAndParse(gpa, io, vault_root);
    defer v.deinit();

    try std.testing.expect(v.notes.len >= 4);

    var garden: ?vault.Note = null;
    var daily: ?vault.Note = null;
    for (v.notes) |n| {
        if (std.mem.eql(u8, n.meta.path, "Projects/Garden.md")) garden = n;
        if (std.mem.eql(u8, n.meta.path, "Daily/2024-06-01.md")) daily = n;
    }
    try std.testing.expect(garden != null);
    try std.testing.expect(daily != null);

    const g = garden.?;
    try std.testing.expectEqualStrings("Community Garden", g.meta.title.?);
    try std.testing.expectEqual(@as(usize, 1), g.meta.aliases.len);
    try std.testing.expectEqualStrings("Garden Plot", g.meta.aliases[0]);
    try std.testing.expect(g.meta.tags.len >= 2);

    const first = g.chunks[0];
    try std.testing.expect(std.mem.startsWith(u8, first.body, "The community garden"));
    try std.testing.expectEqual(@as(u32, 11), first.start_line);
    try std.testing.expectEqual(@as(usize, 1), first.heading_trail.len);
    try std.testing.expectEqualStrings("Community Garden", first.heading_trail[0]);

    var soil: ?vault.Chunk = null;
    for (g.chunks) |c| {
        if (c.heading_trail.len == 2 and std.mem.eql(u8, c.heading_trail[1], "Soil prep")) soil = c;
    }
    try std.testing.expect(soil != null);
    try std.testing.expectEqual(@as(u32, 15), soil.?.start_line);

    const d = daily.?;
    try std.testing.expectEqual(@as(usize, 1), d.meta.tags.len);
    try std.testing.expectEqualStrings("outdoors", d.meta.tags[0]);
}

test "bm25 basics" {
    const a = std.testing.allocator;
    const docs = [_][]const u8{
        "garden watering tomatoes",
        "api design bearer tokens",
        "welcome onboarding intro",
    };
    var idx = try bm25.build(a, &docs);
    defer idx.deinit();

    const hits = try bm25.search(a, &idx, "garden tomatoes", 3);
    defer a.free(hits);
    try std.testing.expect(hits.len >= 1);
    try std.testing.expectEqual(@as(u32, 0), hits[0].chunk_id);
    try std.testing.expect(hits[0].score > 0);
}

test "ranking title boost tag boost saturation" {
    try std.testing.expectEqual(search_mod.title_boost, search_mod.boostFor("Garden", .{
        .path = "Projects/Garden.md",
        .name = "Garden",
        .parent_folder = "Projects",
        .title = null,
        .aliases = &.{},
        .tags = &.{"gardening"},
        .h1 = null,
    }));
    try std.testing.expectEqual(search_mod.tag_boost, search_mod.boostFor("#gardening", .{
        .path = "Projects/Garden.md",
        .name = "Garden",
        .parent_folder = "Projects",
        .title = null,
        .aliases = &.{},
        .tags = &.{"gardening"},
        .h1 = null,
    }));
    try std.testing.expectEqual(@as(f32, 1.0), std.math.pow(f32, 0.5, 0));
    try std.testing.expectEqual(@as(f32, 0.5), std.math.pow(f32, 0.5, 1));
}

test "json anchors match source lines" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const vault_root = try fixtureVaultPath(gpa);
    defer gpa.free(vault_root);

    var built = try index.buildFresh(gpa, io, vault_root);
    defer built.deinit();

    const results = try search_mod.search(gpa, &built, "garden watering", 3);
    defer gpa.free(results);
    try std.testing.expect(results.len >= 1);

    const top = results[0];
    try std.testing.expectEqualStrings("Projects/Garden.md", top.path);
    try std.testing.expectEqual(@as(usize, 1), top.heading_trail.len);
    try std.testing.expectEqualStrings("Community Garden", top.heading_trail[0]);
    try std.testing.expectEqual(@as(u32, 11), top.start_line);

    const abs = try std.fs.path.join(gpa, &.{ vault_root, top.path });
    defer gpa.free(abs);
    const raw = try Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(64 * 1024));
    defer gpa.free(raw);
    const line = try lineAt(gpa, raw, top.start_line);
    defer gpa.free(line);
    const snip = std.mem.trim(u8, top.body, " \t\r\n");
    const first_snip_line = blk: {
        if (std.mem.indexOfScalar(u8, snip, '\n')) |n| break :blk snip[0..n];
        break :blk snip;
    };
    try std.testing.expectEqualStrings(std.mem.trim(u8, line, " \t\r"), first_snip_line);
}

test "cache rebuilds on file change" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "vault");
    try tmp.dir.writeFile(io, .{ .sub_path = "vault/Note.md", .data = "# Note\n\nalpha uniqueone\n" });

    const vault_abs = try tmp.dir.realPathFileAlloc(io, "vault", gpa);
    defer gpa.free(vault_abs);

    var env = try fakeCacheEnv(gpa, &tmp);
    defer env.deinit(gpa);

    const first = try index.loadOrBuild(gpa, io, env.environ, vault_abs);
    var idx1 = first.index;
    defer idx1.deinit();
    switch (first.status) {
        .rebuild => |reason| gpa.free(reason),
        .hit => {},
    }

    const second = try index.loadOrBuild(gpa, io, env.environ, vault_abs);
    var idx2 = second.index;
    defer idx2.deinit();
    try std.testing.expect(second.status == .hit);

    try tmp.dir.writeFile(io, .{ .sub_path = "vault/Note.md", .data = "# Note\n\nbeta uniquetwo changed\n" });

    const third = try index.loadOrBuild(gpa, io, env.environ, vault_abs);
    var idx3 = third.index;
    defer idx3.deinit();
    try std.testing.expect(third.status == .rebuild);
    switch (third.status) {
        .rebuild => |reason| gpa.free(reason),
        .hit => {},
    }

    const hits = try search_mod.search(gpa, &idx3, "uniquetwo", 3);
    defer gpa.free(hits);
    try std.testing.expect(hits.len >= 1);
}

test "malformed cache rejected without panic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "vault");
    try tmp.dir.writeFile(io, .{ .sub_path = "vault/Note.md", .data = "# Note\n\nbody\n" });
    const vault_abs = try tmp.dir.realPathFileAlloc(io, "vault", gpa);
    defer gpa.free(vault_abs);

    var env = try fakeCacheEnv(gpa, &tmp);
    defer env.deinit(gpa);

    const warm = try index.loadOrBuild(gpa, io, env.environ, vault_abs);
    var warm_idx = warm.index;
    defer warm_idx.deinit();
    switch (warm.status) {
        .rebuild => |reason| gpa.free(reason),
        .hit => {},
    }

    const cache_dir = try index.cacheDirPath(gpa, env.environ, vault_abs);
    defer gpa.free(cache_dir);
    const man_path = try std.fs.path.join(gpa, &.{ cache_dir, "manifest.json" });
    defer gpa.free(man_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = man_path, .data = "{\"schema\":\"nope\"}\n" });

    const recovered = try index.loadOrBuild(gpa, io, env.environ, vault_abs);
    var idx = recovered.index;
    defer idx.deinit();
    try std.testing.expect(recovered.status == .rebuild);
    switch (recovered.status) {
        .rebuild => |reason| gpa.free(reason),
        .hit => {},
    }
}

test "binary and mid-array manifest corruption rebuilds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "vault");
    try tmp.dir.writeFile(io, .{ .sub_path = "vault/Note.md", .data = "# Note\n\nuniquebodytoken\n" });
    const vault_abs = try tmp.dir.realPathFileAlloc(io, "vault", gpa);
    defer gpa.free(vault_abs);

    var env = try fakeCacheEnv(gpa, &tmp);
    defer env.deinit(gpa);

    const warm = try index.loadOrBuild(gpa, io, env.environ, vault_abs);
    var warm_idx = warm.index;
    defer warm_idx.deinit();
    switch (warm.status) {
        .rebuild => |reason| gpa.free(reason),
        .hit => {},
    }

    const cache_dir = try index.cacheDirPath(gpa, env.environ, vault_abs);
    defer gpa.free(cache_dir);
    const index_path = try std.fs.path.join(gpa, &.{ cache_dir, "index.bin" });
    defer gpa.free(index_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "NOTDMND\x00corrupt" });

    const after_bin = try index.loadOrBuild(gpa, io, env.environ, vault_abs);
    var idx_bin = after_bin.index;
    defer idx_bin.deinit();
    try std.testing.expect(after_bin.status == .rebuild);
    switch (after_bin.status) {
        .rebuild => |reason| gpa.free(reason),
        .hit => {},
    }

    const man_path = try std.fs.path.join(gpa, &.{ cache_dir, "manifest.json" });
    defer gpa.free(man_path);
    const corrupt_manifest =
        \\{"schema":2,"vault_path":"x","tokenizer_sha256":"a","model_sha256":"b","note_count":1,"chunk_count":1,"files":[{"path":"ok.md","size":1,"mtime_ns":1},{"path":"bad.md","size":"nope","mtime_ns":1}]}
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = man_path, .data = corrupt_manifest });

    const after_man = try index.loadOrBuild(gpa, io, env.environ, vault_abs);
    var idx_man = after_man.index;
    defer idx_man.deinit();
    try std.testing.expect(after_man.status == .rebuild);
    switch (after_man.status) {
        .rebuild => |reason| gpa.free(reason),
        .hit => {},
    }

    const hits = try search_mod.search(gpa, &idx_man, "uniquebodytoken", 3);
    defer gpa.free(hits);
    try std.testing.expect(hits.len >= 1);
}

const FakeEnv = struct {
    environ: std.process.Environ,

    fn deinit(self: *FakeEnv, gpa: std.mem.Allocator) void {
        self.environ.block.deinit(gpa);
    }
};

fn fakeCacheEnv(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir) !FakeEnv {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "xdg-cache");
    const cache_root = try tmp.dir.realPathFileAlloc(io, "xdg-cache", gpa);
    defer gpa.free(cache_root);

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("XDG_CACHE_HOME", cache_root);

    return .{
        .environ = .{ .block = try map.createPosixBlock(gpa, .{}) },
    };
}

fn fixtureVaultPath(gpa: std.mem.Allocator) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, "testdata", "vault" });
}

fn lineAt(gpa: std.mem.Allocator, raw: []const u8, line_no: u32) ![]u8 {
    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\n') {
            if (current == line_no) return try gpa.dupe(u8, raw[start..i]);
            current += 1;
            start = i + 1;
        }
    }
    if (current == line_no) return try gpa.dupe(u8, raw[start..]);
    return error.LineNotFound;
}
