const std = @import("std");
const Allocator = std.mem.Allocator;
const vault = @import("vault.zig");

pub const dim: usize = 256;

// Asset SHA-256 (see assets/potion-base-8M/SHA256SUMS):
// tokenizer.json: e67e803f624fb4d67dea1c730d06e1067e1b14d830e2c2202569e3ef0f70bb50
// model.i8.safetensors: a4264cfe4354253b9332731aa3db0c066f302c8507ebd791ba1b10f64efc8eb5
const tokenizer_bytes = @embedFile("potion_tokenizer");
const model_bytes_raw = @embedFile("potion_model");

pub const tokenizer_sha256_hex = "e67e803f624fb4d67dea1c730d06e1067e1b14d830e2c2202569e3ef0f70bb50";
pub const model_sha256_hex = "a4264cfe4354253b9332731aa3db0c066f302c8507ebd791ba1b10f64efc8eb5";

const m2v = @import("model2vec");

pub const Embedder = struct {
    model: m2v.Model,
    /// Aligned copy of embedded safetensors so the matrix can borrow.
    st_aligned: []align(8) u8,
    gpa: Allocator,

    pub fn init(gpa: Allocator) !Embedder {
        const st = try gpa.alignedAlloc(u8, .of(u64), model_bytes_raw.len);
        errdefer gpa.free(st);
        @memcpy(st, model_bytes_raw);

        const model = try m2v.Model.loadFromBytes(gpa, tokenizer_bytes, st, .{ .normalize = true });
        if (model.dim != dim) return error.UnexpectedModelDim;
        return .{
            .model = model,
            .st_aligned = st,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Embedder) void {
        self.model.deinit();
        self.gpa.free(self.st_aligned);
        self.* = undefined;
    }

    pub fn embed(self: *const Embedder, scratch: Allocator, text: []const u8, out: []f32) !void {
        try self.model.embedInto(scratch, text, out);
    }
};

pub fn denseSearchText(a: Allocator, note: vault.NoteMeta, chunk: vault.Chunk) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    try appendPart(&list, a, note.name);
    if (note.title) |t| try appendPart(&list, a, t);
    for (note.aliases) |al| try appendPart(&list, a, al);
    if (note.h1) |h| try appendPart(&list, a, h);
    if (chunk.breadcrumb.len > 0) try appendPart(&list, a, chunk.breadcrumb);
    try appendPart(&list, a, chunk.body);
    return try a.dupe(u8, list.items);
}

pub fn sparseSearchText(a: Allocator, note: vault.NoteMeta, chunk: vault.Chunk) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);

    try repeatAppend(&list, a, chunk.body, 1);
    try repeatAppend(&list, a, note.parent_folder, 1);
    try repeatAppend(&list, a, chunk.breadcrumb, 2);
    try repeatAppend(&list, a, note.name, 3);
    if (note.title) |t| try repeatAppend(&list, a, t, 3);
    if (note.h1) |h| try repeatAppend(&list, a, h, 3);
    for (note.aliases) |al| try repeatAppend(&list, a, al, 3);
    for (note.tags) |tg| try repeatAppend(&list, a, tg, 3);

    return try a.dupe(u8, list.items);
}

fn appendPart(list: *std.ArrayList(u8), a: Allocator, part: []const u8) !void {
    if (part.len == 0) return;
    if (list.items.len > 0) try list.append(a, ' ');
    try list.appendSlice(a, part);
}

fn repeatAppend(list: *std.ArrayList(u8), a: Allocator, part: []const u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try appendPart(list, a, part);
    }
}

test "dense and sparse text include signals" {
    const a = std.testing.allocator;
    const note = vault.NoteMeta{
        .path = "Projects/Garden.md",
        .name = "Garden",
        .parent_folder = "Projects",
        .title = "Community Garden",
        .aliases = &.{"Garden Plot"},
        .tags = &.{"gardening"},
        .h1 = "Community Garden",
    };
    const chunk = vault.Chunk{
        .note_id = 0,
        .breadcrumb = "Community Garden > Soil prep",
        .body = "Turn the soil",
        .start_line = 10,
        .end_line = 12,
    };
    const d = try denseSearchText(a, note, chunk);
    defer a.free(d);
    const s = try sparseSearchText(a, note, chunk);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, d, "Garden Plot") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "gardening") != null);
    // tags repeated 3x in sparse
    var count: usize = 0;
    var it = std.mem.window(u8, s, "gardening".len, 1);
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "gardening")) count += 1;
    }
    try std.testing.expect(count >= 3);
}
