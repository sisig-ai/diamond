const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");

const vault = @import("vault.zig");
const embed = @import("embed.zig");
const bm25 = @import("bm25.zig");

pub const schema_version: u32 = 2;
pub const magic: [4]u8 = "DMND".*;

pub const FileSnapshot = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i128,
};

pub const Manifest = struct {
    schema: u32,
    vault_path: []const u8,
    tokenizer_sha256: []const u8,
    model_sha256: []const u8,
    note_count: u32,
    chunk_count: u32,
    files: []FileSnapshot,
};

pub const StoredNote = struct {
    path: []const u8,
    name: []const u8,
    parent_folder: []const u8,
    title: ?[]const u8,
    aliases: []const []const u8,
    tags: []const []const u8,
    h1: ?[]const u8,
};

pub const StoredChunk = struct {
    note_id: u32,
    heading_trail: []const []const u8,
    body: []const u8,
    start_line: u32,
    end_line: u32,
};

pub const LoadedIndex = struct {
    notes: []StoredNote,
    chunks: []StoredChunk,
    vectors: []f32, // chunks.len * 256
    bm25: bm25.Index,
    arena: std.heap.ArenaAllocator,
    /// Optional mmap / file bytes owned for vectors if borrowed — unused when arena-copied.
    file_bytes: ?[]align(8) u8 = null,
    gpa: Allocator,

    pub fn deinit(self: *LoadedIndex) void {
        self.bm25.deinit();
        if (self.file_bytes) |b| self.gpa.free(b);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn vector(self: *const LoadedIndex, chunk_id: u32) []const f32 {
        const off = @as(usize, chunk_id) * embed.dim;
        return self.vectors[off .. off + embed.dim];
    }
};

pub const CacheStatus = union(enum) {
    hit: void,
    rebuild: []const u8, // reason
};

pub fn vaultCacheKey(canonical_vault: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(canonical_vault);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn cacheDirPath(gpa: Allocator, environ: std.process.Environ, canonical_vault: []const u8) ![]u8 {
    const key = vaultCacheKey(canonical_vault);
    const hex = std.fmt.bytesToHex(key, .lower);

    const base = try cacheBase(gpa, environ);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, &hex });
}

fn cacheBase(gpa: Allocator, environ: std.process.Environ) ![]u8 {
    if (builtin.os.tag == .macos) {
        const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.NoHome;
        return std.fs.path.join(gpa, &.{ home, "Library", "Caches", "diamond" });
    }
    if (std.process.Environ.getPosix(environ, "XDG_CACHE_HOME")) |xdg| {
        return std.fs.path.join(gpa, &.{ xdg, "diamond" });
    }
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".cache", "diamond" });
}

pub fn ensureCacheDir(io: Io, dir_path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dir_path);
}

pub fn openLock(io: Io, cache_dir: []const u8) !Io.File {
    const lock_path = try std.fs.path.join(std.heap.page_allocator, &.{ cache_dir, "lock" });
    defer std.heap.page_allocator.free(lock_path);
    // create empty lock file if needed
    {
        const f = Io.Dir.cwd().createFile(io, lock_path, .{ .exclusive = false }) catch |err| switch (err) {
            error.PathAlreadyExists => null,
            else => return err,
        };
        if (f) |file| file.close(io);
    }
    return Io.Dir.cwd().openFile(io, lock_path, .{
        .mode = .read_write,
        .lock = .exclusive,
    });
}

pub fn snapshotVaultFiles(gpa: Allocator, io: Io, vault_root: []const u8, v: *const vault.Vault) ![]FileSnapshot {
    var out: std.ArrayList(FileSnapshot) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s.path);
        out.deinit(gpa);
    }
    for (v.notes) |n| {
        const abs = try std.fs.path.join(gpa, &.{ vault_root, n.meta.path });
        defer gpa.free(abs);
        const st = Io.Dir.cwd().statFile(io, abs, .{}) catch return error.IoFailure;
        const mtime_ns: i128 = st.mtime.nanoseconds;
        try out.append(gpa, .{
            .path = try gpa.dupe(u8, n.meta.path),
            .size = st.size,
            .mtime_ns = mtime_ns,
        });
    }
    return try out.toOwnedSlice(gpa);
}

pub fn freeSnapshot(gpa: Allocator, snaps: []FileSnapshot) void {
    for (snaps) |s| gpa.free(s.path);
    gpa.free(snaps);
}

pub fn loadOrBuild(
    gpa: Allocator,
    io: Io,
    environ: std.process.Environ,
    vault_root: []const u8,
) !struct { index: LoadedIndex, status: CacheStatus } {
    const cache_dir = try cacheDirPath(gpa, environ, vault_root);
    defer gpa.free(cache_dir);
    try ensureCacheDir(io, cache_dir);

    var lock = try openLock(io, cache_dir);
    defer lock.close(io);

    const manifest_path = try std.fs.path.join(gpa, &.{ cache_dir, "manifest.json" });
    defer gpa.free(manifest_path);
    const index_path = try std.fs.path.join(gpa, &.{ cache_dir, "index.bin" });
    defer gpa.free(index_path);

    // Probe existing cache
    if (readManifest(gpa, io, manifest_path)) |man| {
        defer freeManifest(gpa, man);
        if (try manifestMatches(gpa, io, vault_root, man)) {
            if (loadIndexBin(gpa, io, index_path)) |idx| {
                return .{ .index = idx, .status = .hit };
            } else |_| {}
        }
    } else |_| {}

    // Rebuild
    const reason = try diagnoseRebuildReason(gpa, io, vault_root, manifest_path, index_path);
    var built = try buildFresh(gpa, io, vault_root);
    errdefer built.deinit();

    try writeAtomic(gpa, io, cache_dir, &built, vault_root);
    return .{ .index = built, .status = .{ .rebuild = reason } };
}

fn diagnoseRebuildReason(gpa: Allocator, io: Io, vault_root: []const u8, manifest_path: []const u8, index_path: []const u8) ![]const u8 {
    _ = vault_root;
    Io.Dir.cwd().access(io, manifest_path, .{}) catch return try gpa.dupe(u8, "missing manifest");
    Io.Dir.cwd().access(io, index_path, .{}) catch return try gpa.dupe(u8, "missing index.bin");
    return try gpa.dupe(u8, "stale or incompatible cache");
}

fn manifestMatches(gpa: Allocator, io: Io, vault_root: []const u8, man: Manifest) !bool {
    if (man.schema != schema_version) return false;
    if (!std.mem.eql(u8, man.tokenizer_sha256, embed.tokenizer_sha256_hex)) return false;
    if (!std.mem.eql(u8, man.model_sha256, embed.model_sha256_hex)) return false;
    if (!std.mem.eql(u8, man.vault_path, vault_root)) return false;

    // Collect current *.md snapshot (paths sorted) via walk only — no parse.
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    var root_dir = Io.Dir.openDirAbsolute(io, vault_root, .{ .iterate = true, .follow_symlinks = false }) catch return false;
    defer root_dir.close(io);
    var walker = root_dir.walk(gpa) catch return false;
    defer walker.deinit();
    while (true) {
        const entry = (walker.next(io) catch return false) orelse break;
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.basename, ".md")) continue;
        if (pathSkipped(entry.path)) continue;
        try paths.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);

    if (paths.items.len != man.files.len) return false;
    if (paths.items.len != man.note_count) return false;

    for (paths.items, man.files) |rel, snap| {
        if (!std.mem.eql(u8, rel, snap.path)) return false;
        const abs = try std.fs.path.join(gpa, &.{ vault_root, rel });
        defer gpa.free(abs);
        const st = Io.Dir.cwd().statFile(io, abs, .{}) catch return false;
        if (st.size != snap.size) return false;
        if (st.mtime.nanoseconds != snap.mtime_ns) return false;
    }
    return true;
}

fn pathSkipped(path: []const u8) bool {
    const skip = [_][]const u8{ ".obsidian", ".trash", ".git", "node_modules" };
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        for (skip) |s| if (std.mem.eql(u8, comp, s)) return true;
    }
    return false;
}

pub fn buildFresh(gpa: Allocator, io: Io, vault_root: []const u8) !LoadedIndex {
    var v = try vault.walkAndParse(gpa, io, vault_root);
    defer v.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var notes = try a.alloc(StoredNote, v.notes.len);
    var total_chunks: usize = 0;
    for (v.notes) |n| total_chunks += n.chunks.len;
    var chunks = try a.alloc(StoredChunk, total_chunks);

    var sparse_docs = try gpa.alloc([]const u8, total_chunks);
    defer {
        for (sparse_docs) |d| gpa.free(d);
        gpa.free(sparse_docs);
    }

    var embedder = try embed.Embedder.init(gpa);
    defer embedder.deinit();

    var vectors = try a.alloc(f32, total_chunks * embed.dim);

    var ci: usize = 0;
    for (v.notes, 0..) |n, ni| {
        notes[ni] = .{
            .path = try a.dupe(u8, n.meta.path),
            .name = try a.dupe(u8, n.meta.name),
            .parent_folder = try a.dupe(u8, n.meta.parent_folder),
            .title = if (n.meta.title) |t| try a.dupe(u8, t) else null,
            .aliases = try dupeStrings(a, n.meta.aliases),
            .tags = try dupeStrings(a, n.meta.tags),
            .h1 = if (n.meta.h1) |h| try a.dupe(u8, h) else null,
        };
        for (n.chunks) |ch| {
            chunks[ci] = .{
                .note_id = @intCast(ni),
                .heading_trail = try dupeStrings(a, ch.heading_trail),
                .body = try a.dupe(u8, ch.body),
                .start_line = ch.start_line,
                .end_line = ch.end_line,
            };
            const dense = try embed.denseSearchText(gpa, n.meta, ch);
            defer gpa.free(dense);
            const sparse = try embed.sparseSearchText(gpa, n.meta, ch);
            sparse_docs[ci] = sparse;

            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            try embedder.embed(scratch.allocator(), dense, vectors[ci * embed.dim ..][0..embed.dim]);
            ci += 1;
        }
    }

    const bm = try bm25.build(gpa, sparse_docs);

    return .{
        .notes = notes,
        .chunks = chunks,
        .vectors = vectors,
        .bm25 = bm,
        .arena = arena,
        .gpa = gpa,
    };
}

fn dupeStrings(a: Allocator, ss: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, ss.len);
    for (ss, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}

fn writeAtomic(gpa: Allocator, io: Io, cache_dir: []const u8, idx: *const LoadedIndex, vault_root: []const u8) !void {
    const tmp_dir = try std.fs.path.join(gpa, &.{ cache_dir, "tmp-build" });
    defer gpa.free(tmp_dir);
    Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp_dir);

    const tmp_index = try std.fs.path.join(gpa, &.{ tmp_dir, "index.bin" });
    defer gpa.free(tmp_index);
    const tmp_manifest = try std.fs.path.join(gpa, &.{ tmp_dir, "manifest.json" });
    defer gpa.free(tmp_manifest);

    try writeIndexBin(gpa, io, tmp_index, idx);
    try writeManifestFile(gpa, io, tmp_manifest, idx, vault_root);

    const final_index = try std.fs.path.join(gpa, &.{ cache_dir, "index.bin" });
    defer gpa.free(final_index);
    const final_manifest = try std.fs.path.join(gpa, &.{ cache_dir, "manifest.json" });
    defer gpa.free(final_manifest);

    // Atomic replace: rename index then manifest
    try Io.Dir.renameAbsolute(tmp_index, final_index, io);
    try Io.Dir.renameAbsolute(tmp_manifest, final_manifest, io);
    Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
}

fn writeManifestFile(gpa: Allocator, io: Io, path: []const u8, idx: *const LoadedIndex, vault_root: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\n");
    try w.print("  \"schema\": {d},\n", .{schema_version});
    try w.print("  \"vault_path\": ", .{});
    try writeJsonString(w, vault_root);
    try w.writeAll(",\n");
    try w.print("  \"tokenizer_sha256\": \"{s}\",\n", .{embed.tokenizer_sha256_hex});
    try w.print("  \"model_sha256\": \"{s}\",\n", .{embed.model_sha256_hex});
    try w.print("  \"note_count\": {d},\n", .{idx.notes.len});
    try w.print("  \"chunk_count\": {d},\n", .{idx.chunks.len});
    try w.writeAll("  \"files\": [\n");

    for (idx.notes, 0..) |n, i| {
        const abs = try std.fs.path.join(gpa, &.{ vault_root, n.path });
        defer gpa.free(abs);
        const st = try Io.Dir.cwd().statFile(io, abs, .{});
        try w.writeAll("    {\"path\": ");
        try writeJsonString(w, n.path);
        try w.print(", \"size\": {d}, \"mtime_ns\": {d}", .{ st.size, @as(i64, @intCast(st.mtime.nanoseconds)) });
        try w.writeAll("}");
        if (i + 1 < idx.notes.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ]\n}\n");

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

const ManifestOwned = Manifest;

fn readManifest(gpa: Allocator, io: Io, path: []const u8) !Manifest {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.BadManifest;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadManifest;
    const obj = root.object;

    const schema = try jsonU32(obj.get("schema") orelse return error.BadManifest);
    const vault_path = try jsonStringDupe(gpa, obj.get("vault_path") orelse return error.BadManifest);
    errdefer gpa.free(vault_path);
    const tok = try jsonStringDupe(gpa, obj.get("tokenizer_sha256") orelse return error.BadManifest);
    errdefer gpa.free(tok);
    const mod = try jsonStringDupe(gpa, obj.get("model_sha256") orelse return error.BadManifest);
    errdefer gpa.free(mod);
    const note_count = try jsonU32(obj.get("note_count") orelse return error.BadManifest);
    const chunk_count = try jsonU32(obj.get("chunk_count") orelse return error.BadManifest);

    const files_node = obj.get("files") orelse return error.BadManifest;
    if (files_node != .array) return error.BadManifest;
    const files_val = files_node.array;
    var files = try gpa.alloc(FileSnapshot, files_val.items.len);
    var nfiles: usize = 0;
    errdefer {
        for (files[0..nfiles]) |f| gpa.free(f.path);
        gpa.free(files);
    }
    for (files_val.items, 0..) |fv, i| {
        if (fv != .object) return error.BadManifest;
        const fo = fv.object;
        const fpath = try jsonStringDupe(gpa, fo.get("path") orelse return error.BadManifest);
        const size = jsonU64(fo.get("size") orelse return error.BadManifest) catch |e| {
            gpa.free(fpath);
            return e;
        };
        const mtime_ns = jsonI128(fo.get("mtime_ns") orelse return error.BadManifest) catch |e| {
            gpa.free(fpath);
            return e;
        };
        files[i] = .{
            .path = fpath,
            .size = size,
            .mtime_ns = mtime_ns,
        };
        nfiles = i + 1;
    }

    return .{
        .schema = schema,
        .vault_path = vault_path,
        .tokenizer_sha256 = tok,
        .model_sha256 = mod,
        .note_count = note_count,
        .chunk_count = chunk_count,
        .files = files,
    };
}

fn jsonStringDupe(gpa: Allocator, v: std.json.Value) ![]u8 {
    if (v != .string) return error.BadManifest;
    return try gpa.dupe(u8, v.string);
}

fn jsonU32(v: std.json.Value) !u32 {
    if (v != .integer) return error.BadManifest;
    if (v.integer < 0 or v.integer > std.math.maxInt(u32)) return error.BadManifest;
    return @intCast(v.integer);
}

fn jsonU64(v: std.json.Value) !u64 {
    if (v != .integer) return error.BadManifest;
    if (v.integer < 0) return error.BadManifest;
    return @intCast(v.integer);
}

fn jsonI128(v: std.json.Value) !i128 {
    if (v != .integer) return error.BadManifest;
    return v.integer;
}

fn freeManifest(gpa: Allocator, man: Manifest) void {
    gpa.free(man.vault_path);
    gpa.free(man.tokenizer_sha256);
    gpa.free(man.model_sha256);
    for (man.files) |f| gpa.free(f.path);
    gpa.free(man.files);
}

// ── binary index format ────────────────────────────────────────────
// magic[4] version:u32 note_count:u32 chunk_count:u32
// strings blob, then notes, chunks, vectors, bm25

fn writeIndexBin(gpa: Allocator, io: Io, path: []const u8, idx: *const LoadedIndex) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w = &aw.writer;

    try w.writeAll(&magic);
    try w.writeInt(u32, schema_version, .little);
    try w.writeInt(u32, @intCast(idx.notes.len), .little);
    try w.writeInt(u32, @intCast(idx.chunks.len), .little);

    // Collect strings
    var strs: std.ArrayList([]const u8) = .empty;
    defer strs.deinit(gpa);
    var str_index: std.StringHashMapUnmanaged(u32) = .empty;
    defer str_index.deinit(gpa);

    const intern = struct {
        fn call(g: Allocator, list: *std.ArrayList([]const u8), map: *std.StringHashMapUnmanaged(u32), s: []const u8) !u32 {
            const gop = try map.getOrPut(g, s);
            if (gop.found_existing) return gop.value_ptr.*;
            const id: u32 = @intCast(list.items.len);
            const owned = try g.dupe(u8, s);
            try list.append(g, owned);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = id;
            return id;
        }
    }.call;

    // We'll rewrite with proper string table — first pass build ids in side structures
    var note_recs: std.ArrayList(NoteRec) = .empty;
    defer note_recs.deinit(gpa);
    for (idx.notes) |n| {
        const path_id = try intern(gpa, &strs, &str_index, n.path);
        const name_id = try intern(gpa, &strs, &str_index, n.name);
        const parent_id = try intern(gpa, &strs, &str_index, n.parent_folder);
        const title_id: u32 = if (n.title) |t| try intern(gpa, &strs, &str_index, t) else std.math.maxInt(u32);
        const h1_id: u32 = if (n.h1) |h| try intern(gpa, &strs, &str_index, h) else std.math.maxInt(u32);
        var alias_ids = try gpa.alloc(u32, n.aliases.len);
        for (n.aliases, 0..) |al, i| alias_ids[i] = try intern(gpa, &strs, &str_index, al);
        var tag_ids = try gpa.alloc(u32, n.tags.len);
        for (n.tags, 0..) |tg, i| tag_ids[i] = try intern(gpa, &strs, &str_index, tg);
        try note_recs.append(gpa, .{
            .path_id = path_id,
            .name_id = name_id,
            .parent_id = parent_id,
            .title_id = title_id,
            .h1_id = h1_id,
            .alias_ids = alias_ids,
            .tag_ids = tag_ids,
        });
    }
    defer for (note_recs.items) |nr| {
        gpa.free(nr.alias_ids);
        gpa.free(nr.tag_ids);
    };

    var chunk_recs: std.ArrayList(ChunkRec) = .empty;
    defer chunk_recs.deinit(gpa);
    for (idx.chunks) |c| {
        var trail_ids = try gpa.alloc(u32, c.heading_trail.len);
        for (c.heading_trail, 0..) |h, i| trail_ids[i] = try intern(gpa, &strs, &str_index, h);
        try chunk_recs.append(gpa, .{
            .note_id = c.note_id,
            .trail_ids = trail_ids,
            .body_id = try intern(gpa, &strs, &str_index, c.body),
            .start_line = c.start_line,
            .end_line = c.end_line,
        });
    }
    defer for (chunk_recs.items) |cr| gpa.free(cr.trail_ids);

    // string table
    try w.writeInt(u32, @intCast(strs.items.len), .little);
    for (strs.items) |s| {
        try w.writeInt(u32, @intCast(s.len), .little);
        try w.writeAll(s);
    }
    for (strs.items) |s| gpa.free(s);

    for (note_recs.items) |nr| {
        try w.writeInt(u32, nr.path_id, .little);
        try w.writeInt(u32, nr.name_id, .little);
        try w.writeInt(u32, nr.parent_id, .little);
        try w.writeInt(u32, nr.title_id, .little);
        try w.writeInt(u32, nr.h1_id, .little);
        try w.writeInt(u32, @intCast(nr.alias_ids.len), .little);
        for (nr.alias_ids) |id| try w.writeInt(u32, id, .little);
        try w.writeInt(u32, @intCast(nr.tag_ids.len), .little);
        for (nr.tag_ids) |id| try w.writeInt(u32, id, .little);
    }

    for (chunk_recs.items) |cr| {
        try w.writeInt(u32, cr.note_id, .little);
        try w.writeInt(u32, @intCast(cr.trail_ids.len), .little);
        for (cr.trail_ids) |id| try w.writeInt(u32, id, .little);
        try w.writeInt(u32, cr.body_id, .little);
        try w.writeInt(u32, cr.start_line, .little);
        try w.writeInt(u32, cr.end_line, .little);
    }

    // vectors as raw f32 little-endian
    const vec_bytes = std.mem.sliceAsBytes(idx.vectors);
    try w.writeAll(vec_bytes);

    // bm25
    try w.writeInt(u32, idx.bm25.doc_count, .little);
    try w.writeInt(u32, @bitCast(idx.bm25.avgdl), .little);
    for (idx.bm25.doc_len) |dl| try w.writeInt(u32, dl, .little);
    try w.writeInt(u32, @intCast(idx.bm25.terms.len), .little);
    for (idx.bm25.terms) |t| {
        try w.writeInt(u32, @intCast(t.term.len), .little);
        try w.writeAll(t.term);
        try w.writeInt(u32, t.df, .little);
        try w.writeInt(u32, @intCast(t.postings.len), .little);
        for (t.postings) |p| {
            try w.writeInt(u32, p.chunk_id, .little);
            try w.writeInt(u32, p.tf, .little);
        }
    }

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

const NoteRec = struct {
    path_id: u32,
    name_id: u32,
    parent_id: u32,
    title_id: u32,
    h1_id: u32,
    alias_ids: []u32,
    tag_ids: []u32,
};

const ChunkRec = struct {
    note_id: u32,
    trail_ids: []u32,
    body_id: u32,
    start_line: u32,
    end_line: u32,
};

fn loadIndexBin(gpa: Allocator, io: Io, path: []const u8) !LoadedIndex {
    const bytes = try Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(512 * 1024 * 1024), .of(u64), null);
    errdefer gpa.free(bytes);

    var fbs: std.Io.Reader = .fixed(bytes);
    const r = &fbs;

    const mag = try r.takeArray(4);
    if (!std.mem.eql(u8, mag, &magic)) return error.BadIndex;

    const version = try r.takeInt(u32, .little);
    if (version != schema_version) return error.BadIndex;
    const note_count = try r.takeInt(u32, .little);
    const chunk_count = try r.takeInt(u32, .little);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const str_count = try r.takeInt(u32, .little);
    var strs = try a.alloc([]const u8, str_count);
    for (0..str_count) |i| {
        const len = try r.takeInt(u32, .little);
        const s = try a.alloc(u8, len);
        const got = r.take(len) catch return error.BadIndex;
        @memcpy(s, got);
        strs[i] = s;
    }

    const requireStr = struct {
        fn call(table: []const []const u8, id: u32) ![]const u8 {
            if (id >= table.len) return error.BadIndex;
            return table[id];
        }
    }.call;

    const optionalStr = struct {
        fn call(table: []const []const u8, id: u32) !?[]const u8 {
            if (id == std.math.maxInt(u32)) return null;
            if (id >= table.len) return error.BadIndex;
            return table[id];
        }
    }.call;

    var notes = try a.alloc(StoredNote, note_count);
    for (0..note_count) |i| {
        const path_id = try r.takeInt(u32, .little);
        const name_id = try r.takeInt(u32, .little);
        const parent_id = try r.takeInt(u32, .little);
        const title_id = try r.takeInt(u32, .little);
        const h1_id = try r.takeInt(u32, .little);
        const alias_n = try r.takeInt(u32, .little);
        var aliases = try a.alloc([]const u8, alias_n);
        for (0..alias_n) |j| aliases[j] = try requireStr(strs, try r.takeInt(u32, .little));
        const tag_n = try r.takeInt(u32, .little);
        var tags = try a.alloc([]const u8, tag_n);
        for (0..tag_n) |j| tags[j] = try requireStr(strs, try r.takeInt(u32, .little));
        notes[i] = .{
            .path = try requireStr(strs, path_id),
            .name = try requireStr(strs, name_id),
            .parent_folder = try requireStr(strs, parent_id),
            .title = try optionalStr(strs, title_id),
            .aliases = aliases,
            .tags = tags,
            .h1 = try optionalStr(strs, h1_id),
        };
    }

    var chunks = try a.alloc(StoredChunk, chunk_count);
    for (0..chunk_count) |i| {
        const note_id = try r.takeInt(u32, .little);
        if (note_id >= note_count) return error.BadIndex;
        const trail_n = try r.takeInt(u32, .little);
        var trail = try a.alloc([]const u8, trail_n);
        for (0..trail_n) |j| trail[j] = try requireStr(strs, try r.takeInt(u32, .little));
        const body_id = try r.takeInt(u32, .little);
        chunks[i] = .{
            .note_id = note_id,
            .heading_trail = trail,
            .body = try requireStr(strs, body_id),
            .start_line = try r.takeInt(u32, .little),
            .end_line = try r.takeInt(u32, .little),
        };
    }

    const vec_n = @as(usize, chunk_count) * embed.dim;
    const vectors = try a.alloc(f32, vec_n);
    const vec_bytes = std.mem.sliceAsBytes(vectors);
    {
        const got = r.take(vec_bytes.len) catch return error.BadIndex;
        @memcpy(vec_bytes, got);
    }

    const doc_count = try r.takeInt(u32, .little);
    if (doc_count != chunk_count) return error.BadIndex;
    const avgdl: f32 = @bitCast(try r.takeInt(u32, .little));
    var doc_len = try a.alloc(u32, doc_count);
    for (0..doc_count) |i| doc_len[i] = try r.takeInt(u32, .little);
    const term_count = try r.takeInt(u32, .little);

    var bm_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer bm_arena.deinit();
    const ba = bm_arena.allocator();
    var terms = try ba.alloc(bm25.TermEntry, term_count);
    var term_map: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer term_map.deinit(gpa);

    for (0..term_count) |i| {
        const tlen = try r.takeInt(u32, .little);
        const term = try ba.alloc(u8, tlen);
        {
            const got = r.take(tlen) catch return error.BadIndex;
            @memcpy(term, got);
        }
        const df = try r.takeInt(u32, .little);
        const pn = try r.takeInt(u32, .little);
        var postings = try ba.alloc(bm25.TermPosting, pn);
        for (0..pn) |j| {
            const chunk_id = try r.takeInt(u32, .little);
            if (chunk_id >= chunk_count) return error.BadIndex;
            postings[j] = .{
                .chunk_id = chunk_id,
                .tf = try r.takeInt(u32, .little),
            };
        }
        terms[i] = .{ .term = term, .df = df, .postings = postings };
        try term_map.put(gpa, term, @intCast(i));
    }

    gpa.free(bytes);

    return .{
        .notes = notes,
        .chunks = chunks,
        .vectors = vectors,
        .bm25 = .{
            .terms = terms,
            .term_map = term_map,
            .doc_len = doc_len,
            .avgdl = avgdl,
            .doc_count = doc_count,
            .arena = bm_arena,
        },
        .arena = arena,
        .gpa = gpa,
    };
}

test "cache key is stable" {
    const a = vaultCacheKey("/tmp/vault");
    const b = vaultCacheKey("/tmp/vault");
    try std.testing.expectEqualSlices(u8, &a, &b);
    const c = vaultCacheKey("/tmp/other");
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}
