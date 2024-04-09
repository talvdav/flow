const std = @import("std");
const tp = @import("thespian");

const Self = @This();
const module_name = @typeName(Self);
pub const Error = error{ OutOfMemory, Exit };

pid: ?tp.pid,

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const Selection = struct {
    begin: Cursor = Cursor{},
    end: Cursor = Cursor{},
};

pub fn create() Error!Self {
    return .{ .pid = try Process.create() };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        pid.send(.{"shutdown"}) catch {};
        pid.deinit();
        self.pid = null;
    }
}

const Process = struct {
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    backwards: std.ArrayList(Entry),
    current: ?Entry = null,
    forwards: std.ArrayList(Entry),
    receiver: Receiver,

    const Receiver = tp.Receiver(*Process);
    const outer_a = std.heap.page_allocator;

    const Entry = struct {
        file_path: []const u8,
        cursor: Cursor,
        selection: ?Selection = null,
    };

    pub fn create() Error!tp.pid {
        const self = try outer_a.create(Process);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(outer_a),
            .a = self.arena.allocator(),
            .backwards = std.ArrayList(Entry).init(self.a),
            .forwards = std.ArrayList(Entry).init(self.a),
            .receiver = Receiver.init(Process.receive, self),
        };
        return tp.spawn_link(self.a, self, Process.start, module_name) catch |e| tp.exit_error(e);
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *Process) void {
        self.clear_backwards();
        self.clear_forwards();
        self.backwards.deinit();
        self.forwards.deinit();
        if (self.current) |entry| self.a.free(entry.file_path);
        self.arena.deinit();
        outer_a.destroy(self);
    }

    fn clear_backwards(self: *Process) void {
        return self.clear_table(&self.backwards);
    }

    fn clear_forwards(self: *Process) void {
        return self.clear_table(&self.forwards);
    }

    fn clear_table(self: *Process, table: *std.ArrayList(Entry)) void {
        for (table.items) |entry| self.a.free(entry.file_path);
        table.clearAndFree();
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        var c: Cursor = .{};
        var s: Selection = .{};
        var cb: usize = 0;
        var file_path: []const u8 = undefined;

        return if (try m.match(.{ "U", tp.extract(&file_path), tp.extract(&c.col), tp.extract(&c.row) }))
            self.update(.{ .file_path = file_path, .cursor = c })
        else if (try m.match(.{ "U", tp.extract(&file_path), tp.extract(&c.col), tp.extract(&c.row), tp.extract(&s.begin.row), tp.extract(&s.begin.col), tp.extract(&s.end.row), tp.extract(&s.end.col) }))
            self.update(.{ .file_path = file_path, .cursor = c, .selection = s })
        else if (try m.match(.{ "B", tp.extract(&cb) }))
            self.back(from, cb)
        else if (try m.match(.{ "F", tp.extract(&cb) }))
            self.forward(from, cb)
        else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn update(self: *Process, entry_: Entry) tp.result {
        const entry: Entry = .{
            .file_path = self.a.dupe(u8, entry_.file_path) catch |e| return tp.exit_error(e),
            .cursor = entry_.cursor,
            .selection = entry_.selection,
        };
        errdefer self.a.free(entry.file_path);
        defer self.current = entry;

        if (isdupe(self.current, entry))
            return self.a.free(self.current.?.file_path);

        if (isdupe(self.backwards.getLastOrNull(), entry)) {
            if (self.current) |current| self.forwards.append(current) catch {};
            const top = self.backwards.pop();
            self.a.free(top.file_path);
            tp.trace(tp.channel.all, tp.message.fmt(.{ "location", "back", entry.file_path, entry.cursor.row, entry.cursor.col, self.backwards.items.len, self.forwards.items.len }));
        } else if (isdupe(self.forwards.getLastOrNull(), entry)) {
            if (self.current) |current| self.backwards.append(current) catch {};
            const top = self.forwards.pop();
            self.a.free(top.file_path);
            tp.trace(tp.channel.all, tp.message.fmt(.{ "location", "forward", entry.file_path, entry.cursor.row, entry.cursor.col, self.backwards.items.len, self.forwards.items.len }));
        } else if (self.current) |current| {
            self.backwards.append(current) catch |e| return tp.exit_error(e);
            tp.trace(tp.channel.all, tp.message.fmt(.{ "location", "new", current.file_path, current.cursor.row, current.cursor.col, self.backwards.items.len, self.forwards.items.len }));
            self.clear_forwards();
        }
    }

    fn isdupe(a_: ?Entry, b: Entry) bool {
        return if (a_) |a| std.mem.eql(u8, a.file_path, b.file_path) and a.cursor.row == b.cursor.row else false;
    }

    fn back(self: *const Process, from: tp.pid_ref, cb_addr: usize) void {
        const cb: *CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);
        if (self.backwards.getLastOrNull()) |entry|
            cb(from, entry.file_path, entry.cursor, entry.selection);
    }

    fn forward(self: *Process, from: tp.pid_ref, cb_addr: usize) void {
        const cb: *CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);
        if (self.forwards.getLastOrNull()) |entry|
            cb(from, entry.file_path, entry.cursor, entry.selection);
    }
};

pub fn update(self: Self, file_path: []const u8, cursor: Cursor, selection: ?Selection) void {
    if (self.pid) |pid| {
        if (selection) |sel|
            pid.send(.{ "U", file_path, cursor.col, cursor.row, sel.begin.row, sel.begin.col, sel.end.row, sel.end.col }) catch {}
        else
            pid.send(.{ "U", file_path, cursor.col, cursor.row }) catch {};
    }
}

pub const CallBack = fn (from: tp.pid_ref, file_path: []const u8, cursor: Cursor, selection: ?Selection) void;

pub fn back(self: Self, cb: *const CallBack) tp.result {
    if (self.pid) |pid| try pid.send(.{ "B", @intFromPtr(cb) });
}

pub fn forward(self: Self, cb: *const CallBack) tp.result {
    if (self.pid) |pid| try pid.send(.{ "F", @intFromPtr(cb) });
}
