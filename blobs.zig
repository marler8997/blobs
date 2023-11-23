const std = @import("std");
const w4 = @import("wasm4.zig");

const arena_half_size_pt: i32 = 100000;
const arena_half_size_pt_f32: f32 = @floatFromInt(arena_half_size_pt);

const speed_points: f32 = 90;

fn XY(comptime T: type) type {
    return struct { x: T, y: T };
}
const global = struct {
    pub var rand: std.rand.DefaultPrng = undefined;
    pub var pos = XY(i32){ .x = 0, .y = 0 };
    pub var blob_radius_pt: i32 = 1000;
    // Angle is in radians in the range of [0,2PI) (includes 0 but not 2PI).
    // 0 is to the right, PI/2 is upward and so on.
    pub var angle: f32 = 0;
};

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [300]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch @panic("codebug");
    w4.trace(str);
}

pub fn panic(
    msg: []const u8,
    trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    log("panic: {s}", .{msg});
    if (trace) |t| {
        w4.trace("dumping error trace...");
        std.debug.dumpStackTrace(t.*);
    } else {
        w4.trace("no error trace");
    }
    w4.trace("dumping current stack...");
    std.debug.dumpCurrentStackTrace(ret_addr);
    w4.trace("breakpoint");
    while (true) { @breakpoint(); }
}

const Control = enum { none, dec, inc };
pub fn getControl(dec: bool, inc: bool) Control {
    if (dec) return if (inc) .none else .dec;
    return if (inc) return .inc else .none;
}

const angle_speed: f32 = @as(f32, std.math.pi) / @as(f32, 40);
const _2pi = 2 * std.math.pi;

var points_buf: [5000]XY(i32) = undefined;

fn getRandomCoord() i32 {
    var buf: [1]u8 = undefined;
    global.rand.fill(&buf);
    const mult = @as(f32, @floatFromInt(buf[0])) / @as(f32, 256);
    const slot: i32 = @intFromFloat(arena_half_size_pt_f32 * 2 * mult);
    return slot - arena_half_size_pt;
}

fn getRandomPoint() XY(i32) {
    return .{
        .x = getRandomCoord(),
        .y = getRandomCoord(),
    };
}

fn ptToPxX(points_per_pixel: i32, coord_x: i32) i32 {
    if (points_per_pixel <= 0) unreachable;
    return 80 + @divTrunc((coord_x - global.pos.x), points_per_pixel);
}
fn ptToPxY(points_per_pixel: i32, coord_y: i32) i32 {
    if (points_per_pixel <= 0) unreachable;
    return 80 + @divTrunc((coord_y - global.pos.y), points_per_pixel);
}
fn ptToPx(points_per_pixel: i32, pt: XY(i32)) XY(i32) {
    return XY(i32){
        .x = ptToPxX(points_per_pixel, pt.x),
        .y = ptToPxY(points_per_pixel, pt.y),
    };
}

fn clamp(comptime T: type, val: T, min: T, max: T) T {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}

export fn start() void {
    global.rand = std.rand.DefaultPrng.init(0);
    for (&points_buf) |*pt| {
        pt.* = getRandomPoint();
    }
}

export fn update() void {

    switch (getControl(
        0 != (w4.GAMEPAD1.* & w4.BUTTON_LEFT),
        0 != (w4.GAMEPAD1.* & w4.BUTTON_RIGHT),
    )) {
        .none => {},
        .dec => {
            global.angle -= angle_speed;
            if (global.angle < 0) {
                global.angle += _2pi;
                std.debug.assert(global.angle >= 0);
            }
        },
        .inc => {
            global.angle += angle_speed;
            if (global.angle > _2pi) {
                global.angle -= _2pi;
                std.debug.assert(global.angle <= _2pi);
            }
        },
    }
    switch (getControl(
        0 != (w4.GAMEPAD1.* & w4.BUTTON_DOWN),
        0 != (w4.GAMEPAD1.* & w4.BUTTON_UP),
    )) {
        .none => {},
        .dec => global.blob_radius_pt = @max(
            global.blob_radius_pt - 10, 10
        ),
        .inc => global.blob_radius_pt += 10,
    }

    const sin = std.math.sin(global.angle);
    const cos = std.math.cos(global.angle);

    {
        // TODO: get slower as you get bigger
        const diff_x: i32 = @intFromFloat(@floor(speed_points * cos));
        const diff_y: i32 = @intFromFloat(@floor(speed_points * sin));
        const min: i32 = -arena_half_size_pt + global.blob_radius_pt;
        const max: i32 =  arena_half_size_pt - global.blob_radius_pt;
        global.pos = .{
            .x = clamp(i32, global.pos.x + diff_x, min, max),
            .y = clamp(i32, global.pos.y + diff_y, min, max),
        };
    }

    for (&points_buf) |*pt| {
        const diff_x: f32 = @floatFromInt(pt.x - global.pos.x);
        const diff_y: f32 = @floatFromInt(pt.y - global.pos.y);
        const dist = std.math.sqrt(diff_x * diff_x + diff_y * diff_y);
        if (dist < 0) @panic("here"); // impossible right?
        if (dist >= @as(f32, @floatFromInt(global.blob_radius_pt))) continue;
        //log("eat point {}!", .{i});
        const radius_pt_ft: f32 = @floatFromInt(global.blob_radius_pt);
        const freq_beg: u16 = 30 + @as(u16, @intFromFloat(500000 / radius_pt_ft));
        const freq_end: u16 = 30 + @as(u16, @intFromFloat(400000 / radius_pt_ft));
        //log("tone {} to {}", .{freq_beg, freq_end});
        const freq = @as(u32, freq_beg) << 16 | freq_end;
        w4.tone(freq, 5, 20, 0);
        {
            pt.* = getRandomPoint();
            global.blob_radius_pt += 20;
        }
    }


    const desired_blob_radius_px = 10;
    const points_per_pixel: i32 = @divTrunc(
        global.blob_radius_pt,
        desired_blob_radius_px
    );
    drawBars(points_per_pixel, .x);
    drawBars(points_per_pixel, .y);

    // draw dots
    for (&points_buf) |*pt| {
        const px = ptToPx(points_per_pixel, pt.*);
        w4.DRAW_COLORS.* = 0x4;
        w4.rect(px.x, px.y, 1, 1);
    }

    // draw player circle
    {
        const px = ptToPx(points_per_pixel, .{
            .x = global.pos.x - global.blob_radius_pt,
            .y = global.pos.y - global.blob_radius_pt,
        });
        w4.DRAW_COLORS.* = 0x03;
        const size: i32 = @divTrunc(global.blob_radius_pt * 2, points_per_pixel);
        //log("player {},{} size={}", .{px.x, px.y, size});
        w4.oval(px.x, px.y, @intCast(size), @intCast(size));
    }
    // draw the direction dot
    {
        const radius_pt: f32 = @as(f32, @floatFromInt(global.blob_radius_pt));
        const px = ptToPx(points_per_pixel, .{
            .x = global.pos.x + @as(i32, @intFromFloat(radius_pt * cos)),
            .y = global.pos.y + @as(i32, @intFromFloat(radius_pt * sin)),
        });
        w4.DRAW_COLORS.* = 0x41;
        w4.oval(px.x - 2, px.y - 2, 4, 4);
    }
    // draw arena border
    {
        const top_left = ptToPx(points_per_pixel, .{
            .x = -arena_half_size_pt,
            .y = -arena_half_size_pt,
        });
        const bottom_right = ptToPx(points_per_pixel, .{
            .x = arena_half_size_pt,
            .y = arena_half_size_pt,
        });
        w4.DRAW_COLORS.* = 0x40;
        w4.rect(
            top_left.x, top_left.y,
            @intCast(bottom_right.x - top_left.x),
            @intCast(bottom_right.y - top_left.y),
        );
    }

    {
        var buf: [100]u8 = undefined;
        const str = std.fmt.bufPrint(
            &buf,
            "{},{}",
            .{
                @divTrunc(global.pos.x, 100),
                @divTrunc(global.pos.y, 100),
            },
        ) catch @panic("codebug");
        w4.DRAW_COLORS.* = 0x04;
        w4.text(str, 0, 0);
    }
}

fn drawBars(points_per_pixel: i32, dir: enum { x, y}) void {
    w4.DRAW_COLORS.* = 0x02;
    const grid_size_pt = 8000;
    var i_pt: i32 = -arena_half_size_pt;
    while (true) {
        i_pt += grid_size_pt;
        if (i_pt >= arena_half_size_pt) break;
        const i_px = switch (dir) {
            .x => ptToPxX(points_per_pixel, i_pt),
            .y => ptToPxY(points_per_pixel, i_pt),
        };
        switch (dir) {
            .x => w4.vline(i_px, 0, 160),
            .y => w4.hline(0, i_px, 160),
        }
    }
}
