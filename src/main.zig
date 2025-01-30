const std = @import("std");
const net = std.net;
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;
const Uri = std.Uri;
const http = std.http;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

fn parsePort(args: [][]const u8) !u16 {
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

fn handleConnection(allocator: Allocator, conn: net.StreamServer.Connection) !void {
    defer conn.stream.close();
    var read_buffer: [8192]u8 = undefined;
    var server = http.Server.init(conn, &read_buffer);

    while (true) {
        server.receiveHead() catch |err| {
            std.log.err("Failed to receive head: {}", .{err});
            return;
        };
        const request = server.request;

        // Log to stderr
        std.debug.print("{} {}\n", .{ request.method, request.target });

        // Handle the request
        handleRequest(allocator, &server, &request) catch |err| {
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

    // Sort directories first
    std.sort.sort(@TypeOf(entries.items[0]), entries.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
            if (a.is_dir and !b.is_dir) return true;
            if (!a.is_dir and b.is_dir) return false;
            return mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var html = std.ArrayList(u8).init(allocator);
    defer html.deinit();
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

fn handleRequest(allocator: Allocator, server: *http.Server, request: *http.Server.Request) !void {
    if (request.method != .GET) {
        try sendError(allocator, server, request, .method_not_allowed, "Method Not Allowed");
        return;
    }

    const root_path = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    const uri = try Uri.parse(request.target);
    const decoded_path = try percentDecode(allocator, uri.path);
    defer allocator.free(decoded_path);

    const resolved_path = try resolveRequestPath(allocator, root_path, decoded_path);
    defer allocator.free(resolved_path);

    const file = fs.openFileAbsolute(resolved_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try sendError(allocator, server, request, .not_found, "Not Found");
            return;
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.kind == .directory) {
        const index_path = try fs.path.join(allocator, &[_][]const u8{ resolved_path, "index.html" });
        defer allocator.free(index_path);

        if (fs.openFileAbsolute(index_path, .{})) |index_file| {
            index_file.close();
            try sendFile(allocator, server, request, index_path, "text/html");
        } else |_| {
            const html = try generateDirectoryListing(allocator, resolved_path, uri.path);
            defer allocator.free(html);
            try sendResponse(allocator, server, request, .ok, "text/html", html);
        }
    } else {
        const mime_type = try getMimeType(resolved_path);
        try sendFile(allocator, server, request, resolved_path, mime_type);
    }
}

fn sendResponse(
    server: *http.Server,
    request: *http.Server.Request,
    status: http.Status,
    content_type: []const u8,
    body: []const u8,
) !void {
    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = content_type },
    };
    var response = try server.respond(request, .{
        .status = status,
        .headers = &headers,
        .transfer_encoding = .{ .content_length = body.len },
    });
    try response.writeAll(body);
    try response.finish();
}

fn sendFile(
    allocator: Allocator,
    server: *http.Server,
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
    try sendResponse(allocator, server, request, .ok, mime_type, content);
}

fn sendError(
    allocator: Allocator,
    server: *http.Server,
    request: *http.Server.Request,
    status: http.Status,
    message: []const u8,
) !void {
    const body = try fmt.allocPrint(allocator, "{}: {s}", .{ status, message });
    defer allocator.free(body);
    try sendResponse(allocator, server, request, status, "text/plain", body);
}

fn percentDecode(allocator: Allocator, path: []const u8) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '%' and i + 2 < path.len) {
            const byte = try fmt.parseInt(u8, path[i + 1 .. i + 3], 16);
            try list.append(byte);
            i += 3;
        } else {
            try list.append(path[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice();
}

fn getMimeType(allocator: Allocator, path: []const u8) ![]const u8 {
    const ext = fs.path.extension(path);
    const mimeAssociations = std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer mimeAssociations.deinit();
    try mimeAssociations.put(".html", "text/html");
    try mimeAssociations.put(".css", "text/css");
    try mimeAssociations.put(".js", "application/javascript");
    try mimeAssociations.put(".png", "image/png");
    try mimeAssociations.put(".jpg", "image/jpeg");
    try mimeAssociations.put(".jpeg", "image/jpeg");
    try mimeAssociations.put(".gif", "image/gif");
    try mimeAssociations.put(".txt", "text/plain");

    return mimeAssociations.get(ext) orelse "application/octet-stream";
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const port = try parsePort(args);
    const address = try net.Address.resolveIp("0.0.0.0", port);
    var server = net.StreamServer.init(.{});
    try server.listen(address);

    std.debug.print("Server running on port {}\n", .{port});

    while (true) {
        const conn = try server.accept();
        const handle = try Thread.spawn(.{}, handleConnection, .{ allocator, conn });
        handle.detach();
    }
}
