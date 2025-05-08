const std = @import("std");
const net = std.net;
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;
const Uri = std.Uri;
const http = std.http;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const sort = std.sort;

const mime_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".html", "text/html" },
    .{ ".htm", "text/html" },
    .{ ".css", "text/css" },
    .{ ".js", "application/javascript" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".txt", "text/plain" },
    .{ ".json", "application/json" },
});

fn parsePort(args: [][]u8) !u16 {
    var port: u16 = 8080;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--port") or mem.eql(u8, args[i], "-p")) {
            if (i + 1 >= args.len) return error.MissingPort;
            port = try fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        }
    }
    return port;
}

fn handleConnection(allocator: Allocator, conn: net.Server.Connection) void {
    defer conn.stream.close();
    var read_buffer: [8192]u8 = undefined;
    var server = http.Server.init(conn, &read_buffer);

    while (true) {
        var request = server.receiveHead() catch |err| {
            std.log.err("Failed to receive head: {}", .{err});
            return;
        };

        std.debug.print("{} {s}\n", .{ request.head.method, request.head.target });

        handleRequest(allocator, &request) catch |err| {
            std.log.err("Failed to handle request: {}", .{err});
            return;
        };
    }
}

fn resolveRequestPath(allocator: Allocator, root_path: []const u8, request_path: []const u8) ![]const u8 {
    const resolved = try fs.path.resolve(allocator, &[_][]const u8{ root_path, request_path });
    errdefer allocator.free(resolved);

    if (!mem.startsWith(u8, resolved, root_path)) {
        return error.PathTraversal;
    }
    return resolved;
}

fn generateDirectoryListing(allocator: Allocator, dir_path: []const u8, uri_path: []const u8) ![]const u8 {
    var dir = try fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList(struct { name: []u8, is_dir: bool }).init(allocator);
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        const is_dir = entry.kind == .directory;
        try entries.append(.{ .name = name, .is_dir = is_dir });
    }

    sort.block(@TypeOf(entries.items[0]), entries.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
            // directories first, then lexicographically
            if (a.is_dir and !b.is_dir) return true;
            if (!a.is_dir and b.is_dir) return false;
            return mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var html = std.ArrayList(u8).init(allocator);
    try html.writer().print(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Index of {s}</title></head>
        \\<body>
        \\<h1>Index of {s}</h1>
        \\<ul>
    , .{ uri_path, uri_path });

    for (entries.items) |entry| {
        const href = if (entry.is_dir)
            try fmt.allocPrint(allocator, "{s}/", .{entry.name})
        else
            entry.name;
        defer if (entry.is_dir) allocator.free(href);

        try html.writer().print(
            \\<li><a href="{s}">{s}{s}</a></li>
        , .{ href, entry.name, if (entry.is_dir) "/" else "" });
    }

    try html.appendSlice("</ul></body></html>");
    return html.toOwnedSlice();
}

fn handleRequest(allocator: Allocator, request: *http.Server.Request) !void {
    if (request.head.method != .GET) {
        try sendError(allocator, request, .method_not_allowed, "Method Not Allowed");
        return;
    }

    const root_path = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    const uri = try Uri.parse(request.head.target);
    const decoded_path = try percentDecode(allocator, uri.path.percent_encoded);
    defer allocator.free(decoded_path);

    const resolved_path = try resolveRequestPath(allocator, root_path, decoded_path);
    defer allocator.free(resolved_path);

    const file = fs.openFileAbsolute(resolved_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => {
            // const dir_stat = (fs.openDirAbsolute(resolved_path, .{}) catch |e| {
            //     if (e == error.NotDir) {
            //         try sendError(allocator, server, request, .not_found, "Not Found");
            //         return;
            //     }
            //     return e;
            // }).stat() catch {
            //     try sendError(allocator, server, request, .not_found, "Not Found");
            //     return;
            // };

            const index_path = try fs.path.join(allocator, &.{ resolved_path, "index.html" });
            defer allocator.free(index_path);

            if (fs.openFileAbsolute(index_path, .{})) |index_file| {
                defer index_file.close();
                try sendFile(allocator, request, index_path, "text/html");
            } else |_| {
                const uri_path = try uri.path.toRawMaybeAlloc(allocator);
                const html = try generateDirectoryListing(allocator, resolved_path, uri_path);
                defer allocator.free(html);
                try sendResponse(request, .ok, "text/html", html);
            }
            return;
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.kind == .directory) {
        const index_path = try fs.path.join(allocator, &.{ resolved_path, "index.html" });
        defer allocator.free(index_path);

        if (fs.openFileAbsolute(index_path, .{})) |index_file| {
            defer index_file.close();
            try sendFile(allocator, request, index_path, "text/html");
        } else |_| {
            const uri_path = try uri.path.toRawMaybeAlloc(allocator);
            const html = try generateDirectoryListing(allocator, resolved_path, uri_path);
            defer allocator.free(html);
            try sendResponse(request, .ok, "text/html", html);
        }
    } else {
        const ext = fs.path.extension(resolved_path);
        const mime_type = mime_types.get(ext) orelse "application/octet-stream";
        try sendFile(allocator, request, resolved_path, mime_type);
    }
}

fn sendResponse(
    request: *http.Server.Request,
    status: http.Status,
    content_type: []const u8,
    body: []const u8,
) !void {
    const headers = [_]http.Header{.{
        .name = "Content-Type",
        .value = content_type,
    }};
    try request.respond(body, .{
        .status = status,
        .extra_headers = &headers,
    });
}

fn sendFile(
    allocator: Allocator,
    request: *http.Server.Request,
    path: []const u8,
    mime_type: []const u8,
) !void {
    const file = try fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    _ = try file.readAll(content);
    try sendResponse(request, .ok, mime_type, content);
}

fn sendError(
    allocator: Allocator,
    request: *http.Server.Request,
    status: http.Status,
    message: []const u8,
) !void {
    const body = try fmt.allocPrint(allocator, "{}: {s}", .{ status, message });
    defer allocator.free(body);
    try sendResponse(request, status, "text/plain", body);
}

fn percentDecode(allocator: Allocator, path: []const u8) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '%' and i + 2 < path.len) {
            const byte = fmt.parseInt(u8, path[i + 1 .. i + 3], 16) catch {
                try list.append(path[i]);
                i += 1;
                continue;
            };
            try list.append(byte);
            i += 3;
        } else {
            try list.append(path[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var args_list = std.ArrayList([]u8).init(allocator);
    defer args_list.deinit();

    const zero: [1]u8 = [_]u8{0};
    for (raw_args) |zstr| {
        // find the length up to—but not including—the first zero
        const len = std.mem.indexOf(u8, zstr, zero[0..]) orelse zstr.len;
        try args_list.append(zstr[0..len]);
    }

    const port = try parsePort(try args_list.toOwnedSlice());
    const address = try net.Address.resolveIp("0.0.0.0", port);

    const listen_opts = net.Address.ListenOptions{
        .reuse_address = true,
    };

    var tcp_server = try address.listen(listen_opts);

    var thread_pool: Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator });
    defer thread_pool.deinit();

    std.debug.print("Server running on port {}\n", .{port});

    while (true) {
        const conn = try tcp_server.accept();
        try thread_pool.spawn(handleConnection, .{ allocator, conn });
    }
}
