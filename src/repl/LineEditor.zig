const std = @import("std");
const tty = @import("../tty.zig");
const cursorctl = tty.cursor;
const clearctl = tty.clear;
const LineEditor = @This();
const repl_parser = @import("parser.zig");

const repl_whitespace = repl_parser.whitespace;
pub const repl_max_line_bytes: usize = 4096;

/// Interactive line editor using tty raw mode and event handling.
/// Supports left/right arrow keys, Home/End, Backspace/Delete,
/// Up/Down for command history, and Ctrl+A/E/U/K/L shortcuts.
allocator: std.mem.Allocator,
stdin: std.Io.File,
out: *std.Io.Writer,
buf: [repl_max_line_bytes]u8 = undefined,
len: usize = 0,
pos: usize = 0,
history: std.ArrayList([]u8),
history_index: ?usize = null,
saved_buf: [repl_max_line_bytes]u8 = undefined,
saved_len: usize = 0,

pub fn init(allocator: std.mem.Allocator, stdin: std.Io.File, out: *std.Io.Writer) LineEditor {
    return .{
        .allocator = allocator,
        .stdin = stdin,
        .out = out,
        .history = .empty,
    };
}

pub fn deinit(self: *LineEditor) void {
    for (self.history.items) |item| self.allocator.free(item);
    self.history.deinit(self.allocator);
}

/// Reads one line of input with full editing support.
/// Returns the line content, or null on Ctrl+D (empty line) / EOF.
pub fn editLine(self: *LineEditor, prompt: []const u8) !?[]const u8 {
    // Flush pending output before entering raw mode, where \n no longer implies \r.
    try self.out.flush();
    var raw = try tty.enableRawMode(self.stdin.handle);
    defer raw.disableRawMode() catch {};

    self.len = 0;
    self.pos = 0;
    self.history_index = null;

    try self.out.writeAll(prompt);
    try self.out.flush();

    while (true) {
        const event = try tty.nextEvent(self.stdin);
        switch (event) {
            .key => |k| {
                if (k.mods.ctrl) {
                    switch (k.code) {
                        .char => |c| switch (c) {
                            'c' => {
                                try self.out.writeAll("^C\r\n");
                                try self.out.flush();
                                return "";
                            },
                            'd' => {
                                if (self.len == 0) {
                                    try self.out.writeAll("\r\n");
                                    try self.out.flush();
                                    return null;
                                }
                            },
                            'a' => try self.moveToPos(0, prompt),
                            'e' => try self.moveToPos(self.len, prompt),
                            'u' => {
                                const tail = self.len - self.pos;
                                std.mem.copyForwards(u8, self.buf[0..tail], self.buf[self.pos..self.len]);
                                self.len = tail;
                                self.pos = 0;
                                try self.refreshLine(prompt);
                            },
                            'k' => {
                                self.len = self.pos;
                                try self.refreshLine(prompt);
                            },
                            'l' => {
                                try clearctl.screen(self.out);
                                try self.refreshLine(prompt);
                            },
                            else => {},
                        },
                        else => {},
                    }
                } else {
                    switch (k.code) {
                        .char => |c| try self.insertChar(c, prompt),
                        .enter => {
                            try self.out.writeAll("\r\n");
                            try self.out.flush();
                            const line = self.buf[0..self.len];
                            const trimmed = std.mem.trim(u8, line, repl_whitespace);
                            if (trimmed.len > 0) try self.addHistory(trimmed);
                            return line;
                        },
                        .backspace => try self.deleteBack(prompt),
                        .delete => try self.deleteForward(prompt),
                        .left => {
                            if (self.pos > 0) {
                                // Skip back over UTF-8 continuation bytes.
                                self.pos -= 1;
                                while (self.pos > 0 and (self.buf[self.pos] & 0xC0) == 0x80) {
                                    self.pos -= 1;
                                }
                                try self.refreshLine(prompt);
                            }
                        },
                        .right => {
                            if (self.pos < self.len) {
                                // Skip forward over one full UTF-8 codepoint.
                                const byte_len = std.unicode.utf8ByteSequenceLength(self.buf[self.pos]) catch 1;
                                self.pos = @min(self.pos + byte_len, self.len);
                                try self.refreshLine(prompt);
                            }
                        },
                        .up => try self.historyPrev(prompt),
                        .down => try self.historyNext(prompt),
                        .home => try self.moveToPos(0, prompt),
                        .end => try self.moveToPos(self.len, prompt),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
}

pub fn insertChar(self: *LineEditor, ch: u21, prompt: []const u8) !void {
    var encoded: [4]u8 = undefined;
    const byte_len = std.unicode.utf8Encode(ch, &encoded) catch return;
    if (self.len + byte_len > repl_max_line_bytes) return;
    if (self.pos < self.len) {
        std.mem.copyBackwards(u8, self.buf[self.pos + byte_len .. self.len + byte_len], self.buf[self.pos..self.len]);
    }
    @memcpy(self.buf[self.pos..][0..byte_len], encoded[0..byte_len]);
    self.len += byte_len;
    self.pos += byte_len;
    if (self.pos == self.len) {
        try self.out.writeAll(encoded[0..byte_len]);
        try self.out.flush();
    } else {
        try self.refreshLine(prompt);
    }
}

pub fn deleteBack(self: *LineEditor, prompt: []const u8) !void {
    if (self.pos == 0) return;
    // Walk backwards to find the start of the previous UTF-8 codepoint.
    var del_len: usize = 1;
    while (del_len < self.pos and (self.buf[self.pos - del_len] & 0xC0) == 0x80) {
        del_len += 1;
    }
    std.mem.copyForwards(u8, self.buf[self.pos - del_len .. self.len - del_len], self.buf[self.pos..self.len]);
    self.pos -= del_len;
    self.len -= del_len;
    try self.refreshLine(prompt);
}

pub fn deleteForward(self: *LineEditor, prompt: []const u8) !void {
    if (self.pos >= self.len) return;
    const del_len = std.unicode.utf8ByteSequenceLength(self.buf[self.pos]) catch 1;
    const actual = @min(del_len, self.len - self.pos);
    std.mem.copyForwards(u8, self.buf[self.pos .. self.len - actual], self.buf[self.pos + actual .. self.len]);
    self.len -= actual;
    try self.refreshLine(prompt);
}

pub fn moveToPos(self: *LineEditor, new_pos: usize, prompt: []const u8) !void {
    if (new_pos == self.pos) return;
    self.pos = new_pos;
    try self.refreshLine(prompt);
}

pub fn historyPrev(self: *LineEditor, prompt: []const u8) !void {
    if (self.history.items.len == 0) return;
    if (self.history_index == null) {
        @memcpy(self.saved_buf[0..self.len], self.buf[0..self.len]);
        self.saved_len = self.len;
        self.history_index = self.history.items.len - 1;
    } else if (self.history_index.? > 0) {
        self.history_index.? -= 1;
    } else {
        return;
    }
    try self.loadHistoryEntry(self.history.items[self.history_index.?], prompt);
}

pub fn historyNext(self: *LineEditor, prompt: []const u8) !void {
    if (self.history_index == null) return;
    if (self.history_index.? + 1 < self.history.items.len) {
        self.history_index.? += 1;
        try self.loadHistoryEntry(self.history.items[self.history_index.?], prompt);
    } else {
        self.history_index = null;
        try self.loadHistoryEntry(self.saved_buf[0..self.saved_len], prompt);
    }
}

pub fn loadHistoryEntry(self: *LineEditor, content: []const u8, prompt: []const u8) !void {
    const copy_len = @min(content.len, repl_max_line_bytes);
    @memcpy(self.buf[0..copy_len], content[0..copy_len]);
    self.len = copy_len;
    self.pos = copy_len;
    try self.refreshLine(prompt);
}

pub fn addHistory(self: *LineEditor, line: []const u8) !void {
    if (self.history.items.len > 0) {
        if (std.mem.eql(u8, self.history.items[self.history.items.len - 1], line)) return;
    }
    const copy = try self.allocator.dupe(u8, line);
    try self.history.append(self.allocator, copy);
}

pub fn refreshLine(self: *LineEditor, prompt: []const u8) !void {
    try clearctl.lineStart(self.out);
    try self.out.writeAll(prompt);
    try self.out.writeAll(self.buf[0..self.len]);
    try clearctl.toEndOfLine(self.out);
    // Move cursor back from end-of-line to current position.
    // Count display columns of the tail (bytes after cursor).
    const tail_cols = displayWidth(self.buf[self.pos..self.len]);
    if (tail_cols > 0) try cursorctl.goLeft(self.out, tail_cols);
    try self.out.flush();
}

/// Count the display width (columns) of a UTF-8 string.
/// CJK characters (U+1100..U+115F, U+2E80..U+A4CF, U+AC00..U+D7AF,
/// U+F900..U+FAFF, U+FE10..U+FE6F, U+FF01..U+FF60, U+FFE0..U+FFE6,
/// U+1F000..U+1FAFF, U+20000..U+2FA1F) are counted as 2 columns;
/// other printable codepoints are 1 column.
pub fn displayWidth(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + byte_len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i..][0..byte_len]) catch {
            i += byte_len;
            continue;
        };
        cols += charWidth(cp);
        i += byte_len;
    }
    return cols;
}

pub fn charWidth(cp: u21) usize {
    // Common CJK / fullwidth ranges
    if ((cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or // CJK Radicals..Yi
        (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compat Ideographs
        (cp >= 0xFE10 and cp <= 0xFE6F) or // CJK Compat Forms..Small Forms
        (cp >= 0xFF01 and cp <= 0xFF60) or // Fullwidth Forms
        (cp >= 0xFFE0 and cp <= 0xFFE6) or // Fullwidth Signs
        (cp >= 0x1F000 and cp <= 0x1FAFF) or // Emojis
        (cp >= 0x20000 and cp <= 0x2FA1F) or // CJK Ext B..Compat Ideographs Sup
        (cp >= 0x30000 and cp <= 0x3134F)) // CJK Ext G..H
    {
        return 2;
    }
    return 1;
}
