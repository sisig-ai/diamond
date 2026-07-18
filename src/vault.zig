const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_file_bytes: usize = 16 * 1024 * 1024;
pub const chunk_target: usize = 750;
pub const chunk_hard_max: usize = 1000;
pub const chunk_merge_under: usize = 250;

pub const ParseError = error{
    UnsupportedFrontmatter,
    InvalidUtf8,
    FileTooLarge,
    IoFailure,
} || Allocator.Error;

pub const NoteMeta = struct {
    path: []const u8,
    name: []const u8,
    parent_folder: []const u8,
    title: ?[]const u8,
    aliases: []const []const u8,
    tags: []const []const u8,
    h1: ?[]const u8,
};

pub const Chunk = struct {
    note_id: u32,
    heading_trail: []const []const u8,
    body: []const u8,
    start_line: u32,
    end_line: u32,
};

pub const Note = struct {
    meta: NoteMeta,
    chunks: []Chunk,
};

pub const Vault = struct {
    notes: []Note,
    /// Arena-owned backing storage for all strings/slices above.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Vault) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const skip_dirs = [_][]const u8{ ".obsidian", ".trash", ".git", "node_modules" };

pub fn walkAndParse(gpa: Allocator, io: Io, vault_root: []const u8) ParseError!Vault {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);

    var root_dir = Io.Dir.openDirAbsolute(io, vault_root, .{ .iterate = true, .follow_symlinks = false }) catch
        return error.IoFailure;
    defer root_dir.close(io);

    var walker = root_dir.walk(gpa) catch return error.OutOfMemory;
    defer walker.deinit();

    while (true) {
        const entry = (walker.next(io) catch return error.IoFailure) orelse break;
        if (entry.kind != .file) continue;
        if (!hasMdExt(entry.basename)) continue;
        if (pathHasSkippedComponent(entry.path)) continue;

        const rel = try a.dupe(u8, entry.path);
        try paths.append(gpa, rel);
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);

    var notes: std.ArrayList(Note) = .empty;
    try notes.ensureTotalCapacity(gpa, paths.items.len);
    defer notes.deinit(gpa);

    for (paths.items, 0..) |rel, i| {
        const abs = try std.fs.path.join(gpa, &.{ vault_root, rel });
        defer gpa.free(abs);

        const raw = Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_file_bytes + 1)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.IoFailure,
        };
        defer gpa.free(raw);

        if (raw.len > max_file_bytes) return error.FileTooLarge;
        if (!std.unicode.utf8ValidateSlice(raw)) {
            std.debug.print("invalid UTF-8: {s}\n", .{rel});
            return error.InvalidUtf8;
        }

        const note = try parseNote(a, rel, raw, @intCast(i));
        try notes.append(gpa, note);
    }

    return .{
        .notes = try a.dupe(Note, notes.items),
        .arena = arena,
    };
}

fn hasMdExt(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".md");
}

fn pathHasSkippedComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        for (skip_dirs) |skip| {
            if (std.mem.eql(u8, comp, skip)) return true;
        }
    }
    return false;
}

fn parseNote(a: Allocator, rel_path: []const u8, raw: []const u8, note_id: u32) ParseError!Note {
    const name = noteNameFromPath(rel_path);
    const parent = parentFolder(rel_path);

    var title: ?[]const u8 = null;
    var aliases: []const []const u8 = &.{};
    var tags: []const []const u8 = &.{};

    var body_start: usize = 0;
    if (std.mem.startsWith(u8, raw, "---\n") or std.mem.startsWith(u8, raw, "---\r\n")) {
        const after_open = if (raw[3] == '\r') @as(usize, 5) else 4;
        const close = findFrontmatterClose(raw, after_open) orelse {
            return failFm(rel_path, 1, "missing frontmatter closing ---");
        };
        const fm = raw[after_open..close.offset];
        const parsed = try parseFrontmatter(a, rel_path, fm, 2);
        title = parsed.title;
        aliases = parsed.aliases;
        tags = parsed.tags;
        body_start = close.end;
    }

    const body = raw[body_start..];
    const sections = try splitSections(a, body, lineNumberAt(raw, body_start));
    const inline_tags = try collectInlineTags(a, body);
    tags = try mergeTags(a, tags, inline_tags);

    var h1: ?[]const u8 = null;
    for (sections) |sec| {
        if (sec.level == 1) {
            h1 = try a.dupe(u8, sec.heading);
            break;
        }
    }

    var chunks = try chunkSections(a, note_id, sections);
    if (chunks.len == 0) {
        const trail: []const []const u8 = if (h1) |h| blk: {
            const one = try a.alloc([]const u8, 1);
            one[0] = try a.dupe(u8, h);
            break :blk one;
        } else &.{};
        const single = try a.alloc(Chunk, 1);
        single[0] = .{
            .note_id = note_id,
            .heading_trail = trail,
            .body = "",
            .start_line = lineNumberAt(raw, body_start),
            .end_line = lineNumberAt(raw, body_start),
        };
        chunks = single;
    }

    return .{
        .meta = .{
            .path = try a.dupe(u8, rel_path),
            .name = try a.dupe(u8, name),
            .parent_folder = try a.dupe(u8, parent),
            .title = title,
            .aliases = aliases,
            .tags = tags,
            .h1 = h1,
        },
        .chunks = chunks,
    };
}

const FmClose = struct { offset: usize, end: usize };

fn findFrontmatterClose(raw: []const u8, start: usize) ?FmClose {
    var i = start;
    while (i + 3 <= raw.len) : (i += 1) {
        if (raw[i] == '-' and raw[i + 1] == '-' and raw[i + 2] == '-') {
            const at_line = i == start or raw[i - 1] == '\n';
            if (!at_line) continue;
            var end = i + 3;
            if (end < raw.len and raw[end] == '\r') end += 1;
            if (end < raw.len and raw[end] == '\n') end += 1;
            return .{ .offset = i, .end = end };
        }
    }
    return null;
}

fn lineNumberAt(raw: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < offset and i < raw.len) : (i += 1) {
        if (raw[i] == '\n') line += 1;
    }
    return line;
}

fn failFm(path: []const u8, line: u32, msg: []const u8) ParseError {
    std.debug.print("unsupported frontmatter in {s}:{d}: {s}\n", .{ path, line, msg });
    return error.UnsupportedFrontmatter;
}

const Frontmatter = struct {
    title: ?[]const u8,
    aliases: []const []const u8,
    tags: []const []const u8,
};

fn parseFrontmatter(a: Allocator, path: []const u8, fm: []const u8, base_line: u32) ParseError!Frontmatter {
    var title: ?[]const u8 = null;
    var aliases: std.ArrayList([]const u8) = .empty;
    defer aliases.deinit(a);
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(a);

    var lines: std.ArrayList(struct { text: []const u8, no: u32 }) = .empty;
    defer lines.deinit(a);
    {
        var rest = fm;
        var line_no = base_line;
        while (true) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const line_raw = if (nl) |n| rest[0..n] else rest;
            try lines.append(a, .{
                .text = std.mem.trimEnd(u8, line_raw, "\r"),
                .no = line_no,
            });
            if (nl) |n| {
                rest = rest[n + 1 ..];
                line_no += 1;
            } else break;
        }
    }

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i].text;
        const line_no = lines.items[i].no;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "- ")) {
            return failFm(path, line_no, "orphaned list item (expected under aliases/tags)");
        }

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
            return failFm(path, line_no, "expected key: value");
        };
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

        if (std.mem.eql(u8, key, "title")) {
            if (value.len == 0) return failFm(path, line_no, "title must be a scalar string");
            if (value[0] == '[' or value[0] == '{' or std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, ">")) {
                return failFm(path, line_no, "unsupported title form");
            }
            title = try a.dupe(u8, unquote(value));
        } else if (std.mem.eql(u8, key, "aliases") or std.mem.eql(u8, key, "tags")) {
            const list = if (std.mem.eql(u8, key, "aliases")) &aliases else &tags;
            if (value.len == 0) {
                i += 1;
                while (i < lines.items.len) : (i += 1) {
                    const t = std.mem.trim(u8, lines.items[i].text, " \t");
                    if (t.len == 0) continue;
                    if (std.mem.startsWith(u8, t, "- ")) {
                        const item = std.mem.trim(u8, t[2..], " \t");
                        if (item.len == 0 or item[0] == '[' or item[0] == '{') {
                            return failFm(path, lines.items[i].no, "unsupported list item form");
                        }
                        try list.append(a, try a.dupe(u8, unquote(item)));
                        continue;
                    }
                    i -= 1; // reprocess as next key
                    break;
                }
            } else if (value[0] == '[') {
                try parseFlowList(a, path, line_no, value, list);
            } else {
                if (value[0] == '{' or std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, ">")) {
                    return failFm(path, line_no, "unsupported aliases/tags form");
                }
                try list.append(a, try a.dupe(u8, unquote(value)));
            }
        } else if (value.len == 0) {
            // skip unrecognized block-list values
            i += 1;
            while (i < lines.items.len) : (i += 1) {
                const t = std.mem.trim(u8, lines.items[i].text, " \t");
                if (t.len == 0 or std.mem.startsWith(u8, t, "- ")) continue;
                i -= 1;
                break;
            }
        }
    }

    return .{
        .title = title,
        .aliases = try a.dupe([]const u8, aliases.items),
        .tags = try a.dupe([]const u8, tags.items),
    };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn parseFlowList(a: Allocator, path: []const u8, line: u32, value: []const u8, out: *std.ArrayList([]const u8)) ParseError!void {
    if (value[value.len - 1] != ']') return failFm(path, line, "unterminated flow list");
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) return;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part| {
        const item = std.mem.trim(u8, part, " \t");
        if (item.len == 0) continue;
        if (item[0] == '[' or item[0] == '{') return failFm(path, line, "nested structures unsupported");
        try out.append(a, try a.dupe(u8, unquote(item)));
    }
}

const Section = struct {
    level: u8, // 0 = lead-in before any heading
    heading: []const u8,
    heading_trail: []const []const u8,
    body: []const u8,
    start_line: u32,
    end_line: u32,
};

const FenceState = struct {
    in_fence: bool = false,
    fence_char: u8 = 0,
    fence_len: usize = 0,

    fn feedLine(self: *FenceState, line: []const u8) void {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!self.in_fence) {
            if (trimmed.len >= 3 and (trimmed[0] == '`' or trimmed[0] == '~')) {
                const ch = trimmed[0];
                var n: usize = 0;
                while (n < trimmed.len and trimmed[n] == ch) : (n += 1) {}
                if (n >= 3) {
                    self.in_fence = true;
                    self.fence_char = ch;
                    self.fence_len = n;
                }
            }
            return;
        }
        if (trimmed.len >= self.fence_len and trimmed[0] == self.fence_char) {
            var n: usize = 0;
            while (n < trimmed.len and trimmed[n] == self.fence_char) : (n += 1) {}
            if (n >= self.fence_len) {
                self.in_fence = false;
                self.fence_char = 0;
                self.fence_len = 0;
            }
        }
    }
};

fn splitSections(a: Allocator, body: []const u8, first_line: u32) ParseError![]Section {
    var sections: std.ArrayList(Section) = .empty;
    defer sections.deinit(a);

    var trail: std.ArrayList([]const u8) = .empty;
    defer trail.deinit(a);

    var line_no = first_line;
    var i: usize = 0;
    var sec_start: usize = 0;
    var sec_start_line = first_line;
    var cur_level: u8 = 0;
    var cur_heading: []const u8 = "";
    var fence: FenceState = .{};

    const flush = struct {
        fn call(
            alloc: Allocator,
            out: *std.ArrayList(Section),
            trail_list: *std.ArrayList([]const u8),
            src: []const u8,
            start: usize,
            end: usize,
            level: u8,
            heading: []const u8,
            start_line: u32,
            end_line: u32,
        ) !void {
            if (start >= end and level == 0) return;
            const trail_copy = try alloc.dupe([]const u8, trail_list.items);
            for (trail_copy) |*p| p.* = try alloc.dupe(u8, p.*);
            try out.append(alloc, .{
                .level = level,
                .heading = try alloc.dupe(u8, heading),
                .heading_trail = trail_copy,
                .body = try alloc.dupe(u8, src[start..end]),
                .start_line = start_line,
                .end_line = if (end_line >= start_line) end_line else start_line,
            });
        }
    }.call;

    while (i < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, i, '\n');
        const line_end = nl orelse body.len;
        const line = body[i..line_end];
        const line_trim = std.mem.trimEnd(u8, line, "\r");

        const was_in_fence = fence.in_fence;
        if (!was_in_fence) {
            if (parseAtxHeading(line_trim)) |h| {
                const end_line = if (line_no > sec_start_line) line_no - 1 else sec_start_line;
                try flush(a, &sections, &trail, body, sec_start, i, cur_level, cur_heading, sec_start_line, end_line);

                while (trail.items.len > 0 and trail.items.len >= h.level) {
                    _ = trail.pop();
                }
                while (trail.items.len + 1 < h.level) {
                    try trail.append(a, "");
                }
                try trail.append(a, try a.dupe(u8, h.text));

                cur_level = h.level;
                cur_heading = h.text;
                sec_start = if (nl) |n| n + 1 else body.len;
                sec_start_line = line_no + 1;
            }
        }
        fence.feedLine(line_trim);

        if (nl) |n| {
            i = n + 1;
            line_no += 1;
        } else {
            i = body.len;
        }
    }

    const end_line = if (body.len == 0) first_line else line_no;
    try flush(a, &sections, &trail, body, sec_start, body.len, cur_level, cur_heading, sec_start_line, end_line);

    var kept: std.ArrayList(Section) = .empty;
    defer kept.deinit(a);
    for (sections.items) |s| {
        if (std.mem.trim(u8, s.body, " \t\r\n").len == 0) continue;
        try kept.append(a, s);
    }

    if (kept.items.len == 0) {
        try kept.append(a, .{
            .level = 0,
            .heading = "",
            .heading_trail = &.{},
            .body = "",
            .start_line = first_line,
            .end_line = first_line,
        });
    }

    return try a.dupe(Section, kept.items);
}

fn parseAtxHeading(line: []const u8) ?struct { level: u8, text: []const u8 } {
    if (line.len == 0 or line[0] != '#') return null;
    var level: u8 = 0;
    while (level < line.len and line[level] == '#' and level < 6) : (level += 1) {}
    if (level == 0 or level > 6) return null;
    if (level >= line.len or line[level] != ' ') return null;
    const text = std.mem.trim(u8, line[level + 1 ..], " \t");
    // strip trailing closing hashes
    var end = text.len;
    while (end > 0 and text[end - 1] == '#') : (end -= 1) {}
    const cleaned = std.mem.trimEnd(u8, text[0..end], " \t");
    return .{ .level = level, .text = cleaned };
}

fn joinHeadingTrail(a: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return try a.dupe(u8, "");
    var size: usize = 0;
    for (parts, 0..) |p, i| {
        size += p.len;
        if (i + 1 < parts.len) size += 3;
    }
    var buf = try a.alloc(u8, size);
    var f: usize = 0;
    for (parts, 0..) |p, i| {
        @memcpy(buf[f..][0..p.len], p);
        f += p.len;
        if (i + 1 < parts.len) {
            @memcpy(buf[f..][0..3], " > ");
            f += 3;
        }
    }
    return buf;
}

pub fn formatHeadingTrail(a: Allocator, parts: []const []const u8) ![]const u8 {
    return joinHeadingTrail(a, parts);
}

fn trailsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn chunkSections(a: Allocator, note_id: u32, sections: []const Section) ParseError![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    defer out.deinit(a);

    for (sections) |sec| {
        try chunkOneSection(a, note_id, sec, &out);
    }

    var i: usize = 1;
    while (i < out.items.len) {
        const prev = out.items[i - 1];
        const cur = out.items[i];
        if (cur.note_id == prev.note_id and
            trailsEqual(cur.heading_trail, prev.heading_trail) and
            cur.body.len < chunk_merge_under and
            prev.body.len + 1 + cur.body.len <= chunk_hard_max)
        {
            const merged = try std.fmt.allocPrint(a, "{s}\n{s}", .{ prev.body, cur.body });
            out.items[i - 1] = .{
                .note_id = prev.note_id,
                .heading_trail = prev.heading_trail,
                .body = merged,
                .start_line = prev.start_line,
                .end_line = cur.end_line,
            };
            _ = out.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    return try a.dupe(Chunk, out.items);
}

fn chunkOneSection(a: Allocator, note_id: u32, sec: Section, out: *std.ArrayList(Chunk)) ParseError!void {
    const raw = sec.body;
    const body = std.mem.trim(u8, raw, " \t\r\n");
    if (body.len == 0) return;

    const prefix_len = @intFromPtr(body.ptr) - @intFromPtr(raw.ptr);
    const adj_start = sec.start_line + countNewlines(raw[0..prefix_len]);
    const adj_end = adj_start + countNewlines(body);

    var start: usize = 0;
    var start_line = adj_start;
    while (start < body.len) {
        const remaining = body.len - start;
        if (remaining <= chunk_hard_max) {
            try out.append(a, .{
                .note_id = note_id,
                .heading_trail = sec.heading_trail,
                .body = try a.dupe(u8, body[start..]),
                .start_line = start_line,
                .end_line = adj_end,
            });
            break;
        }

        const ideal = @min(chunk_target, remaining);
        const hard = @min(chunk_hard_max, remaining);
        const split_at = findSplit(body, start, ideal, hard);
        const piece = body[start .. start + split_at];
        const piece_trim = std.mem.trimEnd(u8, piece, "\r\n");
        const end_line = start_line + countNewlines(piece_trim);
        try out.append(a, .{
            .note_id = note_id,
            .heading_trail = sec.heading_trail,
            .body = try a.dupe(u8, piece_trim),
            .start_line = start_line,
            .end_line = if (end_line > start_line) end_line else start_line,
        });

        var next = start + split_at;
        while (next < body.len and (body[next] == '\n' or body[next] == '\r')) : (next += 1) {}
        start_line = start_line + countNewlines(body[start..next]);
        start = next;
    }
}

fn findSplit(body: []const u8, start: usize, ideal: usize, hard: usize) usize {
    const window = body[start .. start + hard];
    // prefer blank line near ideal
    if (findBlankNear(window, ideal)) |n| return n;
    // prefer newline near ideal
    if (findCharNear(window, ideal, '\n')) |n| return n + 1;
    // UTF-8 safe: back up from hard
    return utf8Floor(window, hard);
}

fn findBlankNear(window: []const u8, ideal: usize) ?usize {
    var best: ?usize = null;
    var i: usize = 0;
    while (i + 1 < window.len) : (i += 1) {
        if (window[i] == '\n' and window[i + 1] == '\n') {
            const at = i + 2;
            if (at >= ideal / 2 and at <= ideal + (ideal / 2) and at <= window.len) {
                if (best == null or absDiff(at, ideal) < absDiff(best.?, ideal)) best = at;
            }
        }
    }
    // also search whole window if nothing near ideal but under hard
    if (best == null) {
        i = 0;
        while (i + 1 < window.len) : (i += 1) {
            if (window[i] == '\n' and window[i + 1] == '\n') {
                const at = i + 2;
                if (at >= ideal / 3) {
                    if (best == null or absDiff(at, ideal) < absDiff(best.?, ideal)) best = at;
                }
            }
        }
    }
    return best;
}

fn findCharNear(window: []const u8, ideal: usize, ch: u8) ?usize {
    var best: ?usize = null;
    var i: usize = ideal / 3;
    while (i < window.len) : (i += 1) {
        if (window[i] == ch) {
            if (best == null or absDiff(i, ideal) < absDiff(best.?, ideal)) best = i;
        }
    }
    return best;
}

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

fn utf8Floor(window: []const u8, hard: usize) usize {
    var i = @min(hard, window.len);
    while (i > 0 and i < window.len and (window[i] & 0xC0) == 0x80) : (i -= 1) {}
    return if (i == 0) @min(hard, window.len) else i;
}

fn countNewlines(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

fn collectInlineTags(a: Allocator, body: []const u8) ParseError![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(a);

    var fence: FenceState = .{};
    var i: usize = 0;
    while (i < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, i, '\n');
        const line_end = nl orelse body.len;
        const line = body[i..line_end];
        const line_trim = std.mem.trimEnd(u8, line, "\r");

        const in_fence = fence.in_fence;
        fence.feedLine(line_trim);

        if (!in_fence and !fence.in_fence) {
            try collectTagsInLine(a, line_trim, &tags);
        } else if (!in_fence and fence.in_fence) {
            // Opening fence line — no tags.
        } else if (in_fence and !fence.in_fence) {
            // Closing fence line — no tags.
        }

        if (nl) |n| {
            i = n + 1;
        } else {
            break;
        }
    }

    return try a.dupe([]const u8, tags.items);
}

fn collectTagsInLine(a: Allocator, line: []const u8, tags: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            i += 1;
            while (i < line.len and line[i] != '`') : (i += 1) {}
            if (i < line.len) i += 1;
            continue;
        }
        if (line[i] == '#' and isTagStart(line, i)) {
            const start = i + 1;
            var j = start;
            while (j < line.len and isTagChar(line[j])) : (j += 1) {}
            if (j > start) {
                try tags.append(a, try a.dupe(u8, line[start..j]));
                i = j;
                continue;
            }
        }
        i += 1;
    }
}

fn isTagStart(body: []const u8, i: usize) bool {
    if (i > 0) {
        const prev = body[i - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '-') return false;
    }
    if (i + 1 >= body.len) return false;
    return isTagChar(body[i + 1]);
}

fn isTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/';
}

fn mergeTags(a: Allocator, a_tags: []const []const u8, b_tags: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    for (a_tags) |t| try out.append(a, t);
    for (b_tags) |t| {
        var found = false;
        for (out.items) |e| {
            if (std.mem.eql(u8, e, t)) {
                found = true;
                break;
            }
        }
        if (!found) try out.append(a, t);
    }
    return try a.dupe([]const u8, out.items);
}

fn noteNameFromPath(rel: []const u8) []const u8 {
    const base = std.fs.path.basename(rel);
    if (std.ascii.endsWithIgnoreCase(base, ".md")) {
        return base[0 .. base.len - 3];
    }
    return base;
}

fn parentFolder(rel: []const u8) []const u8 {
    const dir = std.fs.path.dirname(rel) orelse return "";
    return dir;
}

// ── tests ──────────────────────────────────────────────────────────

test "frontmatter title aliases tags" {
    const a = std.testing.allocator;
    const raw =
        \\---
        \\title: Hello
        \\aliases:
        \\  - Hi
        \\  - Hey
        \\tags: [a, b]
        \\---
        \\
        \\# Hello
        \\
        \\Body #c
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const note = try parseNote(arena.allocator(), "Hello.md", raw, 0);
    try std.testing.expectEqualStrings("Hello", note.meta.title.?);
    try std.testing.expectEqual(@as(usize, 2), note.meta.aliases.len);
    try std.testing.expectEqualStrings("Hi", note.meta.aliases[0]);
    try std.testing.expectEqual(@as(usize, 3), note.meta.tags.len);
}

test "unsupported title form aborts" {
    const a = std.testing.allocator;
    const raw =
        \\---
        \\title:
        \\  - nope
        \\---
        \\
        \\x
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedFrontmatter, parseNote(arena.allocator(), "bad.md", raw, 0));
}

test "chunk never crosses heading" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const raw =
        \\# One
        \\
        \\aaa
        \\
        \\# Two
        \\
        \\bbb
    ;
    const note = try parseNote(arena.allocator(), "t.md", raw, 0);
    try std.testing.expect(note.chunks.len >= 2);
    for (note.chunks) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c.body, "# Two") == null);
    }
}

test "inline tags skip fences and code" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const raw =
        \\# T
        \\
        \\`#nope` and
        \\```
        \\#nope2
        \\```
        \\yes #real
    ;
    const note = try parseNote(arena.allocator(), "t.md", raw, 0);
    try std.testing.expectEqual(@as(usize, 1), note.meta.tags.len);
    try std.testing.expectEqualStrings("real", note.meta.tags[0]);
}

test "chunk respects hard max" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "# Big\n\n");
    var i: usize = 0;
    while (i < 2500) : (i += 1) {
        try buf.appendSlice(a, "word ");
    }
    const note = try parseNote(arena.allocator(), "big.md", buf.items, 0);
    for (note.chunks) |c| {
        try std.testing.expect(c.body.len <= chunk_hard_max);
    }
    try std.testing.expect(note.chunks.len > 1);
}

test "trim adjusts start_line to first content line" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const raw =
        \\---
        \\title: Community Garden
        \\aliases: [Garden Plot]
        \\tags:
        \\  - gardening
        \\  - outdoors
        \\---
        \\
        \\# Community Garden
        \\
        \\The community garden grows tomatoes and herbs every summer.
        \\
        \\## Soil prep
        \\
        \\Turn the soil in early spring before planting #gardening beds.
    ;
    const note = try parseNote(arena.allocator(), "Projects/Garden.md", raw, 0);
    try std.testing.expect(note.chunks.len >= 1);
    const first = note.chunks[0];
    try std.testing.expect(std.mem.startsWith(u8, first.body, "The community garden"));
    try std.testing.expectEqual(@as(u32, 11), first.start_line);
    try std.testing.expectEqual(@as(usize, 1), first.heading_trail.len);
    try std.testing.expectEqualStrings("Community Garden", first.heading_trail[0]);
}

test "fenced headings are not sections and fenced tags ignored" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const raw =
        \\# Real
        \\
        \\Outside #keep
        \\
        \\```
        \\# Fake Heading
        \\#faketag
        \\```
        \\
        \\After
    ;
    const note = try parseNote(arena.allocator(), "fence.md", raw, 0);
    try std.testing.expectEqual(@as(usize, 1), note.meta.tags.len);
    try std.testing.expectEqualStrings("keep", note.meta.tags[0]);
    for (note.chunks) |c| {
        try std.testing.expect(c.heading_trail.len == 0 or std.mem.eql(u8, c.heading_trail[0], "Real"));
        for (c.heading_trail) |h| {
            try std.testing.expect(!std.mem.eql(u8, h, "Fake Heading"));
        }
    }
    var saw_fake_body = false;
    for (note.chunks) |c| {
        if (std.mem.indexOf(u8, c.body, "# Fake Heading") != null) saw_fake_body = true;
    }
    try std.testing.expect(saw_fake_body);
}
