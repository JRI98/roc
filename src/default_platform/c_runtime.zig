//! C-runtime default app support for non-Linux native targets.
//!
//! The dev backend emits symbol-ABI calls for compiled executables. This object
//! provides those symbols for the synthetic default platform on targets whose
//! process entrypoint is the C runtime's `main`.

const builtin = @import("builtin");

const RocStr = @import("roc_str_view").RocStr;

const c = switch (builtin.os.tag) {
    .windows => struct {
        extern fn malloc(size: usize) ?*anyopaque;
        extern fn free(ptr: ?*anyopaque) void;
        extern fn exit(code: i32) noreturn;
        extern fn _write(fd: i32, buf: [*]const u8, len: u32) i32;

        fn write(fd: i32, buf: [*]const u8, len: usize) isize {
            const chunk_len: u32 = @intCast(@min(len, 0x7fff_ffff));
            return _write(fd, buf, chunk_len);
        }
    },
    else => struct {
        extern fn malloc(size: usize) ?*anyopaque;
        extern fn free(ptr: ?*anyopaque) void;
        extern fn exit(code: i32) noreturn;
        extern fn write(fd: i32, buf: [*]const u8, len: usize) isize;
    },
};

const AllocationHeader = extern struct {
    raw: [*]u8,
    len: usize,
};

/// Set when an inline `expect` fails. A failed inline expect reports and lets
/// the program continue; the process exit turns an otherwise-successful status
/// into 1, matching the interpreter's default-app behavior.
var inline_expect_failed: bool = false;

/// The Roc entrypoint the synthetic default platform exports.
extern fn roc_default_start_main() callconv(.c) i32;

/// The C runtime owns the process entrypoint: it initializes the Roc runtime,
/// runs the Roc entrypoint, and folds failed inline expects into the status.
export fn main() callconv(.c) c_int {
    roc_default_runtime_init();
    const status = roc_default_start_main();
    if (status == 0 and inline_expect_failed) return 1;
    return status;
}

export fn roc_default_runtime_init() callconv(.c) void {}

export fn roc_default_exit(code: u8) callconv(.c) noreturn {
    if (code == 0 and inline_expect_failed) c.exit(1);
    c.exit(code);
}

export fn roc_default_echo_line(str: RocStr) callconv(.c) void {
    var owned = str;
    const message = owned.asSlice();
    writeAll(1, message);
    owned.decref(roc_dealloc);
}

export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    writeAll(2, "[dbg] ");
    writeAll(2, bytes[0..len]);
    writeAll(2, "\n");
}

export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    inline_expect_failed = true;
    writeAll(2, "Expect failed: ");
    writeAll(2, bytes[0..len]);
    writeAll(2, "\n");
}

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) noreturn {
    writeAll(2, "Roc application crashed with this message:\n\n\t");
    writeAll(2, bytes[0..len]);
    writeAll(2, "\n\n");
    c.exit(1);
}

export fn roc_alloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const byte_alignment = normalizedAlignment(alignment);
    const total = length + byte_alignment + @sizeOf(AllocationHeader);
    const raw_any = c.malloc(total) orelse return null;
    const raw: [*]u8 = @ptrCast(raw_any);
    const user_addr = alignForward(@intFromPtr(raw) + @sizeOf(AllocationHeader), byte_alignment);
    const user: [*]u8 = @ptrFromInt(user_addr);
    allocationHeader(user).* = .{ .raw = raw, .len = length };
    return @ptrCast(user);
}

export fn roc_realloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const old_user: [*]u8 = @ptrCast(ptr);
    const old_header = allocationHeader(old_user).*;
    const new_ptr = roc_alloc(new_length, alignment) orelse return null;
    const new_user: [*]u8 = @ptrCast(new_ptr);

    const copy_len = @min(old_header.len, new_length);
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        new_user[i] = old_user[i];
    }
    roc_dealloc(ptr, alignment);
    return new_ptr;
}

export fn roc_dealloc(ptr: *anyopaque, _: usize) callconv(.c) void {
    const user: [*]u8 = @ptrCast(ptr);
    c.free(@ptrCast(allocationHeader(user).raw));
}

fn allocationHeader(user: [*]u8) *AllocationHeader {
    return @ptrCast(@alignCast(user - @sizeOf(AllocationHeader)));
}

fn normalizedAlignment(alignment: usize) usize {
    return @max(alignment, @alignOf(usize));
}

fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn writeAll(fd: i32, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = c.write(fd, remaining.ptr, remaining.len);
        if (written <= 0) return;
        remaining = remaining[@intCast(written)..];
    }
}
