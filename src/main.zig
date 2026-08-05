//! A small, dependency-free FITS HDU reader and editor.
//! FITS files are made of 80-byte header cards grouped into 2880-byte blocks,
//! followed by a data area padded to a 2880-byte boundary. This module keeps
//! header cards in their logical form, while retaining arbitrary cards and
//! comments that it does not interpret.
const std = @import("std");

pub const FitsError = error{
    InvalidFits,
    InvalidCard,
    InvalidKeyword,
    InvalidValue,
    MissingRequiredKeyword,
    UnsupportedHeader,
    DataSizeOverflow,
};

pub const Card = struct {
    keyword: []u8,
    value: ?[]u8,
    comment: ?[]u8,
    allocator: std.mem.Allocator,

    /// Release the card's keyword, value, and comment storage.
    pub fn deinit(self: *Card) void {
        self.allocator.free(self.keyword);
        if (self.value) |value| self.allocator.free(value);
        if (self.comment) |comment| self.allocator.free(comment);
    }
};

pub const Fits = struct {
    allocator: std.mem.Allocator,
    cards: std.ArrayList(Card),
    data: std.ArrayList(u8),

    /// Create an empty HDU using `allocator` for all owned storage.
    pub fn init(allocator: std.mem.Allocator) Fits {
        return .{
            .allocator = allocator,
            .cards = .{ .items = &.{}, .capacity = 0 },
            .data = .{ .items = &.{}, .capacity = 0 },
        };
    }

    /// Release all cards and data owned by this HDU.
    pub fn deinit(self: *Fits) void {
        for (self.cards.items) |*card| card.deinit();
        self.cards.deinit(self.allocator);
        self.data.deinit(self.allocator);
    }

    /// Parse the primary HDU from a complete FITS byte buffer.
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Fits {
        if (bytes.len < block_size or bytes.len % block_size != 0) return error.InvalidFits;
        const parsed = try parseHduAt(allocator, bytes, 0, true);
        return parsed.fits;
    }

    /// Parse an HDU by zero-based extension index. Index 0 is the primary HDU;
    /// index 1 is the first extension, and so on.
    pub fn parseExtension(allocator: std.mem.Allocator, bytes: []const u8, index: usize) !Fits {
        if (bytes.len < block_size or bytes.len % block_size != 0) return error.InvalidFits;
        var offset: usize = 0;
        var current: usize = 0;
        while (offset < bytes.len) : (current += 1) {
            var parsed = try parseHduAt(allocator, bytes, offset, current == 0);
            if (current == index) return parsed.fits;
            offset = parsed.next_offset;
            parsed.fits.deinit();
        }
        return error.InvalidFits;
    }

    /// Read and parse the primary HDU from a file path.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Fits {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(bytes);
        return parse(allocator, bytes);
    }

    /// Read and parse the HDU at `index` from a file path.
    pub fn loadExtension(allocator: std.mem.Allocator, path: []const u8, index: usize) !Fits {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(bytes);
        return parseExtension(allocator, bytes, index);
    }

    /// Write this HDU as a complete, standalone FITS file.
    pub fn save(self: *const Fits, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try self.write(file);
    }

    /// Replace one HDU in an existing FITS file, retaining all other HDUs.
    /// The replacement may have a different header or data size.
    pub fn saveExtension(self: *const Fits, path: []const u8, index: usize) !void {
        const input = try std.fs.cwd().openFile(path, .{});
        defer input.close();
        const original = try self.allocator.alloc(u8, try input.getEndPos());
        defer self.allocator.free(original);
        _ = try input.seekTo(0);
        try input.reader().readNoEof(original);

        const bounds = try extensionBounds(original, index);
        var replacement: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer replacement.deinit(self.allocator);
        try self.appendSerialized(&replacement);

        const output = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer output.close();
        try output.writeAll(original[0..bounds.start]);
        try output.writeAll(replacement.items);
        try output.writeAll(original[bounds.end..]);
    }

    /// Alias for `saveExtension`.
    pub fn writeExtension(self: *const Fits, path: []const u8, index: usize) !void {
        return self.saveExtension(path, index);
    }

    /// Write this HDU to a writer as a complete FITS HDU.
    pub fn write(self: *const Fits, writer: anytype) !void {
        var header: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer header.deinit(self.allocator);
        try self.appendSerialized(&header);
        try writer.writeAll(header.items);
    }

    /// Return the first card with this keyword, or null if absent.
    pub fn getCard(self: *const Fits, keyword: []const u8) ?*const Card {
        for (self.cards.items) |*card| if (std.ascii.eqlIgnoreCase(card.keyword, keyword)) return card;
        return null;
    }

    /// Return the raw value field for the first matching keyword.
    pub fn getString(self: *const Fits, keyword: []const u8) ?[]const u8 {
        const card = self.getCard(keyword) orelse return null;
        return card.value;
    }

    /// Parse the raw value field as an integer, if the keyword exists.
    pub fn getInt(self: *const Fits, comptime T: type, keyword: []const u8) !?T {
        const text = self.getString(keyword) orelse return null;
        return std.fmt.parseInt(T, std.mem.trim(u8, text, " \t"), 10) catch error.InvalidValue;
    }

    /// Parse the raw value field as a floating-point number, if it exists.
    pub fn getFloat(self: *const Fits, comptime T: type, keyword: []const u8) !?T {
        const text = self.getString(keyword) orelse return null;
        return std.fmt.parseFloat(T, std.mem.trim(u8, text, " \t")) catch error.InvalidValue;
    }

    /// Insert or replace a keyword. Values are emitted in the FITS value field.
    pub fn set(self: *Fits, keyword: []const u8, value: []const u8, comment: ?[]const u8) !void {
        try validateKeyword(keyword);
        const new_keyword = try self.allocator.dupe(u8, keyword);
        errdefer self.allocator.free(new_keyword);
        const new_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(new_value);
        const new_comment = if (comment) |c| try self.allocator.dupe(u8, c) else null;
        errdefer if (new_comment) |c| self.allocator.free(c);

        for (self.cards.items) |*card| {
            if (std.ascii.eqlIgnoreCase(card.keyword, keyword)) {
                card.deinit();
                card.* = .{ .keyword = new_keyword, .value = new_value, .comment = new_comment, .allocator = self.allocator };
                return;
            }
        }
        try self.cards.append(self.allocator, .{ .keyword = new_keyword, .value = new_value, .comment = new_comment, .allocator = self.allocator });
    }

    /// Format an integer and insert or replace a keyword.
    pub fn setInt(self: *Fits, keyword: []const u8, value: anytype, comment: ?[]const u8) !void {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{}", .{value});
        return self.set(keyword, text, comment);
    }

    /// Format a floating-point value and insert or replace a keyword.
    pub fn setFloat(self: *Fits, keyword: []const u8, value: anytype, comment: ?[]const u8) !void {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        return self.set(keyword, text, comment);
    }

    /// Remove the first card with `keyword`, returning whether one was found.
    pub fn remove(self: *Fits, keyword: []const u8) bool {
        for (self.cards.items, 0..) |*card, i| {
            if (std.ascii.eqlIgnoreCase(card.keyword, keyword)) {
                card.deinit();
                _ = self.cards.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Replace the unpadded data payload for this HDU.
    pub fn setData(self: *Fits, bytes: []const u8) !void {
        self.data.clearRetainingCapacity();
        try self.data.appendSlice(self.allocator, bytes);
    }

    /// Return the unpadded data payload owned by this HDU.
    pub fn dataBytes(self: *const Fits) []const u8 {
        return self.data.items;
    }

    fn appendSerialized(self: *const Fits, out: *std.ArrayList(u8)) !void {
        const expected_data_len = try self.expectedDataLength();
        if (expected_data_len != self.data.items.len) return error.InvalidFits;
        for (self.cards.items) |card| try appendCard(out, self.allocator, card);
        var end_card: [card_size]u8 = undefined;
        @memset(&end_card, ' ');
        end_card[0..3].* = "END".*;
        try out.appendSlice(self.allocator, &end_card);
        try appendPadding(out, self.allocator, block_size);
        try out.appendSlice(self.allocator, self.data.items);
        try appendZeroPadding(out, self.allocator, block_size);
    }

    const card_size = 80;
    const block_size = 2880;

    fn expectedDataLength(self: *const Fits) !usize {
        const bitpix = try self.getInt(i64, "BITPIX") orelse return error.MissingRequiredKeyword;
        const naxis = try self.getInt(usize, "NAXIS") orelse return error.MissingRequiredKeyword;
        if (bitpix == 0 or @mod(bitpix, 8) != 0) return error.UnsupportedHeader;
        var elements: usize = if (naxis == 0) 0 else 1;
        var axis: usize = 0;
        while (axis < naxis) : (axis += 1) {
            var key_buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "NAXIS{}", .{axis + 1});
            const dimension = try self.getInt(usize, key) orelse return error.MissingRequiredKeyword;
            elements = std.math.mul(usize, elements, dimension) catch return error.DataSizeOverflow;
        }
        const bytes_per_element: usize = @intCast(@abs(bitpix) / 8);
        const image_bytes = std.math.mul(usize, elements, bytes_per_element) catch return error.DataSizeOverflow;
        const pcount = (try self.getInt(usize, "PCOUNT")) orelse 0;
        const gcount = (try self.getInt(usize, "GCOUNT")) orelse 1;
        const total = std.math.add(usize, image_bytes, pcount) catch return error.DataSizeOverflow;
        return std.math.mul(usize, total, gcount) catch error.DataSizeOverflow;
    }
};

const ParsedHdu = struct {
    fits: Fits,
    next_offset: usize,
};

const HduBounds = struct { start: usize, end: usize };

fn parseHduAt(allocator: std.mem.Allocator, bytes: []const u8, offset: usize, primary: bool) !ParsedHdu {
    if (offset > bytes.len or bytes.len - offset < Fits.block_size) return error.InvalidFits;

    var result = Fits.init(allocator);
    errdefer result.deinit();
    var end_card: usize = 0;
    var found_end = false;
    var block_offset: usize = offset;
    while (block_offset + Fits.block_size <= bytes.len and !found_end) : (block_offset += Fits.block_size) {
        var card_offset = block_offset;
        while (card_offset < block_offset + Fits.block_size) : (card_offset += Fits.card_size) {
            const raw = bytes[card_offset .. card_offset + Fits.card_size];
            if (std.mem.eql(u8, raw[0..3], "END") and std.mem.allEqual(u8, raw[3..], ' ')) {
                end_card = card_offset + Fits.card_size;
                found_end = true;
                break;
            }
            try result.cards.append(allocator, try parseCard(allocator, raw));
        }
    }
    if (!found_end or result.cards.items.len == 0) return error.InvalidFits;
    if (primary) {
        if (!std.mem.eql(u8, result.cards.items[0].keyword, "SIMPLE")) return error.InvalidFits;
    } else if (result.getCard("XTENSION") == null) {
        return error.InvalidFits;
    }

    const header_bytes = end_card + (Fits.block_size - (end_card % Fits.block_size)) % Fits.block_size;
    const payload_len = try result.expectedDataLength();
    const padded_len = try padded(payload_len);
    if (header_bytes > bytes.len or padded_len > bytes.len - header_bytes) return error.InvalidFits;
    try result.data.appendSlice(allocator, bytes[header_bytes .. header_bytes + payload_len]);
    return .{ .fits = result, .next_offset = header_bytes + padded_len };
}

fn extensionBounds(bytes: []const u8, index: usize) !HduBounds {
    if (bytes.len < Fits.block_size or bytes.len % Fits.block_size != 0) return error.InvalidFits;
    var offset: usize = 0;
    var current: usize = 0;
    while (offset < bytes.len) : (current += 1) {
        var parsed = try parseHduAt(std.heap.page_allocator, bytes, offset, current == 0);
        const end = parsed.next_offset;
        parsed.fits.deinit();
        if (current == index) return .{ .start = offset, .end = end };
        offset = end;
    }
    return error.InvalidFits;
}

fn validateKeyword(keyword: []const u8) !void {
    if (keyword.len == 0 or keyword.len > 8) return error.InvalidKeyword;
    for (keyword) |c| if (c < 0x20 or c > 0x7e or c == '=') return error.InvalidKeyword;
}

fn parseCard(allocator: std.mem.Allocator, raw: []const u8) !Card {
    if (raw.len != 80) return error.InvalidCard;
    const keyword = std.mem.trim(u8, raw[0..8], " ");
    if (keyword.len == 0) return error.InvalidCard;
    const key_copy = try allocator.dupe(u8, keyword);
    errdefer allocator.free(key_copy);

    var value: ?[]u8 = null;
    var comment: ?[]u8 = null;
    if (raw[8] == '=') {
        var field = std.mem.trim(u8, raw[10..], " ");
        var comment_start: ?usize = null;
        var quoted = false;
        for (field, 0..) |c, i| {
            if (c == '\'' and (i == 0 or field[i - 1] != '\'')) quoted = !quoted;
            if (c == '/' and !quoted) {
                comment_start = i;
                break;
            }
        }
        if (comment_start) |start| {
            comment = try allocator.dupe(u8, std.mem.trim(u8, field[start + 1 ..], " "));
            field = std.mem.trim(u8, field[0..start], " ");
        }
        value = try allocator.dupe(u8, field);
    }
    return .{ .keyword = key_copy, .value = value, .comment = comment, .allocator = allocator };
}

fn appendCard(out: *std.ArrayList(u8), allocator: std.mem.Allocator, card: Card) !void {
    if (card.keyword.len > 8 or (card.value == null and card.comment != null)) return error.InvalidCard;
    var raw: [80]u8 = undefined;
    @memset(&raw, ' ');
    @memcpy(raw[0..card.keyword.len], card.keyword);
    if (card.value) |value| {
        raw[8] = '=';
        raw[9] = ' ';
        if (value.len > 70) return error.InvalidCard;
        @memcpy(raw[10 .. 10 + value.len], value);
        if (card.comment) |comment| {
            if (12 + value.len + comment.len > 80) return error.InvalidCard;
            raw[10 + value.len] = ' ';
            raw[11 + value.len] = '/';
            @memcpy(raw[12 + value.len .. 12 + value.len + comment.len], comment);
        }
    }
    try out.appendSlice(allocator, &raw);
}

fn appendPadding(out: *std.ArrayList(u8), allocator: std.mem.Allocator, alignment: usize) !void {
    const padding_len = (alignment - (out.items.len % alignment)) % alignment;
    try out.resize(allocator, out.items.len + padding_len);
    @memset(out.items[out.items.len - padding_len ..], ' ');
}

fn appendZeroPadding(out: *std.ArrayList(u8), allocator: std.mem.Allocator, alignment: usize) !void {
    const padding_len = (alignment - (out.items.len % alignment)) % alignment;
    try out.resize(allocator, out.items.len + padding_len);
    @memset(out.items[out.items.len - padding_len ..], 0);
}

fn padded(length: usize) !usize {
    const remainder = length % Fits.block_size;
    return std.math.add(usize, length, if (remainder == 0) 0 else Fits.block_size - remainder) catch error.DataSizeOverflow;
}

test "round trip and edit a FITS image" {
    var fits = Fits.init(std.testing.allocator);
    defer fits.deinit();
    try fits.set("SIMPLE", "T", null);
    try fits.setInt("BITPIX", 8, null);
    try fits.setInt("NAXIS", 1, null);
    try fits.setInt("NAXIS1", 3, "pixels");
    try fits.set("OBJECT", "'demo'", null);
    try fits.setData(&[_]u8{ 1, 2, 3 });

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try fits.write(&output.writer);
    var parsed = try Fits.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    try std.testing.expectEqualStrings("T", parsed.getString("SIMPLE").?);
    try std.testing.expectEqual(@as(usize, 3), parsed.dataBytes().len);
    try parsed.set("OBJECT", "'edited'", null);
    try std.testing.expectEqualStrings("'edited'", parsed.getString("OBJECT").?);
}

test "missing dimensions are rejected" {
    var fits = Fits.init(std.testing.allocator);
    defer fits.deinit();
    try fits.set("SIMPLE", "T", null);
    try fits.setInt("BITPIX", 8, null);
    try fits.setInt("NAXIS", 1, null);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.MissingRequiredKeyword, fits.write(&output.writer));
}

test "read an indexed image extension" {
    var primary = Fits.init(std.testing.allocator);
    defer primary.deinit();
    try primary.set("SIMPLE", "T", null);
    try primary.setInt("BITPIX", 8, null);
    try primary.setInt("NAXIS", 0, null);

    var extension = Fits.init(std.testing.allocator);
    defer extension.deinit();
    try extension.set("XTENSION", "'IMAGE   '", null);
    try extension.setInt("BITPIX", 8, null);
    try extension.setInt("NAXIS", 1, null);
    try extension.setInt("NAXIS1", 2, null);
    try extension.setInt("PCOUNT", 1, null);
    try extension.setInt("GCOUNT", 1, null);
    try extension.setData(&[_]u8{ 10, 11, 12 });

    var file: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer file.deinit();
    try primary.write(&file.writer);
    try extension.write(&file.writer);

    var parsed = try Fits.parseExtension(std.testing.allocator, file.written(), 1);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("'IMAGE   '", parsed.getString("XTENSION").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 11, 12 }, parsed.dataBytes());
    try std.testing.expectError(error.InvalidFits, Fits.parseExtension(std.testing.allocator, file.written(), 2));
}
