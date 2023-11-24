const std = @import("std");
const w4 = @import("wasm4.zig");

const arena_half_size_pt: i32 = 100000;
const arena_half_size_pt_f32: f32 = @floatFromInt(arena_half_size_pt);

const speed_points: f32 = 90;
const min_radius_pt = 500;

fn XY(comptime T: type) type {
    return struct { x: T, y: T };
}

const Blob = struct {
    pos_pt: XY(i32),
    radius_pt: i32,
    // Angle is in radians in the range of [0,2PI) (includes 0 but not 2PI).
    // 0 is to the right, PI/2 is upward and so on.
    angle: f32,
};

const global = struct {
    pub var rand: std.rand.DefaultPrng = undefined;
    pub var blobs: [20]Blob = undefined;
    var ai_controls = [_]Control{ .none } ** (global.blobs.len - 1);
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

// returns a random f32 in the range [0,1) (includes 0 but not 1)
// it uses (byte_count*8) bits of granualarity
fn getRandomScale(comptime byte_count: comptime_int) f32 {
    const UInt = @Type(std.builtin.Type{
        .Int = .{
            .signedness = .unsigned,
            .bits = byte_count * 8,
        },
    });
    var buf: [byte_count]u8 = undefined;
    global.rand.fill(&buf);
    const r = std.mem.readInt(UInt, &buf, .Big);
    return @as(f32, @floatFromInt(r)) / (@as(f32, 1.0) + @as(f32, std.math.maxInt(UInt)));
}

fn getRandomCoord() i32 {
    const mult = getRandomScale(2);
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
    return 80 + @divTrunc((coord_x - global.blobs[0].pos_pt.x), points_per_pixel);
}
fn ptToPxY(points_per_pixel: i32, coord_y: i32) i32 {
    if (points_per_pixel <= 0) unreachable;
    return 80 + @divTrunc((coord_y - global.blobs[0].pos_pt.y), points_per_pixel);
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

fn getFreqs(radius: f32) struct { start: u16, end: u16 } {
    //log("radius {}", .{@as(i32, @intFromFloat(@floor(radius)))});
    if (radius <= min_radius_pt * 2) return .{
        .start = 2000,
        .end   = 5000,
    };
    if (radius <= min_radius_pt * 4) return .{
        .start = 1000,
        .end   = 2000,
    };
    if (radius <= min_radius_pt * 8) return .{
        .start = 400,
        .end   = 1000,
    };
    if (radius <= min_radius_pt * 16) return .{
        .start = 100,
        .end   = 400,
    };
    return .{
        .start = 50,
        .end   = 100,
    };
}

fn updateAngle(blob: *Blob, control: Control) void {
    switch (control) {
        .none => {},
        .dec => {
            blob.angle -= angle_speed;
            if (blob.angle < 0) {
                blob.angle += _2pi;
                std.debug.assert(blob.angle >= 0);
            }
        },
        .inc => {
            blob.angle += angle_speed;
            if (blob.angle > _2pi) {
                blob.angle -= _2pi;
                std.debug.assert(blob.angle <= _2pi);
            }
        },
    }
}

const max_eat_volume = 20;

fn eatTone(blob: *const Blob) void {
    const freqs = getFreqs(@floatFromInt(blob.radius_pt));
    //log("tone {} to {}", .{freqs.start, freqs.send});
    const freq_arg = @as(u32, freqs.end) << 16 | freqs.start;

    const tone: struct {
        volume: u32,
        pan: u32,
    } = blk: {
        if (blob == &global.blobs[0]) break :blk .{
            .volume = max_eat_volume,
            .pan = 0,
        };
        const diff_x: f32 = @floatFromInt(blob.pos_pt.x - global.blobs[0].pos_pt.x);
        const diff_y: f32 = @floatFromInt(blob.pos_pt.y - global.blobs[0].pos_pt.y);
        const dist = std.math.sqrt(diff_x * diff_x + diff_y * diff_y);
        if (dist < 0) @panic("impossible?");
        const max_distance = arena_half_size_pt_f32 * 1.5;
        const ratio: f32 = 1.0 - @min(dist, max_distance) / max_distance;
        const pan_threshold = arena_half_size_pt_f32 / 3;
        break :blk .{
            .volume = @intFromFloat((ratio*ratio) * (max_eat_volume * 0.4)),
            .pan =
                if (diff_x > pan_threshold) w4.TONE_PAN_RIGHT
                else if (diff_x < -pan_threshold) w4.TONE_PAN_LEFT
                else 0
        };
    };
    w4.tone(freq_arg, 5, tone.volume, tone.pan);
}

export fn start() void {
    global.rand = std.rand.DefaultPrng.init(0);
    for (&points_buf) |*pt| {
        pt.* = getRandomPoint();
    }
    global.blobs[0] = .{
        .pos_pt = .{ .x = 0, .y = 0 },
        .radius_pt = min_radius_pt,
        .angle = 0,
    };
    for (global.blobs[1..], 0..) |*other, i| {
        other.* = .{
            .pos_pt = getRandomPoint(),
            .radius_pt = min_radius_pt,
            .angle = _2pi * getRandomScale(2),
        };
        global.ai_controls[i] = .none;
    }
}

export fn update() void {
    updateAngle(&global.blobs[0], getControl(
        0 != (w4.GAMEPAD1.* & w4.BUTTON_LEFT),
        0 != (w4.GAMEPAD1.* & w4.BUTTON_RIGHT),
    ));

    for (global.blobs[1..], 0..) |*blob, i| {
        const control_ref = &global.ai_controls[i];
        {
            var buf: [1]u8 = undefined;
            global.rand.fill(&buf);
            switch (control_ref.*) {
                .none => switch (buf[0]) {
                    0...29 => control_ref.* = .dec,
                    30...59 => control_ref.* = .inc,
                    60...255 => {},
                },
                .dec => switch (buf[0]) {
                    0...39 => control_ref.* = .none,
                    40...255 => {},
                },
                .inc => switch (buf[0]) {
                    0...39 => control_ref.* = .none,
                    40...255 => {},
                },
            }
        }
        updateAngle(blob, control_ref.*);
    }

    // custom size change control (for development)
    switch (getControl(
        0 != (w4.GAMEPAD1.* & w4.BUTTON_DOWN),
        0 != (w4.GAMEPAD1.* & w4.BUTTON_UP),
    )) {
        .none => {},
        .dec => global.blobs[0].radius_pt = @max(
            global.blobs[0].radius_pt - 10, 10
        ),
        .inc => global.blobs[0].radius_pt += 10,
    }

    var sines: [global.blobs.len]f32 = undefined;
    var cosines: [global.blobs.len]f32 = undefined;

    // move blobs
    for (&global.blobs, 0..) |*blob, i| {
        // TODO: get slower as you get bigger
        sines[i] = std.math.sin(blob.angle);
        cosines[i] = std.math.cos(blob.angle);

        const diff_x: i32 = @intFromFloat(@floor(speed_points * cosines[i]));
        const diff_y: i32 = @intFromFloat(@floor(speed_points * sines[i]));
        const min: i32 = -arena_half_size_pt + blob.radius_pt;
        const max: i32 =  arena_half_size_pt - blob.radius_pt;
        blob.pos_pt = .{
            .x = clamp(i32, blob.pos_pt.x + diff_x, min, max),
            .y = clamp(i32, blob.pos_pt.y + diff_y, min, max),
        };
    }

    // TODO: this *might* need some optimization?
    for (&global.blobs) |*blob| {
        for (&points_buf) |*pt| {
            const diff_x: f32 = @floatFromInt(pt.x - blob.pos_pt.x);
            const diff_y: f32 = @floatFromInt(pt.y - blob.pos_pt.y);
            const dist = std.math.sqrt(diff_x * diff_x + diff_y * diff_y);
            if (dist < 0) @panic("here"); // impossible right?
            if (dist >= @as(f32, @floatFromInt(blob.radius_pt))) continue;

            //log("eat point {}!", .{i});
            eatTone(blob);
            {
                pt.* = getRandomPoint();
                blob.radius_pt += 10;
            }
        }
    }


    const desired_blob_radius_px = 10;
    const points_per_pixel: i32 = @divTrunc(
        global.blobs[0].radius_pt,
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
    for (&global.blobs, 0..) |*blob, i| {
        {
            const px = ptToPx(points_per_pixel, .{
                .x = blob.pos_pt.x - blob.radius_pt,
                .y = blob.pos_pt.y - blob.radius_pt,
            });
            w4.DRAW_COLORS.* = 0x03;
            const size: i32 = @divTrunc(blob.radius_pt * 2, points_per_pixel);
            //log("player {},{} size={}", .{px.x, px.y, size});
            w4.oval(px.x, px.y, @intCast(size), @intCast(size));
        }

        // draw the direction dot
        {
            const radius_pt: f32 = @as(f32, @floatFromInt(blob.radius_pt));
            const px = ptToPx(points_per_pixel, .{
                .x = blob.pos_pt.x + @as(i32, @intFromFloat(radius_pt * cosines[i])),
                .y = blob.pos_pt.y + @as(i32, @intFromFloat(radius_pt * sines[i])),
            });
            w4.DRAW_COLORS.* = 0x41;
            w4.oval(px.x - 2, px.y - 2, 4, 4);
        }
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
                @divTrunc(global.blobs[0].pos_pt.x, 100),
                @divTrunc(global.blobs[0].pos_pt.y, 100),
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
