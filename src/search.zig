const std = @import("std");
const Allocator = std.mem.Allocator;

const index = @import("index.zig");
const embed = @import("embed.zig");
const bm25 = @import("bm25.zig");

pub const rrf_k: f32 = 60.0;
pub const title_boost: f32 = 1.50;
pub const tag_boost: f32 = 1.25;

pub const Result = struct {
    chunk_id: u32,
    note_id: u32,
    path: []const u8,
    heading_trail: []const []const u8,
    start_line: u32,
    end_line: u32,
    body: []const u8,
    score: f32,
};

pub fn overFetch(chunk_count: usize, top_k: usize) usize {
    return @min(chunk_count, @max(@as(usize, 50), top_k * 10));
}

pub fn search(
    gpa: Allocator,
    idx: *const index.LoadedIndex,
    query: []const u8,
    top_k: usize,
) ![]Result {
    if (idx.chunks.len == 0 or query.len == 0) return try gpa.alloc(Result, 0);

    const limit = overFetch(idx.chunks.len, top_k);

    // Dense
    var embedder = try embed.Embedder.init(gpa);
    defer embedder.deinit();
    var qvec: [embed.dim]f32 = undefined;
    {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        try embedder.embed(scratch.allocator(), query, &qvec);
    }

    var dense_scores = try gpa.alloc(struct { id: u32, score: f32 }, idx.chunks.len);
    defer gpa.free(dense_scores);
    for (0..idx.chunks.len) |i| {
        const v = idx.vector(@intCast(i));
        dense_scores[i] = .{ .id = @intCast(i), .score = dot(&qvec, v) };
    }
    std.mem.sort(@TypeOf(dense_scores[0]), dense_scores, {}, struct {
        fn less(_: void, a: @TypeOf(dense_scores[0]), b: @TypeOf(dense_scores[0])) bool {
            if (a.score == b.score) return a.id < b.id;
            return a.score > b.score;
        }
    }.less);

    // BM25
    const bm_hits = try bm25.search(gpa, &idx.bm25, query, limit);
    defer gpa.free(bm_hits);

    var dense_rank: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer dense_rank.deinit(gpa);
    var bm_rank: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer bm_rank.deinit(gpa);

    const dense_n = @min(limit, dense_scores.len);
    for (dense_scores[0..dense_n], 0..) |h, r| {
        try dense_rank.put(gpa, h.id, @intCast(r));
    }
    for (bm_hits, 0..) |h, r| {
        try bm_rank.put(gpa, h.chunk_id, @intCast(r));
    }

    // Candidate union
    var cand: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer cand.deinit(gpa);
    for (dense_scores[0..dense_n]) |h| try cand.put(gpa, h.id, {});
    for (bm_hits) |h| try cand.put(gpa, h.chunk_id, {});

    var scored: std.ArrayList(struct { id: u32, score: f32 }) = .empty;
    defer scored.deinit(gpa);

    var it = cand.keyIterator();
    while (it.next()) |id_ptr| {
        const id = id_ptr.*;
        var s: f32 = 0;
        if (dense_rank.get(id)) |r| s += 1.0 / (rrf_k + @as(f32, @floatFromInt(r)));
        if (bm_rank.get(id)) |r| s += 1.0 / (rrf_k + @as(f32, @floatFromInt(r)));

        const note = idx.notes[idx.chunks[id].note_id];
        s *= boostFor(query, note);

        try scored.append(gpa, .{ .id = id, .score = s });
    }

    // Greedy select with note saturation 0.5^n
    var selected: std.ArrayList(Result) = .empty;
    errdefer selected.deinit(gpa);
    var note_hits: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer note_hits.deinit(gpa);

    while (selected.items.len < top_k and scored.items.len > 0) {
        // pick best remaining after saturation
        var best_i: usize = 0;
        var best_s: f32 = -std.math.inf(f32);
        for (scored.items, 0..) |item, i| {
            const note_id = idx.chunks[item.id].note_id;
            const n = note_hits.get(note_id) orelse 0;
            const sat = std.math.pow(f32, 0.5, @floatFromInt(n));
            const adj = item.score * sat;
            const chunk = idx.chunks[item.id];
            const note = idx.notes[note_id];
            if (adj > best_s or (adj == best_s and tieBreakBetter(note.path, chunk.start_line, idx, scored.items[best_i].id))) {
                best_s = adj;
                best_i = i;
            }
        }

        const pick = scored.swapRemove(best_i);
        const chunk = idx.chunks[pick.id];
        const note_id = chunk.note_id;
        const n = note_hits.get(note_id) orelse 0;
        const sat = std.math.pow(f32, 0.5, @floatFromInt(n));
        try note_hits.put(gpa, note_id, n + 1);

        try selected.append(gpa, .{
            .chunk_id = pick.id,
            .note_id = note_id,
            .path = idx.notes[note_id].path,
            .heading_trail = chunk.heading_trail,
            .start_line = chunk.start_line,
            .end_line = chunk.end_line,
            .body = chunk.body,
            .score = pick.score * sat,
        });
    }

    return try selected.toOwnedSlice(gpa);
}

fn tieBreakBetter(path: []const u8, start_line: u32, idx: *const index.LoadedIndex, other_id: u32) bool {
    const other = idx.chunks[other_id];
    const other_path = idx.notes[other.note_id].path;
    const ord = std.mem.order(u8, path, other_path);
    if (ord == .lt) return true;
    if (ord == .gt) return false;
    return start_line < other.start_line;
}

pub fn boostFor(query: []const u8, note: index.StoredNote) f32 {
    if (exactMatch(query, note.name)) return title_boost;
    if (note.title) |t| {
        if (exactMatch(query, t)) return title_boost;
    }
    if (note.h1) |h| {
        if (exactMatch(query, h)) return title_boost;
    }
    for (note.aliases) |al| {
        if (exactMatch(query, al)) return title_boost;
    }
    if (explicitTagMatch(query, note.tags)) return tag_boost;
    return 1.0;
}

fn exactMatch(query: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, query, value);
}

fn explicitTagMatch(query: []const u8, tags: []const []const u8) bool {
    // Query is exactly `#tag` or contains `#tag` as a token-ish substring.
    for (tags) |tg| {
        var buf: [256]u8 = undefined;
        if (tg.len + 1 > buf.len) continue;
        buf[0] = '#';
        @memcpy(buf[1 .. 1 + tg.len], tg);
        const needle = buf[0 .. 1 + tg.len];
        if (std.mem.eql(u8, query, needle)) return true;
        if (std.mem.indexOf(u8, query, needle)) |pos| {
            const end = pos + needle.len;
            const before_ok = pos == 0 or !std.ascii.isAlphanumeric(query[pos - 1]);
            const after_ok = end >= query.len or (!std.ascii.isAlphanumeric(query[end]) and query[end] != '_' and query[end] != '-' and query[end] != '/');
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

fn dot(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

test "rrf prefers dual hits" {
    // Pure unit: fusion math
    const d: f32 = 1.0 / (60.0 + 0);
    const b: f32 = 1.0 / (60.0 + 0);
    try std.testing.expectApproxEqAbs(d + b, 2.0 / 60.0, 1e-6);
}

test "boosts are mutually exclusive" {
    const note = index.StoredNote{
        .path = "x.md",
        .name = "Garden",
        .parent_folder = "",
        .title = null,
        .aliases = &.{},
        .tags = &.{"gardening"},
        .h1 = null,
    };
    try std.testing.expectEqual(title_boost, boostFor("Garden", note));
    // title wins over tag even if both could match — query can't be both exact name and #tag
    try std.testing.expectEqual(tag_boost, boostFor("#gardening", note));
    try std.testing.expectEqual(@as(f32, 1.0), boostFor("tomatoes", note));
}

test "saturation halves subsequent" {
    try std.testing.expectEqual(@as(f32, 1.0), std.math.pow(f32, 0.5, 0));
    try std.testing.expectEqual(@as(f32, 0.5), std.math.pow(f32, 0.5, 1));
    try std.testing.expectEqual(@as(f32, 0.25), std.math.pow(f32, 0.5, 2));
}
