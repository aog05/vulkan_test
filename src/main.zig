const std = @import("std");
const triangle = @import("triangle.zig").TriangleApp;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer if (gpa.deinit() == .leak) @panic("Memory leak detected");

    var triangle_app = triangle.init(gpa.allocator());
    defer triangle_app.deinit();

    triangle_app.run();
}
