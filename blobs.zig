const std = @import("std");
const w4 = @import("wasm4.zig");
const startlogo = @import("startlogo.zig");
const music = @import("music.zig");
const Tone = music.Tone;

const arena_half_size_pt: i32 = 100000;
const arena_half_size_pt_f32: f32 = @floatFromInt(arena_half_size_pt);
const max_points_per_pixel: i32 = (arena_half_size_pt*2) / 160;

const base_speed_pt: f32 = 90;
const max_size_penalty = 80;

// The starting mass is important to adjust strategy on how much
// more valuable eating another blob is vs eating indiviual pixels/nibbles
const starting_mass = 50;

const min_radius_pt = 500;
fn massToRadius(mass: i32) i32 {
    if (mass == 0) @panic("codebug");
    if (mass < starting_mass) std.debug.panic("codebug: mass {} too small", .{mass});
    const part: f32 = @floatFromInt(mass - starting_mass);
    const extra: i32 = @intFromFloat(@round(200 * std.math.sqrt(part)));
    return min_radius_pt + extra;
}

const max_digest_per_frame = 10;

const intro_messages = [_][]const u8 {
    "Be Fruitful and\nBlob!",
    "Take off\nevery Blob!",
    "All your Blob are\nbelong to us!",
};

fn XY(comptime T: type) type {
    return struct { x: T, y: T };
}

const Blob = struct {
    pos_pt: XY(i32),
    mass: i32,
    // Angle is in radians in the range of [0,2PI) (includes 0 but not 2PI).
    // 0 is to the right, PI/2 is upward and so on.
    angle: f32,
    dashing: bool,
    digesting: i32,
};

const MultiTone = struct {
    loop: bool,
    tones: []const Tone,
    volume: u32,
    flags: u32,
    current_tone: usize = 0,
    current_tone_frame: u32 = 0,
};

const StartMenu = struct {
    button1_released: bool = false,
};
const Play = struct {
    button1_released: bool = false,
    intro_frame: ?u32,
    player: [4]Player = .{.{}, .{}, .{}, .{} },

    pub fn myPlayer(self: *Play) *Player {
        return &self.player[w4.NETPLAY.* & 0x3];
    }
    pub const Player = struct {
        last_points_per_pixel: ?i32 = null,
    };
};
const Settings = struct {
    button1_released: bool = false,
    button_left_released: bool = false,
    button_right_released: bool = false,
    button_up_released: bool = false,
    button_down_released: bool = false,
    selection: enum {
        return_to_game,
        appearance,
        new_game,
    } = .return_to_game,
};

const global = struct {
    var disk_state = [_]u8 { 0 } ** 1;
    pub var rand_seed: u8 = 0;
    pub var mode: union(enum) {
        start_menu: StartMenu,
        play: Play,
        settings: Settings,
    } = .{ .start_menu = .{} };
    pub var rand: std.rand.DefaultPrng = undefined;
    pub var blobs: [60]Blob = undefined;
    pub fn myBlob() *Blob {
        return &blobs[w4.NETPLAY.* & 0x3];
    }

    var ai_controls = [_]Control{ .none } ** (global.blobs.len - 4);
    var multitones_buf: [20]MultiTone = undefined;
    var multitones_count: usize = 0;
    var my_eat_tone_frame: ?u8 = null;

};

fn netplay() bool { return 0 != (w4.NETPLAY.* & 4); }

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
const tau = std.math.tau;

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

fn ptToPxX(points_per_pixel: i32, center_pt: i32, pt: i32) i32 {
    if (points_per_pixel <= 0) unreachable;
    return 80 + @divTrunc(pt - center_pt, points_per_pixel);
}
fn ptToPxY(points_per_pixel: i32, center_pt: i32, pt: i32) i32 {
    if (points_per_pixel <= 0) unreachable;
    return 80 + @divTrunc(pt - center_pt, points_per_pixel);
}
fn ptToPx(points_per_pixel: i32, center_pt: XY(i32), pt: XY(i32)) XY(i32) {
    return XY(i32){
        .x = ptToPxX(points_per_pixel, center_pt.x, pt.x),
        .y = ptToPxY(points_per_pixel, center_pt.y, pt.y),
    };
}

fn clamp(comptime T: type, val: T, min: T, max: T) T {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}

fn interpolateAdditive(comptime T: type, from: T, to: T, speed: T) T {
    if (speed <= 0) @panic("codebug");
    if (from < to) {
        return @min(to, from + speed);
    } else if (from > to) {
        return @max(to, from - speed);
    }
    else return to;
}

fn interpolateScale(comptime T: type, from: T, to: T, scale: f32) T {
    if (scale < 0) @panic("codebug: negative scale");
    if (scale > 1) @panic("codebug: scale too big");
    if (from == to) return to;
    const diff = to - from;
    return from + @as(T, @intFromFloat(scale * @as(f32, @floatFromInt(diff))));
}

fn getFreqs(mass: i32) struct { start: u16, end: u16 } {
    //log("mass {}", .{mass});
    if (mass <= 100) return .{
        .start = 2000,
        .end   = 5000,
    };
    if (mass <= 1000) return .{
        .start = 1000,
        .end   = 2000,
    };
    if (mass <= 10000) return .{
        .start = 400,
        .end   = 1000,
    };
    if (mass <= 5000) return .{
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
                blob.angle += tau;
                std.debug.assert(blob.angle >= 0);
            }
        },
        .inc => {
            blob.angle += angle_speed;
            if (blob.angle > tau) {
                blob.angle -= tau;
                std.debug.assert(blob.angle <= tau);
            }
        },
    }
}

fn calcDistance(a: XY(i32), b: XY(i32)) f32 {
    const diff_x: f32 = @floatFromInt(a.x - b.x);
    const diff_y: f32 = @floatFromInt(a.y - b.y);
    const dist = std.math.sqrt(diff_x * diff_x + diff_y * diff_y);
    if (dist < 0) @panic("codebug");
    return dist;
}

const global_volume: f32 = 0.4;
const max_eat_nibble_volume = 20;
const max_eat_blob_volume = 40;

const VolPan = struct {
    volume: u32,
    pan: u32,

    pub fn fromPoint(pt: XY(i32), max_volume: u32) VolPan {
        const my_blob = global.myBlob();
        const diff_x: f32 = @floatFromInt(pt.x - my_blob.pos_pt.x);
        const diff_y: f32 = @floatFromInt(pt.y - my_blob.pos_pt.y);
        const dist = std.math.sqrt(diff_x * diff_x + diff_y * diff_y);
        if (dist < 0) @panic("codebug");
        const max_distance = arena_half_size_pt_f32 * 1.5;
        const ratio: f32 = 1.0 - @min(dist, max_distance) / max_distance;
        const pan_threshold = arena_half_size_pt_f32 / 3;
        return .{
            .volume = @intFromFloat((ratio*ratio) * (
                @as(f32, @floatFromInt(max_volume)) * global_volume
            )),
            .pan =
                if (diff_x > pan_threshold) w4.TONE_PAN_RIGHT
                else if (diff_x < -pan_threshold) w4.TONE_PAN_LEFT
                else 0
        };
    }
};

const eat_blob_multitone = [_]Tone{
    .{ .frequency = 0x00500032, .duration = 10 },
    .{ .frequency = 0x00320050, .duration = 10 },
    .{ .frequency = 0x00500032, .duration = 10 },
    .{ .frequency = 0x00320050, .duration = 10 },
};

fn eatBlobTone(eater: *const Blob) void {
    if (global.multitones_count == global.multitones_buf.len) {
        log("WARNING!!! can't play eatBlobTone, out of multitone slots!", .{});
        return;
    }
    const vp: VolPan = if (eater == global.myBlob()) .{
        .volume = max_eat_blob_volume,
        .pan = 0,
    } else VolPan.fromPoint(eater.pos_pt, max_eat_blob_volume);
    global.multitones_buf[global.multitones_count] = .{
        .loop = false,
        .tones = &eat_blob_multitone,
        .volume = vp.volume,
        .flags = vp.pan | w4.TONE_PULSE1,
    };
    global.multitones_count += 1;
}

const eat_tone_duration = 5;
fn eatTone(blob: *const Blob) void {
    // don't cut off the player's eat tone
    const is_me = (blob == global.myBlob());
    if (is_me) {
        global.my_eat_tone_frame = 1;
    } else if (global.my_eat_tone_frame) |_| {
        // don't cut off the player's eat tone, we all share
        // the same oscillator
        // TODO: we could put the sound in a deferred queue
        return;
    }

    const freqs = getFreqs(blob.mass);
    //log("tone {} to {}", .{freqs.start, freqs.send});
    const freq_arg = @as(u32, freqs.end) << 16 | freqs.start;
    const vp: VolPan = if (is_me) .{
        .volume = max_eat_nibble_volume,
        .pan = 0,
    } else VolPan.fromPoint(blob.pos_pt, max_eat_nibble_volume);
    w4.tone(freq_arg, eat_tone_duration, vp.volume, vp.pan | w4.TONE_TRIANGLE);
}

const disk_state_flag = struct {
    pub const light_mode = 1;
};
fn setDiskState(mask: u8, value: u1) void {
    switch (value) {
        0 => global.disk_state[0] &= ~mask,
        1 => global.disk_state[0] |= mask,
    }
    const len = w4.diskw(&global.disk_state, global.disk_state.len);
    if (len != global.disk_state.len) {
        log("failed to write state to disk", .{});
    } else {
        log("wrote {} bytes to disk", .{len});
    }
}

const Appearance = enum { dark, light };

fn getAppearance() Appearance {
    const state = global.disk_state[0] & disk_state_flag.light_mode;
    return if (0 == state) .dark else .light;
}
fn applyAppearance() void {
    w4.PALETTE.* = switch (getAppearance()) {
        .dark => [4]u32{
            0x293133,
            0x384250,
            0xD96520,
            0x25BEC1,
        },
        .light => [4]u32{
            0xFFFFFF,
            0xFCEADE,
            0xFF8A30,
            0x25CED1,
        },
    };
}
fn changeAppearance(a: Appearance) void {
    setDiskState(
        disk_state_flag.light_mode,
        switch (a) { .dark => 0, .light => 1 },
    );
    applyAppearance();
}

export fn start() void {
    const len = w4.diskr(&global.disk_state, global.disk_state.len);
    if (len == 0) {
        log("no disk state", .{});
    } else {
        log("read {} bytes from disk", .{len});
    }
    applyAppearance();
    initStartMenuMusic();
}

fn initStartMenuMusic() void {
    global.multitones_buf[0] = .{
        .loop = false,
        .tones = &music.bass,
        .volume = 42,
        .flags = w4.TONE_TRIANGLE,
    };
    global.multitones_buf[1] = .{
        .loop = false,
        .tones = &music.melody,
        .volume = 20,
        .flags = w4.TONE_PULSE1,
    };
    global.multitones_count = 2;
}

// Used to tell if a button is "triggered".
// Prevents the "down" state from triggering multiple events.
fn isButtonTriggered(
    button: u32,
    released_state_ref: *bool,
) bool {
    const pressed = (0 != (w4.GAMEPAD1.* & button));
    if (released_state_ref.*) {
        if (pressed) released_state_ref.* = false;
        return pressed;
    } else {
        if (!pressed) {
            released_state_ref.* = true;
        }
        return false;
    }
}

export fn update() void {
    switch (global.mode) {
        // TODO: minify these cases and file a bug, they cause the
        //       compiler to crash on windows
        //.start_menu => |*s| updateStartMenu(s),
        .start_menu => updateStartMenu(&global.mode.start_menu),
        //.settings => |*s| updateSettingsMode(s),
        .settings => updateSettingsMode(&global.mode.settings),
        //.play => |*p| updatePlayMode(p),
        .play => updatePlayMode(&global.mode.play),
    }
}

fn updateStartMenu(start_menu: *StartMenu) void {
    // TODO: play cool music
    global.rand_seed +%= 1;
    w4.DRAW_COLORS.* = 0x0430;
    w4.blit(
        &startlogo.blobs,
        (160 - startlogo.blobs_width) / 2, 10,
         startlogo.blobs_width,
        startlogo.blobs_height,
        w4.BLIT_2BPP,
    );
    w4.DRAW_COLORS.* = 0x02;
    textCenter("Controls:", 70);
    w4.DRAW_COLORS.* = 0x02;
    w4.text("Direction: \x84 \x85", 25, 85);
    w4.text("Dash: \x81", 25, 98);
    w4.text("Menu: \x80", 25, 111);
    w4.DRAW_COLORS.* = 0x04;
    textCenter("Press \x80 to start", 130);
    tickMultitones();

    if (!isButtonTriggered(
        w4.BUTTON_1, &start_menu.button1_released
    ))
        return;

    w4.tracef("random seed: %d", global.rand_seed);
    global.rand = std.rand.DefaultPrng.init(global.rand_seed);
    for (&points_buf) |*pt| {
        pt.* = getRandomPoint();
    }
    for (&global.blobs, 0..) |*blob, i| {
        const is_potential_player = (i < 4);
        const start_boost: i32 = if (is_potential_player) 0
            else @as(i32, @intFromFloat(@floor(300 * getRandomScale(2))));
        blob.* = .{
            .pos_pt = getRandomPoint(),
            .mass = starting_mass + start_boost,
            .angle = if (is_potential_player) 0 else tau * getRandomScale(2),
            .dashing = false,
            .digesting = 0,
        };
    }
    for (&global.ai_controls) |*c| {
        c.* = .none;
    }

    global.multitones_count = 0;
    global.mode = .{ .play = .{
        .intro_frame = 0, // do show intro frame
    } };
}

fn updateSettingsMode(settings: *Settings) void {
    if (isButtonTriggered(
        w4.BUTTON_1, &settings.button1_released
    )) switch (settings.selection) {
        .return_to_game => {
            // NOTE: this will invalidate `settings` so we
            //       return right after setting it
            global.mode = .{ .play = .{
                .intro_frame = null, // don't show intro frame
            } };
            return;
        },
        .appearance => changeAppearance(switch (getAppearance()) {
            .dark => .light,
            .light => .dark,
        }),
        .new_game => {
            // NOTE: this will invalidate `settings` so we
            //       return right after setting it
            global.mode = .{ .start_menu = .{ } };
            initStartMenuMusic();
            return;
        },
    };
    if (isButtonTriggered(
        w4.BUTTON_UP, &settings.button_up_released
    )) switch (settings.selection) {
        .return_to_game => {},
        .appearance => settings.selection = .return_to_game,
        .new_game => settings.selection = .appearance,
    };
    if (isButtonTriggered(
        w4.BUTTON_DOWN, &settings.button_down_released
    )) switch (settings.selection) {
        .return_to_game => settings.selection = .appearance,
        .appearance => settings.selection = .new_game,
        .new_game => {},
    };
    if (isButtonTriggered(
        w4.BUTTON_RIGHT, &settings.button_right_released
    )) switch (settings.selection) {
        .return_to_game => {},
        .appearance => changeAppearance(.light),
        .new_game => {},
    };
    if (isButtonTriggered(
        w4.BUTTON_LEFT, &settings.button_left_released
    )) switch (settings.selection) {
        .return_to_game => {},
        .appearance => changeAppearance(.dark),
        .new_game => {},
    };

    {
        const netplay_x = 22;
        const netplay_y = 20;
        w4.DRAW_COLORS.* = 0x3;
        w4.text("NETPLAY: ", netplay_x, netplay_y);

        var buf: [20]u8 = undefined;
        const status = blk: {
            if (netplay()) {
                w4.DRAW_COLORS.* = 0x4;
                break :blk std.fmt.bufPrint(
                    &buf, "Player {}", .{1 + (w4.NETPLAY.* & 0x3)}
                ) catch @panic("codebug");
            }
            w4.DRAW_COLORS.* = 0x2;
            break :blk "off";
        };
        w4.text(status, netplay_x + 3 + 8*8, netplay_y);
    }

    const return_y = 50;
    const appearance_y = 65;
    const new_game_y = 80;

    w4.DRAW_COLORS.* = 0x3;
    w4.text("Return to Game", 22, return_y - 4);
    {
        const box_x: i32 = switch (getAppearance()) {
            .dark => 20,
            .light => 72,
        };
        w4.DRAW_COLORS.* = 0x40;
        w4.rect(box_x, appearance_y - 7, 48, 13);
        w4.DRAW_COLORS.* = 0x3;
        w4.text("Dark", 28, appearance_y - 4);
        w4.text("Light", 76, appearance_y - 4);
    }
    w4.DRAW_COLORS.* = 0x3;
    w4.text("New Game", 22, new_game_y - 4);
    {
        const selector_y: i32 = switch (settings.selection) {
            .return_to_game => return_y,
            .appearance => appearance_y,
            .new_game => new_game_y,
        };
        w4.DRAW_COLORS.* = 0x4;
        w4.text("\x80", 8, selector_y - 4);
    }
}

fn textCenter(str: []const u8, y: i32) void {
    w4.text(str, @intCast((160 - str.len * 8) / 2), y);
}

fn tickMultitones() void {
    var mt_index: usize = 0;
    while (mt_index < global.multitones_count) {
        const mt = &global.multitones_buf[mt_index];
        mt.current_tone_frame += 1;
        if (mt.current_tone_frame > mt.tones[mt.current_tone].duration) {
            // TODO: handline looping multitones?
            mt.current_tone += 1;
            mt.current_tone_frame = 1;
            if (mt.current_tone >= mt.tones.len) {
                if (mt.loop) {
                    mt.current_tone = 0;
                } else {
                    std.mem.copyForwards(
                        MultiTone,
                        global.multitones_buf[mt_index..global.multitones_count-1],
                        global.multitones_buf[mt_index+1..global.multitones_count],
                    );
                    global.multitones_count -= 1;
                    continue;
                }
            }
        }
        if (mt.current_tone_frame == 1) {
            const t = &mt.tones[mt.current_tone];
            if (t.frequency != 0) {
                //log("playing tone freq {} dur {} vol {}", .{t.frequency, t.duration, t.volume});
                w4.tone(t.frequency, t.duration, mt.volume, mt.flags);
            }
        }
        mt_index += 1;
    }
}

fn updatePlayMode(play: *Play) void {
    // check if the user wants to enter the settings
    if (isButtonTriggered(w4.BUTTON_1, &play.button1_released)) {
        // NOTE: this will invalidate `play` so we
        //       return right after setting it
        global.mode = .{ .settings = .{} };
        return;
    }

    tickMultitones();

    if (global.my_eat_tone_frame) |*f| {
        f.* = f.* + 1;
        if (f.* >= eat_tone_duration) {
            global.my_eat_tone_frame = null;
        }
    }

    for (0 .. 4) |player_index| {
        const gamepad = @as([*]const u8, @ptrFromInt(0x16))[player_index];
        updateAngle(&global.blobs[player_index], getControl(
            0 != (gamepad & w4.BUTTON_LEFT),
            0 != (gamepad & w4.BUTTON_RIGHT),
        ));
        global.blobs[player_index].dashing = (
            0 != (gamepad & w4.BUTTON_2)
        );
    }

    for (global.blobs[4..], 0..) |*blob, i| {
        if (blob.mass == 0) continue;
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
    const cheat = false;
    if (cheat) {
        switch (getControl(
            0 != (w4.GAMEPAD1.* & w4.BUTTON_DOWN),
            0 != (w4.GAMEPAD1.* & w4.BUTTON_UP),
        )) {
            .none => {},
            .dec => {
                const mod = @max(1, @divTrunc(global.p1.mass, 20));
                global.me.mass = @max(starting_mass, global.me.mass - mod);
            },
            .inc => {
                const mod = @max(1, @divTrunc(global.p1.mass, 20));
                global.me.mass += mod;
            },
        }
    }

    // blobs digest
    for (&global.blobs) |*blob| {
        if (blob.digesting != 0) {
            if (blob.mass == 0) @panic("codebug");
            const digest = @min(max_digest_per_frame, blob.digesting);
            blob.mass += digest;
            blob.digesting -= digest;
        }
    }

    var sines: [global.blobs.len]f32 = undefined;
    var cosines: [global.blobs.len]f32 = undefined;
    var radiuses: [global.blobs.len]i32 = undefined;

    // move blobs
    for (&global.blobs, 0..) |*blob, i| {
        if (blob.mass == 0) continue;

        // TODO: get slower as you get bigger
        sines[i] = std.math.sin(blob.angle);
        cosines[i] = std.math.cos(blob.angle);
        radiuses[i] = massToRadius(blob.mass);

        const penalty_multipler: f32 = @min(1.0, @as(
            f32, @max(0, @as(f32, @floatFromInt(blob.mass)))
        ) / @as(f32, 10000));
        const penalty: f32 = penalty_multipler * @as(f32, max_size_penalty);
        var speed_pt = (if (blob.dashing) base_speed_pt * 2 else base_speed_pt) - penalty;

        const diff_x: i32 = @intFromFloat(@floor(speed_pt * cosines[i]));
        const diff_y: i32 = @intFromFloat(@floor(speed_pt * sines[i]));
        const min: i32 = -arena_half_size_pt + radiuses[i];
        const max: i32 =  arena_half_size_pt - radiuses[i];
        blob.pos_pt = .{
            .x = clamp(i32, blob.pos_pt.x + diff_x, min, max),
            .y = clamp(i32, blob.pos_pt.y + diff_y, min, max),
        };
    }

    // TODO: this *might* need some optimization?
    for (&global.blobs, 0..) |*blob, blob_index| {
        if (blob.mass == 0) continue;
        for (global.blobs[blob_index+1..], blob_index+1..) |*other_blob, other_blob_index| {
            if (other_blob.mass == 0) continue;
            const dist: i32 = @intFromFloat(@floor(calcDistance(blob.pos_pt, other_blob.pos_pt)));
            if (dist > radiuses[blob_index] and dist > radiuses[other_blob_index])
                continue;

            const blobs: struct {
                eater: *Blob,
                eaten: *Blob,
            } = if (radiuses[blob_index] > radiuses[other_blob_index])
                .{ .eater = blob, .eaten = other_blob }
            else if (radiuses[other_blob_index] > radiuses[blob_index])
                .{ .eater = other_blob, .eaten = blob }
            else continue;
            eatBlobTone(blobs.eater);
            blobs.eater.digesting += blobs.eaten.mass;
            blobs.eaten.mass = 0;
            blobs.eaten.digesting = 0; // important!
        }
    }

    // eat nibbles
    for (&global.blobs, 0..) |*blob, blob_index| {
        if (blob.mass == 0) continue;
        for (&points_buf) |*pt| {
            const dist = calcDistance(pt.*, blob.pos_pt);
            if (dist >= @as(f32, @floatFromInt(radiuses[blob_index]))) continue;

            //log("eat point {}!", .{i});
            eatTone(blob);
            blob.mass += 1;

            // replace with new random nibble
            pt.* = getRandomPoint();
        }
    }

    const my_blob = global.myBlob();
    const my_player = play.myPlayer();
    const points_per_pixel: i32 = blk: {
        if (my_blob.mass == 0) {
            if (my_player.last_points_per_pixel) |*ppp| {
                const zoom_speed = 10;
                if (my_blob.pos_pt.x != 0 or my_blob.pos_pt.y != 0) {
                    const zoom_left: f32 = @floatFromInt(@max(0, max_points_per_pixel - ppp.*));
                    const zoom_multiplier: f32 = @as(f32, @min(zoom_left, zoom_speed)) / zoom_left;
                    const from = my_blob.pos_pt;
                    my_blob.pos_pt = .{
                        .x = interpolateScale(i32, from.x, 0, zoom_multiplier),
                        .y = interpolateScale(i32, from.y, 0, zoom_multiplier),
                    };
                }

                break :blk @min(max_points_per_pixel, ppp.* + zoom_speed);
            }
        }
        const my_radius: i32 = if (my_blob.mass == 0)
            min_radius_pt
        else
            radiuses[w4.NETPLAY.* & 3]
        ;
        const my_desired_blob_radius_px: i32 = interpolateScale(
            i32,
            10,
            80,
            @min(1, @as(f32, @floatFromInt(my_radius - min_radius_pt)) / arena_half_size_pt_f32),
        );
        const desired_ppp: i32 = @min(
            max_points_per_pixel,
            @divTrunc(my_radius, my_desired_blob_radius_px),
        );
        if (my_player.last_points_per_pixel) |*ppp|
            break :blk interpolateAdditive(i32, ppp.*, desired_ppp, 1);
        break :blk desired_ppp;
    };
    my_player.last_points_per_pixel = points_per_pixel;
    // keep the camera in the arena
    const camera_center_pt: XY(i32) = blk: {
        const half_view_size_pt = 80 * points_per_pixel;
        break :blk XY(i32) {
            .x = clamp(
                i32,
                my_blob.pos_pt.x,
                -arena_half_size_pt + half_view_size_pt,
                arena_half_size_pt - half_view_size_pt,
            ),
            .y = clamp(
                i32,
                my_blob.pos_pt.y,
                -arena_half_size_pt + half_view_size_pt,
                arena_half_size_pt - half_view_size_pt,
            ),
        };
    };

    drawBars(points_per_pixel, camera_center_pt.x, .x);
    drawBars(points_per_pixel, camera_center_pt.y, .y);

    // draw dots
    for (&points_buf) |*pt| {
        const px = ptToPx(points_per_pixel, camera_center_pt, pt.*);
        w4.DRAW_COLORS.* = 0x4;
        w4.rect(px.x, px.y, 1, 1);
    }

    // draw the blobs
    for (&global.blobs, 0..) |*blob, blob_index| {
        if (blob.mass == 0) continue;
        const px = ptToPx(points_per_pixel, camera_center_pt, .{
            .x = blob.pos_pt.x - radiuses[blob_index],
            .y = blob.pos_pt.y - radiuses[blob_index],
        });
        w4.DRAW_COLORS.* = 0x33;
        const size: i32 = @divTrunc(radiuses[blob_index] * 2, points_per_pixel);
        //log("player {},{} size={}", .{px.x, px.y, size});
        w4.oval(px.x, px.y, @intCast(size), @intCast(size));
    }
    // draw the blob directional dots (on second pass
    // so they always appear in front of the bodies)
    for (&global.blobs, 0..) |*blob, i| {
        if (blob.mass == 0) continue;
        const radius_pt: f32 = @as(f32, @floatFromInt(radiuses[i]));
        const px = ptToPx(points_per_pixel, camera_center_pt, .{
            .x = blob.pos_pt.x + @as(i32, @intFromFloat(radius_pt * cosines[i])),
            .y = blob.pos_pt.y + @as(i32, @intFromFloat(radius_pt * sines[i])),
        });
        w4.DRAW_COLORS.* = 0x43;
        w4.oval(px.x - 2, px.y - 2, 4, 4);
    }

    const draw_mass = false;
    if (draw_mass) {
        for (&global.blobs) |*blob| {
            if (blob.mass == 0) continue;
            const px = ptToPx(points_per_pixel, blob.pos_pt);
            w4.DRAW_COLORS.* = 0x33;
            var buf: [100]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{}", .{blob.mass}) catch @panic("codebug");
            w4.DRAW_COLORS.* = 0x02;
            const shift_x: i32 = 4 * @as(i32, @intCast(str.len));
            w4.text(str, px.x - shift_x, px.y - 4);
        }
    }

    // draw arena border
    {
        const top_left = ptToPx(points_per_pixel, camera_center_pt, .{
            .x = -arena_half_size_pt,
            .y = -arena_half_size_pt,
        });
        const bottom_right = ptToPx(points_per_pixel, camera_center_pt, .{
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

    if (play.intro_frame) |*frame| {
        frame.* += 1;
        // 3 seconds
        if (frame.* == 3 * 60) {
            play.intro_frame = null;
        } else {
            w4.DRAW_COLORS.* = 4;
            const msg = intro_messages[global.rand_seed % intro_messages.len];
            var it = std.mem.split(u8, msg, "\n");
            var line_num: i32 = 0;
            while (it.next()) |line| : (line_num += 1) {
                textCenter(line, 30 + (12*line_num));
            }
        }
    }

    const draw_position = false;
    if (draw_position) {
        var buf: [100]u8 = undefined;
        const str = std.fmt.bufPrint(
            &buf,
            "{},{}",
            .{
                @divTrunc(global.me.pos_pt.x, 100),
                @divTrunc(global.me.pos_pt.y, 100),
            },
        ) catch @panic("codebug");
        w4.DRAW_COLORS.* = 0x04;
        w4.text(str, 0, 0);
    }

    if (global.myBlob().mass == 0) {
        w4.DRAW_COLORS.* = 0x13;
        textCenter("Spectating...", 150);
    }
}

fn drawBars(points_per_pixel: i32, center_pt: i32, dir: enum { x, y}) void {
    w4.DRAW_COLORS.* = 0x02;
    const grid_size_pt = 8000;
    var i_pt: i32 = -arena_half_size_pt;
    while (true) {
        i_pt += grid_size_pt;
        if (i_pt >= arena_half_size_pt) break;
        const i_px = switch (dir) {
            .x => ptToPxX(points_per_pixel, center_pt, i_pt),
            .y => ptToPxY(points_per_pixel, center_pt, i_pt),
        };
        switch (dir) {
            .x => w4.vline(i_px, 0, 160),
            .y => w4.hline(0, i_px, 160),
        }
    }
}
