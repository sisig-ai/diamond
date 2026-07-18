const std = @import("std");
const Allocator = std.mem.Allocator;

pub const k1: f32 = 1.2;
pub const b: f32 = 0.75;

pub const TermPosting = struct {
    chunk_id: u32,
    tf: u32,
};

pub const TermEntry = struct {
    term: []const u8,
    df: u32,
    postings: []TermPosting,
};

pub const Index = struct {
    terms: []TermEntry,
    /// Sorted term strings for binary search; parallel to `terms` order after build.
    term_map: std.StringHashMapUnmanaged(u32),
    doc_len: []u32,
    avgdl: f32,
    doc_count: u32,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Index) void {
        self.term_map.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn tokenize(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);

    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !isTokenChar(text[i])) : (i += 1) {}
        if (i >= text.len) break;
        const start = i;
        while (i < text.len and isTokenChar(text[i])) : (i += 1) {}
        const raw = text[start..i];
        const lower = try toLowerAlloc(a, raw);
        try out.append(a, lower);
    }
    return try a.dupe([]const u8, out.items);
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn toLowerAlloc(a: Allocator, s: []const u8) ![]const u8 {
    const buf = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        buf[i] = if (c < 0x80) std.ascii.toLower(c) else c;
    }
    return buf;
}

pub fn build(gpa: Allocator, docs: []const []const u8) !Index {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var map: std.StringHashMapUnmanaged(std.ArrayList(TermPosting)) = .empty;
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(gpa);
        }
        map.deinit(gpa);
    }

    var doc_len = try a.alloc(u32, docs.len);
    var total_len: u64 = 0;

    for (docs, 0..) |doc, di| {
        const toks = try tokenize(gpa, doc);
        defer {
            for (toks) |t| gpa.free(t);
            gpa.free(toks);
        }

        var tf: std.StringHashMapUnmanaged(u32) = .empty;
        defer tf.deinit(gpa);

        for (toks) |t| {
            const gop = try tf.getOrPut(gpa, t);
            if (!gop.found_existing) {
                gop.key_ptr.* = try a.dupe(u8, t);
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }

        doc_len[di] = @intCast(toks.len);
        total_len += toks.len;

        var tit = tf.iterator();
        while (tit.next()) |e| {
            const gop = try map.getOrPut(gpa, e.key_ptr.*);
            if (!gop.found_existing) {
                gop.key_ptr.* = e.key_ptr.*; // already arena-duped
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(gpa, .{
                .chunk_id = @intCast(di),
                .tf = e.value_ptr.*,
            });
        }
    }

    const doc_count: u32 = @intCast(docs.len);
    const avgdl: f32 = if (doc_count == 0) 0 else @as(f32, @floatFromInt(total_len)) / @as(f32, @floatFromInt(doc_count));

    var terms: std.ArrayList(TermEntry) = .empty;
    defer terms.deinit(gpa);

    var term_map: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer term_map.deinit(gpa);

    var mit = map.iterator();
    while (mit.next()) |e| {
        const postings = try a.dupe(TermPosting, e.value_ptr.items);
        std.mem.sort(TermPosting, postings, {}, struct {
            fn less(_: void, x: TermPosting, y: TermPosting) bool {
                return x.chunk_id < y.chunk_id;
            }
        }.less);
        const idx: u32 = @intCast(terms.items.len);
        try terms.append(gpa, .{
            .term = e.key_ptr.*,
            .df = @intCast(postings.len),
            .postings = postings,
        });
        try term_map.put(gpa, e.key_ptr.*, idx);
    }

    // Sort terms for determinism
    std.mem.sort(TermEntry, terms.items, {}, struct {
        fn less(_: void, x: TermEntry, y: TermEntry) bool {
            return std.mem.order(u8, x.term, y.term) == .lt;
        }
    }.less);
    // rebuild map indices after sort
    term_map.clearRetainingCapacity();
    for (terms.items, 0..) |t, i| {
        try term_map.put(gpa, t.term, @intCast(i));
    }

    return .{
        .terms = try a.dupe(TermEntry, terms.items),
        .term_map = term_map,
        .doc_len = doc_len,
        .avgdl = avgdl,
        .doc_count = doc_count,
        .arena = arena,
    };
}

pub fn idf(doc_count: u32, df: u32) f32 {
    // standard BM25 IDF: ln((N - n + 0.5) / (n + 0.5) + 1)
    const N: f32 = @floatFromInt(doc_count);
    const n: f32 = @floatFromInt(df);
    return @log((N - n + 0.5) / (n + 0.5) + 1.0);
}

pub fn scoreDoc(index: *const Index, chunk_id: u32, query_terms: []const []const u8) f32 {
    if (chunk_id >= index.doc_len.len) return 0;
    const dl: f32 = @floatFromInt(index.doc_len[chunk_id]);
    var score: f32 = 0;
    for (query_terms) |qt| {
        const idx = index.term_map.get(qt) orelse continue;
        const term = index.terms[idx];
        const tf = blk: {
            for (term.postings) |p| {
                if (p.chunk_id == chunk_id) break :blk p.tf;
            }
            break :blk @as(u32, 0);
        };
        if (tf == 0) continue;
        const tf_f: f32 = @floatFromInt(tf);
        const denom = tf_f + k1 * (1.0 - b + b * dl / index.avgdl);
        score += idf(index.doc_count, term.df) * (tf_f * (k1 + 1.0)) / denom;
    }
    return score;
}

pub const Hit = struct {
    chunk_id: u32,
    score: f32,
};

pub fn search(gpa: Allocator, index: *const Index, query: []const u8, limit: usize) ![]Hit {
    const qtoks = try tokenize(gpa, query);
    defer {
        for (qtoks) |t| gpa.free(t);
        gpa.free(qtoks);
    }

    var scores = try gpa.alloc(f32, index.doc_count);
    defer gpa.free(scores);
    @memset(scores, 0);

    for (qtoks) |qt| {
        const idx = index.term_map.get(qt) orelse continue;
        const term = index.terms[idx];
        const idf_v = idf(index.doc_count, term.df);
        for (term.postings) |p| {
            const dl: f32 = @floatFromInt(index.doc_len[p.chunk_id]);
            const tf_f: f32 = @floatFromInt(p.tf);
            const denom = tf_f + k1 * (1.0 - b + b * dl / index.avgdl);
            scores[p.chunk_id] += idf_v * (tf_f * (k1 + 1.0)) / denom;
        }
    }

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    for (scores, 0..) |s, i| {
        if (s > 0) try hits.append(gpa, .{ .chunk_id = @intCast(i), .score = s });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn less(_: void, x: Hit, y: Hit) bool {
            if (x.score == y.score) return x.chunk_id < y.chunk_id;
            return x.score > y.score;
        }
    }.less);

    const n = @min(limit, hits.items.len);
    return try gpa.dupe(Hit, hits.items[0..n]);
}

test "bm25 ranks matching doc higher" {
    const a = std.testing.allocator;
    const docs = [_][]const u8{
        "the quick brown fox",
        "lazy dog sleeps",
        "quick fox jumps",
    };
    var idx = try build(a, &docs);
    defer idx.deinit();

    const hits = try search(a, &idx, "quick fox", 3);
    defer a.free(hits);
    try std.testing.expect(hits.len >= 1);
    try std.testing.expect(hits[0].chunk_id == 0 or hits[0].chunk_id == 2);
    try std.testing.expect(hits[0].score > 0);
}

test "bm25 idf hand fixture" {
    // N=2, df=1 => ln((2-1+0.5)/(1+0.5)+1) = ln(1.5/1.5+1) = ln(2)
    const v = idf(2, 1);
    try std.testing.expectApproxEqAbs(@log(2.0), v, 1e-6);
}
