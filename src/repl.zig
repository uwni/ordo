const std = @import("std");
const tty = @import("tty.zig");
const visa = @import("visa/root.zig");
const repl_parser = @import("repl/parser.zig");
const LineEditor = @import("repl/LineEditor.zig");
const repl_prompt = tty.styledText("repl> ", .{.aqua});
const err_label = tty.styledText("error:", .{.red});
const repl_whitespace = repl_parser.whitespace;
const State = repl_parser.State;
const Open = repl_parser.Open;
const Command = repl_parser.Command;
const ParseError = repl_parser.ParseError;
const parseCommand = repl_parser.parseCommand;
const isValidName = repl_parser.isValidName;

/// Recommended stdin buffer size for line-oriented REPL input.
pub const stdin_buffer_bytes: usize = LineEditor.repl_max_line_bytes + 1;

/// Configurable instrument settings exposed by the `set` command.
const Setting = enum {
    timeout_ms,
    read_termination,
    write_termination,
    query_delay_ms,
    chunk_size,

    const map = std.StaticStringMap(Setting).initComptime(.{
        .{ "timeout_ms", .timeout_ms },
        .{ "read_termination", .read_termination },
        .{ "write_termination", .write_termination },
        .{ "query_delay_ms", .query_delay_ms },
        .{ "chunk_size", .chunk_size },
    });

    fn parse(key: []const u8) ?Setting {
        return map.get(key);
    }
};

const Termination = @import("instrument.zig").Termination;

/// Tagged value for a parsed `set` command, ready for application.
const SettingValue = union(Setting) {
    timeout_ms: u32,
    read_termination: Termination,
    write_termination: Termination,
    query_delay_ms: u32,
    chunk_size: usize,
};

/// Opens a VISA resource manager and starts the interactive REPL loop.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    resource_addr: ?[]const u8,
    visa_lib: ?[]const u8,
    reader: *std.Io.Reader,
    out: *std.Io.Writer,
) !void {
    var visa_diag: visa.loader.LoadDiagnostic = undefined;
    const vtable = visa.loader.load(visa_lib, &visa_diag) catch |err| {
        out.writeAll(err_label ++ " ") catch {};
        visa_diag.write(out, err) catch {};
        return err;
    };
    var rm: visa.ResourceManager = try .init(&vtable);
    defer rm.deinit();

    var ctx = ReplContext{
        .allocator = allocator,
        .rm = &rm,
    };
    defer ctx.closeAll();

    if (resource_addr) |addr| {
        const name = try ctx.openConnection(addr, null);
        try out.print(comptime tty.styledText("Connected to {s} ({s})", .{.green}) ++ "\n", .{ addr, name });
    }

    try printHelp(out, ctx.state());
    try out.flush();
    defer out.flush() catch {};
    if ((std.Io.File.stdin().isTty(io) catch false)) {
        var editor = LineEditor.init(allocator, std.Io.File.stdin(), out);
        defer editor.deinit();
        try runLoop(allocator, reader, out, &ctx, &editor);
    } else {
        try runLoop(allocator, reader, out, &ctx, null);
    }
}

/// A named connection to a VISA instrument.
const NamedConnection = struct {
    name: []u8,
    addr: []u8,
    instrument: visa.Instrument,
    /// Write termination override. Null means no termination.
    write_termination: ?Termination = null,
};

/// Production REPL context wrapping a VISA resource manager and multiple instruments.
const ReplContext = struct {
    allocator: std.mem.Allocator,
    rm: *visa.ResourceManager,
    connections: std.ArrayList(NamedConnection) = .empty,
    selected: ?usize = null,
    next_id: usize = 1,

    fn state(self: *const ReplContext) State {
        if (self.selected != null) return .selected;
        if (self.connections.items.len > 0) return .connected;
        return .disconnected;
    }

    fn selectedName(self: *const ReplContext) ?[]const u8 {
        if (self.selected) |idx| return self.connections.items[idx].name;
        return null;
    }

    fn openConnection(self: *ReplContext, addr: []const u8, name: ?[]const u8) ![]const u8 {
        var inst: visa.Instrument = .init(self.rm.session, self.rm.vtable);
        try inst.open(self.allocator, addr, .{});
        errdefer inst.deinit();
        const addr_copy = try self.allocator.dupe(u8, addr);
        errdefer self.allocator.free(addr_copy);
        const name_copy = if (name) |n|
            try self.allocator.dupe(u8, n)
        else blk: {
            const auto = try std.fmt.allocPrint(self.allocator, "d{d}", .{self.next_id});
            self.next_id += 1;
            break :blk auto;
        };
        errdefer self.allocator.free(name_copy);
        try self.connections.append(self.allocator, .{ .name = name_copy, .addr = addr_copy, .instrument = inst });
        if (self.selected == null) self.selected = self.connections.items.len - 1;
        return name_copy;
    }

    fn closeByName(self: *ReplContext, target: []const u8) bool {
        for (self.connections.items, 0..) |conn, i| {
            if (std.mem.eql(u8, conn.name, target)) {
                if (self.selected) |sel| {
                    if (sel == i) {
                        self.selected = null;
                    } else if (sel > i) {
                        self.selected = sel - 1;
                    }
                }
                var removed = self.connections.orderedRemove(i);
                removed.instrument.deinit();
                self.allocator.free(removed.addr);
                self.allocator.free(removed.name);
                return true;
            }
        }
        return false;
    }

    fn closeAll(self: *ReplContext) void {
        for (self.connections.items) |*conn| {
            conn.instrument.deinit();
            self.allocator.free(conn.addr);
            self.allocator.free(conn.name);
        }
        self.connections.deinit(self.allocator);
        self.selected = null;
    }

    fn findByName(self: *const ReplContext, target: []const u8) ?usize {
        for (self.connections.items, 0..) |conn, i| {
            if (std.mem.eql(u8, conn.name, target)) return i;
        }
        return null;
    }

    fn findByAddr(self: *const ReplContext, addr: []const u8) ?usize {
        for (self.connections.items, 0..) |conn, i| {
            if (std.mem.eql(u8, conn.addr, addr)) return i;
        }
        return null;
    }

    fn selectByName(self: *ReplContext, target: []const u8) bool {
        for (self.connections.items, 0..) |conn, i| {
            if (std.mem.eql(u8, conn.name, target)) {
                self.selected = i;
                return true;
            }
        }
        return false;
    }

    fn listResources(self: *ReplContext, allocator: std.mem.Allocator) !visa.ResourceList {
        return self.rm.listResources(allocator);
    }

    fn writeAt(self: *ReplContext, idx: usize, payload: []const u8) !void {
        var conn = &self.connections.items[idx];
        if (conn.write_termination) |wt| {
            const suffix = wt.constSlice();
            const full = try self.allocator.alloc(u8, payload.len + suffix.len);
            defer self.allocator.free(full);
            @memcpy(full[0..payload.len], payload);
            @memcpy(full[payload.len..][0..suffix.len], suffix);
            return conn.instrument.write(full);
        }
        return conn.instrument.write(payload);
    }

    fn readAt(self: *ReplContext, allocator: std.mem.Allocator, idx: usize) ![]u8 {
        return self.connections.items[idx].instrument.readToOwned(allocator);
    }

    fn queryAt(self: *ReplContext, allocator: std.mem.Allocator, idx: usize, payload: []const u8) ![]u8 {
        try self.writeAt(idx, payload);
        try self.connections.items[idx].instrument.waitQueryDelay();
        return self.readAt(allocator, idx);
    }

    fn applyOption(self: *ReplContext, _: std.mem.Allocator, idx: usize, sv: SettingValue) !void {
        var conn = &self.connections.items[idx];
        switch (sv) {
            .timeout_ms => |v| {
                conn.instrument.options.timeout_ms = v;
                try conn.instrument.applyOptions();
            },
            .read_termination => |v| {
                conn.instrument.options.read_termination = v;
                try conn.instrument.applyOptions();
            },
            .write_termination => |v| conn.write_termination = v,
            .query_delay_ms => |v| conn.instrument.options.query_delay_ms = v,
            .chunk_size => |v| conn.instrument.options.chunk_size = v,
        }
    }
};

/// Runs the command prompt loop until EOF or a quit command is received.
/// When `editor` is non-null, uses interactive line editing via tty;
/// otherwise falls back to plain line-oriented reading from `reader`.
fn runLoop(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    out: *std.Io.Writer,
    ctx: anytype,
    editor: ?*LineEditor,
) !void {
    var running = true;
    while (running) {
        var prompt_buf: [128]u8 = undefined;
        const prompt = buildPrompt(ctx, &prompt_buf);

        const line: ?[]const u8 = if (editor) |ed|
            try ed.editLine(prompt)
        else blk: {
            try out.writeAll(prompt);
            try out.flush();
            break :blk readLine(reader) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.StreamTooLong => {
                    try out.print(err_label ++ " input line exceeds {d} bytes\n", .{LineEditor.repl_max_line_bytes});
                    continue;
                },
            };
        };

        const input = line orelse {
            if (editor == null) try out.writeAll("\n");
            break;
        };

        const trimmed = std.mem.trim(u8, input, repl_whitespace);
        if (trimmed.len == 0) continue;

        const command = parseCommand(trimmed) catch |err| {
            try printParseError(out, err);
            continue;
        };

        running = executeCommand(allocator, ctx, command, reader, out) catch |err| {
            try out.print(err_label ++ " {any}\n", .{err});
            continue;
        };
    }
}

fn buildPrompt(ctx: anytype, buf: []u8) []const u8 {
    if (ctx.selectedName()) |name| {
        return std.fmt.bufPrint(buf, comptime tty.styledText("repl[{s}]> ", .{.aqua}), .{
            name,
        }) catch repl_prompt;
    }
    return repl_prompt;
}

/// Executes one parsed command and returns whether the REPL should continue running.
fn executeCommand(
    allocator: std.mem.Allocator,
    ctx: anytype,
    command: Command,
    reader: *std.Io.Reader,
    out: *std.Io.Writer,
) !bool {
    switch (command) {
        .help => try printHelp(out, ctx.state()),
        .quit => return false,
        .list => try handleList(allocator, ctx, out),
        .open => |o| try handleOpen(allocator, ctx, o, reader, out),
        .close => |name| try handleClose(ctx, name, out),
        .select => |name| try handleSelect(ctx, name, out),
        .write => |w| try handleWrite(ctx, w.target, w.payload, out),
        .read => |target| try handleRead(allocator, ctx, target, out),
        .query => |q| try handleQuery(allocator, ctx, q.target, q.payload, out),
        .set => |s| try handleSet(allocator, ctx, s.target, s.payload, out),
    }
    return true;
}

fn handleOpen(
    allocator: std.mem.Allocator,
    ctx: anytype,
    args: Open,
    reader: *std.Io.Reader,
    out: *std.Io.Writer,
) !void {
    if (args.name) |n| {
        if (!isValidName(n)) {
            try out.print(err_label ++ " invalid name '{s}'; use [a-zA-Z][a-zA-Z0-9_]*, must not be a command name\n", .{n});
            return;
        }
        if (ctx.findByName(n) != null) {
            try out.print(err_label ++ " name '{s}' is already in use\n", .{n});
            return;
        }
    }
    if (args.addr) |addr| {
        if (ctx.findByAddr(addr) != null) {
            try out.print(err_label ++ " already connected to {s}\n", .{addr});
            return;
        }
        const name = try ctx.openConnection(addr, args.name);
        try out.print(comptime tty.styledText("Connected to {s} ({s})", .{.green}) ++ "\n", .{ addr, name });
        return;
    }
    // Interactive mode: scan and prompt for index.
    const count = try printOpenCandidates(allocator, ctx, out);
    if (count == 0) return;
    try out.writeAll("Enter index: ");
    try out.flush();
    const idx_line = readLine(reader) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.StreamTooLong => {
            try out.writeAll(err_label ++ " input too long\n");
            return;
        },
    } orelse return;
    const idx_trimmed = std.mem.trim(u8, idx_line, repl_whitespace);
    const index = std.fmt.parseInt(usize, idx_trimmed, 10) catch {
        try out.writeAll(err_label ++ " invalid index\n");
        return;
    };
    if (index == 0 or index > count) {
        try out.writeAll(err_label ++ " index out of range\n");
        return;
    }
    var resources = try ctx.listResources(allocator);
    defer resources.deinit();
    // Map the user index to the nth unconnected resource.
    var n: usize = 0;
    var addr: ?[]const u8 = null;
    for (resources.items) |resource| {
        if (ctx.findByAddr(resource) != null) continue;
        n += 1;
        if (n == index) {
            addr = resource;
            break;
        }
    }
    const target_addr = addr orelse {
        try out.writeAll(err_label ++ " instrument list changed; try again\n");
        return;
    };
    const name = try ctx.openConnection(target_addr, args.name);
    try out.print(comptime tty.styledText("Connected to {s} ({s})", .{.green}) ++ "\n", .{ target_addr, name });
}

fn handleClose(ctx: anytype, target: ?[]const u8, out: *std.Io.Writer) !void {
    if (target) |name| {
        if (!ctx.closeByName(name)) {
            try out.print(err_label ++ " unknown connection '{s}'\n", .{name});
            return;
        }
        try out.print("Disconnected from {s}.\n", .{name});
        return;
    }
    // Close selected — save name before freeing.
    const sel = ctx.selectedName() orelse {
        try out.writeAll(err_label ++ " no instrument selected; use 'close <name>'\n");
        return;
    };
    var name_buf: [64]u8 = undefined;
    const len = @min(sel.len, name_buf.len);
    @memcpy(name_buf[0..len], sel[0..len]);
    _ = ctx.closeByName(name_buf[0..len]);
    try out.print("Disconnected from {s}.\n", .{name_buf[0..len]});
}

fn handleSelect(ctx: anytype, target: ?[]const u8, out: *std.Io.Writer) !void {
    const name = target orelse {
        ctx.selected = null;
        try out.writeAll("Deselected.\n");
        return;
    };
    if (!ctx.selectByName(name)) {
        try out.print(err_label ++ " unknown connection '{s}'\n", .{name});
        return;
    }
    try out.print("Selected {s}.\n", .{name});
}

const no_target_msg = err_label ++ " no instrument selected; use 'select <name>' or '<name>.command ...'\n";

fn resolveTarget(ctx: anytype, target: ?[]const u8, out: *std.Io.Writer) !?usize {
    if (target) |name| {
        return ctx.findByName(name) orelse {
            try out.print(err_label ++ " unknown connection '{s}'\n", .{name});
            return null;
        };
    }
    return ctx.selected orelse {
        try out.writeAll(no_target_msg);
        return null;
    };
}

fn handleWrite(ctx: anytype, target: ?[]const u8, payload: []const u8, out: *std.Io.Writer) !void {
    const idx = try resolveTarget(ctx, target, out) orelse return;
    try ctx.writeAt(idx, payload);
    try out.writeAll("ok\n");
}

fn handleRead(allocator: std.mem.Allocator, ctx: anytype, target: ?[]const u8, out: *std.Io.Writer) !void {
    const idx = try resolveTarget(ctx, target, out) orelse return;
    const response = try ctx.readAt(allocator, idx);
    defer allocator.free(response);
    try printResponse(out, response);
}

fn handleQuery(allocator: std.mem.Allocator, ctx: anytype, target: ?[]const u8, payload: []const u8, out: *std.Io.Writer) !void {
    const idx = try resolveTarget(ctx, target, out) orelse return;
    const response = try ctx.queryAt(allocator, idx, payload);
    defer allocator.free(response);
    try printResponse(out, response);
}

fn handleSet(allocator: std.mem.Allocator, ctx: anytype, target: ?[]const u8, payload: []const u8, out: *std.Io.Writer) !void {
    const idx = try resolveTarget(ctx, target, out) orelse return;
    const space = std.mem.indexOfAny(u8, payload, repl_whitespace) orelse {
        try out.writeAll(err_label ++ " usage: set <key> <value>\n");
        return;
    };
    const key = payload[0..space];
    const raw_value = std.mem.trimStart(u8, payload[space..], repl_whitespace);
    if (raw_value.len == 0) {
        try out.writeAll(err_label ++ " usage: set <key> <value>\n");
        return;
    }
    const setting = Setting.parse(key) orelse {
        try out.print(err_label ++ " unknown setting '{s}'\n", .{key});
        return;
    };
    const sv: SettingValue = switch (setting) {
        .timeout_ms => .{ .timeout_ms = std.fmt.parseInt(u32, raw_value, 10) catch {
            try out.print(err_label ++ " invalid integer '{s}'\n", .{raw_value});
            return;
        } },
        .query_delay_ms => .{ .query_delay_ms = std.fmt.parseInt(u32, raw_value, 10) catch {
            try out.print(err_label ++ " invalid integer '{s}'\n", .{raw_value});
            return;
        } },
        .chunk_size => .{ .chunk_size = std.fmt.parseInt(usize, raw_value, 10) catch {
            try out.print(err_label ++ " invalid integer '{s}'\n", .{raw_value});
            return;
        } },
        .read_termination, .write_termination => blk: {
            const t = unescape(raw_value) catch |err| {
                const msg = switch (err) {
                    error.InvalidEscape => "invalid escape sequence",
                    error.Overflow => "termination too long (max 4 bytes)",
                };
                try out.print(err_label ++ " {s}: '{s}'\n", .{ msg, raw_value });
                return;
            };
            break :blk if (setting == .read_termination)
                .{ .read_termination = t }
            else
                .{ .write_termination = t };
        },
    };
    try ctx.applyOption(allocator, idx, sv);
    try out.writeAll("ok\n");
}

fn unescape(input: []const u8) error{ InvalidEscape, Overflow }!Termination {
    var out: Termination = .{};
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            out.append(switch (input[i + 1]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                else => return error.InvalidEscape,
            }) catch return error.Overflow;
            i += 2;
        } else {
            out.append(input[i]) catch return error.Overflow;
            i += 1;
        }
    }
    return out;
}

/// Handles the `list` command: shows all resources without numbering.
/// Connected resources display their name; selected one is highlighted.
fn handleList(allocator: std.mem.Allocator, ctx: anytype, out: *std.Io.Writer) !void {
    var resources = try ctx.listResources(allocator);
    defer resources.deinit();
    if (resources.items.len == 0) {
        try out.writeAll("No instruments found.\n");
        return;
    }
    for (resources.items) |resource| {
        if (ctx.findByAddr(resource)) |ci| {
            const conn = ctx.connections.items[ci];
            const is_selected = if (ctx.selected) |sel| sel == ci else false;
            if (is_selected) {
                try out.print("  " ++ comptime tty.styledText("{s}) {s}", .{ .bold, .green }) ++ "\n", .{ conn.name, resource });
            } else {
                try out.print("  " ++ comptime tty.styledText("{s}) {s}", .{.yellow}) ++ "\n", .{ conn.name, resource });
            }
        } else {
            try out.print("  {s}\n", .{resource});
        }
    }
}

/// Scans for VISA resources and prints only unconnected ones, numbered for selection.
/// Returns the count of displayed (unconnected) resources.
fn printOpenCandidates(allocator: std.mem.Allocator, ctx: anytype, out: *std.Io.Writer) !usize {
    var resources = try ctx.listResources(allocator);
    defer resources.deinit();
    if (resources.items.len == 0) {
        try out.writeAll("No instruments found.\n");
        return 0;
    }
    var count: usize = 0;
    for (resources.items) |resource| {
        if (ctx.findByAddr(resource) != null) continue;
        count += 1;
        try out.print("  {d}) {s}\n", .{ count, resource });
    }
    if (count == 0) {
        try out.writeAll("All instruments already connected.\n");
    }
    return count;
}

/// Reads one newline-delimited command line from the REPL input stream.
fn readLine(reader: *std.Io.Reader) error{ ReadFailed, StreamTooLong }!?[]const u8 {
    return reader.takeDelimiter('\n') catch |err| switch (err) {
        error.ReadFailed => error.ReadFailed,
        error.StreamTooLong => {
            _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                error.EndOfStream => {},
                error.ReadFailed => return error.ReadFailed,
            };
            return error.StreamTooLong;
        },
    };
}

/// Prints the list of supported REPL commands based on connection state.
fn printHelp(out: *std.Io.Writer, current_state: State) !void {
    switch (current_state) {
        .disconnected => try out.writeAll(
            \\Commands:
            \\  list               List current connections.
            \\  open [<addr>]      Connect by address, or scan interactively.
            \\                     Use 'open <addr> as <name>' to assign a name.
            \\  help               Show this help text.
            \\  quit               Leave the REPL.
            \\
        ),
        .connected => try out.writeAll(
            \\Commands:
            \\  <name>.write <cmd> Send a command to a named instrument.
            \\  <name>.read        Read a response from a named instrument.
            \\  <name>.query <cmd> Send a command and read the response.
            \\  <name>.set <k> <v> Set an instrument option (e.g. write_termination \n).
            \\  select <name>      Select an instrument for direct commands.
            \\  list               List current connections.
            \\  open [<addr>]      Connect to another instrument.
            \\  close <name>       Disconnect a named instrument.
            \\  help               Show this help text.
            \\  quit               Leave the REPL.
            \\
        ),
        .selected => try out.writeAll(
            \\Commands:
            \\  write <command>    Send a command to the selected instrument.
            \\  read               Read a response from the selected instrument.
            \\  query <command>    Send a command and read the response.
            \\  set <key> <value>  Set an instrument option (e.g. write_termination \n).
            \\  <name>.write <cmd> Send a command to a named instrument.
            \\  <name>.read        Read a response from a named instrument.
            \\  <name>.query <cmd> Send a command and read the response.
            \\  <name>.set <k> <v> Set an instrument option on a named instrument.
            \\  select [<name>]    Switch or deselect the active instrument.
            \\  list               List current connections.
            \\  open [<addr>]      Connect to another instrument.
            \\  close [<name>]     Disconnect (default: selected).
            \\  help               Show this help text.
            \\  quit               Leave the REPL.
            \\
        ),
    }
}

/// Prints a friendly parse error followed by a usage hint.
fn printParseError(out: *std.Io.Writer, err: ParseError) !void {
    const message = switch (err) {
        error.UnknownCommand => "unknown command",
        error.MissingCommandPayload => "missing command payload",
        error.UnexpectedCommandPayload => "read does not accept a payload",
    };
    try out.print(err_label ++ " {s}; type 'help' for usage\n", .{message});
}

/// Writes a response to the terminal, preserving existing trailing newlines when present.
fn printResponse(out: *std.Io.Writer, response: []const u8) !void {
    if (response.len == 0) {
        try out.writeAll("(empty)\n");
        return;
    }

    try out.writeAll(response);
    if (response[response.len - 1] != '\n') {
        try out.writeAll("\n");
    }
}

/// Mock resource list for testing.
const MockResourceList = struct {
    items: []const []const u8,
    fn deinit(_: *MockResourceList) void {}
};

/// Test double used to exercise the REPL loop without a real VISA session.
const MockContext = struct {
    const MockConnection = struct { name: []u8, addr: []u8 };
    const RecordedWrite = struct { target: []u8, payload: []u8 };

    allocator: std.mem.Allocator,
    writes: std.ArrayList(RecordedWrite) = .empty,
    applied_settings: std.ArrayList(SettingValue) = .empty,
    responses: []const []const u8,
    read_index: usize = 0,
    mock_resources: []const []const u8 = &.{},
    connections: std.ArrayList(MockConnection) = .empty,
    selected: ?usize = null,
    next_id: usize = 1,

    fn init(allocator: std.mem.Allocator, responses: []const []const u8) MockContext {
        return .{
            .allocator = allocator,
            .responses = responses,
        };
    }

    fn deinit(self: *MockContext) void {
        for (self.writes.items) |item| {
            self.allocator.free(item.target);
            self.allocator.free(item.payload);
        }
        self.writes.deinit(self.allocator);
        self.applied_settings.deinit(self.allocator);
        for (self.connections.items) |conn| {
            self.allocator.free(conn.name);
            self.allocator.free(conn.addr);
        }
        self.connections.deinit(self.allocator);
    }

    fn state(self: *const MockContext) State {
        if (self.selected != null) return .selected;
        if (self.connections.items.len > 0) return .connected;
        return .disconnected;
    }

    fn selectedName(self: *const MockContext) ?[]const u8 {
        if (self.selected) |idx| return self.connections.items[idx].name;
        return null;
    }

    fn openConnection(self: *MockContext, addr: []const u8, name: ?[]const u8) ![]const u8 {
        const name_copy = if (name) |n|
            try self.allocator.dupe(u8, n)
        else blk: {
            const auto = try std.fmt.allocPrint(self.allocator, "d{d}", .{self.next_id});
            self.next_id += 1;
            break :blk auto;
        };
        errdefer self.allocator.free(name_copy);
        const addr_copy = try self.allocator.dupe(u8, addr);
        errdefer self.allocator.free(addr_copy);
        try self.connections.append(self.allocator, .{ .name = name_copy, .addr = addr_copy });
        if (self.selected == null) self.selected = self.connections.items.len - 1;
        return name_copy;
    }

    fn closeByName(self: *MockContext, target: []const u8) bool {
        for (self.connections.items, 0..) |conn, i| {
            if (std.mem.eql(u8, conn.name, target)) {
                if (self.selected) |sel| {
                    if (sel == i) {
                        self.selected = null;
                    } else if (sel > i) {
                        self.selected = sel - 1;
                    }
                }
                const removed = self.connections.orderedRemove(i);
                self.allocator.free(removed.addr);
                self.allocator.free(removed.name);
                return true;
            }
        }
        return false;
    }

    fn findByName(self: *const MockContext, target: []const u8) ?usize {
        for (self.connections.items, 0..) |conn, i| {
            if (std.mem.eql(u8, conn.name, target)) return i;
        }
        return null;
    }

    fn findByAddr(self: *const MockContext, addr: []const u8) ?usize {
        for (self.connections.items, 0..) |conn, i| {
            if (std.mem.eql(u8, conn.addr, addr)) return i;
        }
        return null;
    }

    fn selectByName(self: *MockContext, target: []const u8) bool {
        for (self.connections.items, 0..) |conn, i| {
            if (std.mem.eql(u8, conn.name, target)) {
                self.selected = i;
                return true;
            }
        }
        return false;
    }

    fn listResources(self: *MockContext, _: std.mem.Allocator) !MockResourceList {
        return .{ .items = self.mock_resources };
    }

    fn writeAt(self: *MockContext, idx: usize, payload: []const u8) !void {
        const t = try self.allocator.dupe(u8, self.connections.items[idx].name);
        errdefer self.allocator.free(t);
        const p = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(p);
        try self.writes.append(self.allocator, .{ .target = t, .payload = p });
    }

    fn readAt(self: *MockContext, allocator: std.mem.Allocator, _: usize) ![]u8 {
        if (self.read_index >= self.responses.len) return error.EndOfStream;
        const response = self.responses[self.read_index];
        self.read_index += 1;
        return try allocator.dupe(u8, response);
    }

    fn queryAt(self: *MockContext, allocator: std.mem.Allocator, idx: usize, payload: []const u8) ![]u8 {
        try self.writeAt(idx, payload);
        return self.readAt(allocator, idx);
    }

    fn applyOption(self: *MockContext, _: std.mem.Allocator, _: usize, sv: SettingValue) !void {
        try self.applied_settings.append(self.allocator, sv);
    }
};

test "repl auto-selects first connection" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR
        \\write CONF:VOLT 10
        \\query *IDN?
        \\read
        \\close
        \\quit
        \\
    ;

    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{ "TEST,MODEL,123\n", "5.000\n" });
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    try std.testing.expectEqual(@as(usize, 2), ctx.writes.items.len);
    try std.testing.expectEqualStrings("d1", ctx.writes.items[0].target);
    try std.testing.expectEqualStrings("CONF:VOLT 10", ctx.writes.items[0].payload);
    try std.testing.expectEqualStrings("d1", ctx.writes.items[1].target);
    try std.testing.expectEqualStrings("*IDN?", ctx.writes.items[1].payload);
    const output = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Connected to USB0::INSTR (d1)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "ok\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "TEST,MODEL,123\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "5.000\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Disconnected from d1.\n"));
}

test "repl multi-connection with targeted commands" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR as dmm
        \\open TCPIP0::1.1::INSTR as psu
        \\dmm.query *IDN?
        \\psu.write VOLT 3.3
        \\close psu
        \\close dmm
        \\quit
        \\
    ;

    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{"DMM,Model,123\n"});
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    try std.testing.expectEqual(@as(usize, 2), ctx.writes.items.len);
    try std.testing.expectEqualStrings("dmm", ctx.writes.items[0].target);
    try std.testing.expectEqualStrings("*IDN?", ctx.writes.items[0].payload);
    try std.testing.expectEqualStrings("psu", ctx.writes.items[1].target);
    try std.testing.expectEqualStrings("VOLT 3.3", ctx.writes.items[1].payload);
}

test "repl select and deselect" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR as dmm
        \\open TCPIP0::INSTR as psu
        \\select psu
        \\write VOLT 5.0
        \\select
        \\write VOLT 1.0
        \\quit
        \\
    ;

    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    // First write goes to psu (explicitly selected).
    try std.testing.expectEqual(@as(usize, 1), ctx.writes.items.len);
    try std.testing.expectEqualStrings("psu", ctx.writes.items[0].target);
    try std.testing.expectEqualStrings("VOLT 5.0", ctx.writes.items[0].payload);
    // Second write should fail (deselected, no target).
    const output = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "no instrument selected"));
}

test "repl list shows resources with connection status" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR as dmm
        \\open TCPIP0::INSTR as psu
        \\list
        \\quit
        \\
    ;

    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    ctx.mock_resources = &.{ "USB0::INSTR", "TCPIP0::INSTR", "GPIB0::22::INSTR" };
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    // list shows no numbers; connected resources show name, unconnected show bare address.
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "dmm) USB0::INSTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "psu) TCPIP0::INSTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "GPIB0::22::INSTR"));
    // Unconnected resource must NOT have a number prefix.
    try std.testing.expect(!std.mem.containsAtLeast(u8, output, 1, "3) GPIB0::22::INSTR"));
}

test "repl interactive open scans and prompts" {
    const gpa = std.testing.allocator;
    const input = "open\n2\nclose d1\nquit\n";

    var reader: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    ctx.mock_resources = &.{ "USB0::0x0957::INSTR", "TCPIP0::192.168.1.1::INSTR" };
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "1) USB0::0x0957::INSTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "2) TCPIP0::192.168.1.1::INSTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Enter index:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Connected to TCPIP0::192.168.1.1::INSTR (d1)"));
}

test "repl interactive open with invalid index" {
    const gpa = std.testing.allocator;
    const input = "open\n5\nquit\n";

    var reader: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    ctx.mock_resources = &.{"USB0::INSTR"};
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "index out of range"));
}

test "repl rejects duplicate address" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR as dmm
        \\open USB0::INSTR as dmm2
        \\quit
        \\
    ;

    var reader: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "already connected to USB0::INSTR"));
}

test "repl rejects commands when disconnected" {
    const gpa = std.testing.allocator;
    const input =
        \\write CONF:VOLT 10
        \\read
        \\query *IDN?
        \\close
        \\quit
        \\
    ;

    var reader: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    // write, read, query → "no instrument selected"; close → "no instrument selected"
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 4, "no instrument selected"));
}

test "repl set applies options" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR as dmm
        \\set timeout_ms 5000
        \\set query_delay_ms 100
        \\set chunk_size 2048
        \\set write_termination \n
        \\set read_termination \r\n
        \\quit
        \\
    ;

    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    // All five set commands should succeed.
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 5, "ok\n"));
    // Verify applied settings.
    try std.testing.expectEqual(@as(usize, 5), ctx.applied_settings.items.len);
    try std.testing.expectEqual(@as(u32, 5000), ctx.applied_settings.items[0].timeout_ms);
    try std.testing.expectEqual(@as(u32, 100), ctx.applied_settings.items[1].query_delay_ms);
    try std.testing.expectEqual(@as(usize, 2048), ctx.applied_settings.items[2].chunk_size);
    try std.testing.expectEqualStrings("\n", ctx.applied_settings.items[3].write_termination.constSlice());
    try std.testing.expectEqualStrings("\r\n", ctx.applied_settings.items[4].read_termination.constSlice());
}

test "repl targeted set with name.set" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR as dmm
        \\open TCPIP0::INSTR as psu
        \\select psu
        \\dmm.set timeout_ms 3000
        \\quit
        \\
    ;

    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "ok\n"));
    try std.testing.expectEqual(@as(usize, 1), ctx.applied_settings.items.len);
    try std.testing.expectEqual(@as(u32, 3000), ctx.applied_settings.items[0].timeout_ms);
}

test "repl set rejects unknown key" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR as dmm
        \\set baud_rate 9600
        \\quit
        \\
    ;

    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "unknown setting"));
    try std.testing.expectEqual(@as(usize, 0), ctx.applied_settings.items.len);
}

test "repl set rejects invalid integer" {
    const gpa = std.testing.allocator;
    const input =
        \\open USB0::INSTR as dmm
        \\set timeout_ms abc
        \\quit
        \\
    ;

    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var ctx: MockContext = .init(gpa, &.{});
    defer ctx.deinit();

    try runLoop(gpa, &reader, &out.writer, &ctx, null);

    const output = out.written();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "invalid integer"));
    try std.testing.expectEqual(@as(usize, 0), ctx.applied_settings.items.len);
}

test "unescape termination literals" {
    const newline = try unescape("\\n");
    try std.testing.expectEqualStrings("\n", newline.constSlice());

    const crlf = try unescape("\\r\\n");
    try std.testing.expectEqualStrings("\r\n", crlf.constSlice());

    const backslash = try unescape("\\\\");
    try std.testing.expectEqualStrings("\\", backslash.constSlice());

    try std.testing.expectError(error.InvalidEscape, unescape("\\x"));
    try std.testing.expectError(error.Overflow, unescape("abcde"));
}
