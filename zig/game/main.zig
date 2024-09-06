const std = @import("std");
const gain = @import("../gain/main.zig");
const gfx = @import("gfx.zig");
const Vec2 = gain.math.Vec2;
const app = gain.app;
const Color32 = gain.math.Color32;
const Mat2d = gain.math.Mat2d;
const FPRect = @import("FPRect.zig");
const fp32 = @import("fp32.zig");
const FPVec2 = @import("FPVec2.zig");
const sfx = @import("sfx.zig");
const map = @import("map.zig");
const particles = @import("particles.zig");
const colors = @import("colors.zig");
const texts = @import("texts.zig");
const camera = @import("camera.zig");

var g_rnd: gain.math.Rnd = .{ .seed = 0 };

const Hero = struct {
    x: i32,
    y: i32,
};

const Item = struct {
    x: i32,
    y: i32,
    kind: u8,
};

const fbits = fp32.fbits;
const cell_size_bits = map.cell_size_bits;
const cell_size = map.cell_size;
const cell_size_half = map.cell_size_half;

var level: u32 = 0;
var level_started = false;
var kills: u32 = 0;
const camera_zoom = 1;
const screen_size = 512 << fbits;
const screen_size_half = screen_size >> 1;

const hero_w = 10 << fbits;
const hero_h = 24 << fbits;
const hero_place_w = 12 << fbits;
const hero_place_h = 4 << fbits;

var hero_move_timer: i32 = undefined;
var hero_look_x: i32 = undefined;
var hero_look_y: i32 = undefined;
var hero: Hero = undefined;
var hero_aabb_local = FPRect.init(-(hero_w >> 1), -hero_h, hero_w, hero_h);
var hero_ground_aabb_local = FPRect.init(-(hero_place_w >> 1), -(hero_place_h >> 1), hero_place_w, hero_place_h);
var hero_visible: u32 = 0;
const hero_visible_max = 31;
var hero_knife = false;
var hero_mask = false;
var hero_hp: i32 = undefined;
var hero_attack_t: i32 = undefined;

const game_over_t_max = 32;
var game_over_t: u8 = 0;

const Portal = struct {
    src: FPVec2,
    rc: FPRect,
    dest: FPVec2,
};

const portals_max = 32;
var portals: [portals_max]Portal = undefined;
var portals_num: u32 = undefined;

fn addPortal(x: i32, y: i32, dx: i32, dy: i32, sx: i32, sy: i32) void {
    if (portals_num < portals_max) {
        portals[portals_num] = .{
            .rc = FPRect.init(
                x << map.cell_size_bits,
                y << cell_size_bits,
                cell_size,
                cell_size,
            ),
            .dest = FPVec2.init(
                (dx << cell_size_bits) + cell_size_half,
                (dy << cell_size_bits) + cell_size_half,
            ),
            .src = FPVec2.init(
                (sx << cell_size_bits) + cell_size_half,
                (sy << cell_size_bits) + cell_size_half,
            ),
        };
        portals_num += 1;
    }
}

const mob_max_hp = 8;
const hit_timer_max = 15;
const Mob = struct {
    x: i32,
    y: i32,
    kind: i32,
    move_timer: i32,
    lx: i32,
    ly: i32,
    ai_timer: i32,
    hp: i32,
    hit_timer: u32,
    target_map_x: i32,
    target_map_y: i32,
    danger_t: i32,
    danger: bool,
    attention: u32,
    text_t: u32,
    text_i: u32,
    male: bool,
    is_student: bool,
    attack_t: i32,
};

fn placeMob(x: i32, y: i32, kind: i32, male: bool, student: bool) void {
    if (mobs_num < mobs_max) {
        mobs[mobs_num] = .{
            .x = cell_size_half + (x << cell_size_bits),
            .y = cell_size_half + (y << cell_size_bits),
            .kind = kind,
            .move_timer = 0,
            .lx = 0,
            .ly = 0,
            .ai_timer = 0,
            .hp = mob_max_hp,
            .hit_timer = 0,
            .target_map_x = 0,
            .target_map_y = 0,
            .danger_t = 0,
            .danger = false,
            .attention = 0,
            .male = male,
            .text_t = 0,
            .text_i = 0,
            .is_student = student,
            .attack_t = 0,
        };
        mobs_num += 1;
    }
}

const mobs_max = 128;
var mobs: [mobs_max]Mob = undefined;
var mobs_num: u32 = undefined;
const mob_hitbox_local = FPRect.fromInt(
    -10,
    -4,
    20,
    4,
);

const mob_quad_local = FPRect.fromInt(
    -10,
    -30,
    20,
    30,
);

const item_aabb = FPRect.fromInt(
    -10,
    -10,
    20,
    20,
);

const items_max = 128;
var items: [items_max]Item = undefined;
var items_num: u32 = undefined;

fn placeItem(x: i32, y: i32, kind: u8) void {
    if (items_num < items_max) {
        items[items_num] = .{
            .x = cell_size_half + (x << cell_size_bits),
            .y = cell_size_half + (y << cell_size_bits),
            .kind = kind,
        };
        items_num += 1;
    }
}

fn initLevel() void {
    var rnd = gain.math.Rnd{ .seed = 3 + (level << 5) };

    items_num = 0;
    mobs_num = 0;
    portals_num = 0;
    kills = 0;
    particles.reset();
    unsetAllTexts();
    var x: i32 = map.size >> 1;
    var y: i32 = map.size >> 1;
    var room_x = x;
    var room_y = y;
    var act: u32 = 0;
    var act_timer: u32 = 4;
    hero.x = (x << cell_size_bits) + cell_size_half;
    hero.y = (y << cell_size_bits) + cell_size_half;
    hero_visible = 0;
    hero_hp = 10;
    hero_knife = false;
    hero_mask = false;
    hero_attack_t = 0;

    var gender_i: u32 = 0;
    var mob_kind_i: i32 = 0;
    const rooms_count: u8 = 6;
    for (0..rooms_count) |room_index| {
        map.current_color = @truncate(room_index);
        room_x = x;
        room_y = y;
        const iters = 100;
        var portals_gen: u32 = 1;
        var items_gen: u32 = 10;
        var mobs_gen: u32 = 3;
        var guards_gen: u32 = 3;
        for (0..iters) |_| {
            switch (act) {
                0 => if (x + 2 < map.size) {
                    x += 1;
                } else {
                    //act = 1;
                },
                1 => if (x > 1) {
                    x -= 1;
                } else {
                    //act = 0;
                },
                2 => if (y + 2 < map.size) {
                    y += 1;
                } else {
                    //act = 3;
                },
                3 => if (y > 1) {
                    y -= 1;
                } else {
                    //act = 2;
                },
                else => unreachable,
            }

            map.set(x, y, 1);
            map.set(x - 1, y, 1);
            map.set(x + 1, y, 1);
            map.set(x, y - 1, 1);
            map.set(x, y + 1, 1);

            act_timer -= 1;
            if (act_timer == 0) {
                act_timer = 1 + (rnd.next() & 3);
                const new_act = rnd.next() & 3;
                if (new_act != act) {
                    act = new_act;
                    const pp = rnd.next() & 7;
                    switch (pp) {
                        0 => if (mobs_gen > 0) {
                            placeMob(x, y, @mod(mob_kind_i, 3) + 1, gender_i & 1 == 1, true);
                            gender_i += 1;
                            mobs_gen -= 1;
                            mob_kind_i += 1;
                        },
                        1 => if (guards_gen > 0) {
                            placeMob(x, y, @mod(mob_kind_i, 3) + 1, rnd.next() & 1 == 1, false);
                            guards_gen -= 1;
                            mob_kind_i += 1;
                        },
                        2 => if (portals_num > 2 and portals_gen > 0) {
                            const p = portals[rnd.next() % portals_num];
                            addPortal(x, y, p.src.x >> cell_size_bits, p.src.y >> cell_size_bits, room_x, room_y);
                            portals_gen -= 1;
                        },
                        else => if (items_gen > 0) {
                            placeItem(x, y, 1);
                            items_gen -= 1;
                        },
                    }
                }
            }
        }

        if (room_index < rooms_count - 1) {
            const nx = rnd.int(8, map.size - 8 - 1);
            const ny = rnd.int(8, map.size - 8 - 1);
            addPortal(x, y, nx, ny, room_x, room_y);
            x = nx;
            y = ny;
        }
    }

    addPortal(x, y, hero.x >> cell_size_bits, hero.y >> cell_size_bits, room_x, room_y);

    for (&map.map) |*cell| {
        if (cell.* == 1) {
            if (rnd.next() & 7 == 0) {
                cell.* = @truncate(1 + (rnd.next() & 3));
            }
        }
    }

    level_started = true;
}

fn mobSetMove(mob: *Mob, dx: i32, dy: i32, speed: i32) void {
    const v = FPVec2.init(dx, dy).rescale(speed);
    mob.*.lx = v.x;
    mob.*.ly = v.y;
}

fn setMobRandomMovement(mob: *Mob) void {
    mobSetMove(
        mob,
        g_rnd.int(-10, 10),
        g_rnd.int(-10, 10),
        if (g_rnd.next() & 7 == 0) 0 else 1 << fbits,
    );
}

fn mobRunAwayBeh(mob: *Mob, x: i32, y: i32, speed: i32) void {
    mobSetMove(mob, mob.x - x, mob.y - y, speed);
}

fn updateMobs() void {
    const hero_aabb = hero_ground_aabb_local.translate(hero.x, hero.y).expandInt(16);

    for (0..mobs_num) |i| {
        const mob: *Mob = &mobs[i];
        if (mob.kind != 0) {
            const hero_is_danger = hero_visible > 8 and hero_knife and hero_mask and hero_hp != 0;
            const dist_to_hero = fp32.dist(hero.x, hero.y, mob.x, mob.y);
            const danger = hero_is_danger and dist_to_hero < (100 << fbits);
            if (danger) {
                mob.*.attention += 1;
                if (mob.attention > 32 and !mob.danger) {
                    mob.*.danger_t = if (mob.is_student) 32 else 4;
                    sfx.fear();
                    mob.*.danger = true;
                }
            } else {
                if (mob.*.danger_t > 0 or hero_hp <= 0) {
                    mob.*.danger = false;
                }
                if (mob.attention > 0) {
                    mob.*.attention -= 1;
                }
            }

            if (mob.*.ai_timer <= 0) {
                mob.*.ai_timer = @intCast(g_rnd.next() & 0x3f);
                if (mob.danger) {
                    mob.*.target_map_x = 0;
                    mob.*.target_map_y = 0;
                    if (mob.is_student) {
                        if (findClosestPortal(mob.x, mob.y)) |portal| {
                            map.findPath(mob.x >> cell_size_bits, mob.y >> cell_size_bits, portal.rc.cx() >> cell_size_bits, portal.rc.cy() >> cell_size_bits);
                            if (map.path_num > 1) {
                                mob.*.target_map_x = map.path_x[1];
                                mob.*.target_map_y = map.path_y[1];
                            }
                        }
                    } else {
                        map.findPath(mob.x >> cell_size_bits, mob.y >> cell_size_bits, hero_aabb.cx() >> cell_size_bits, hero_aabb.cy() >> cell_size_bits);
                        if (map.path_num > 1) {
                            mob.*.target_map_x = map.path_x[1];
                            mob.*.target_map_y = map.path_y[1];
                        }
                    }
                } else {
                    // just flex
                    mob.*.target_map_x = 0;
                    mob.*.target_map_y = 0;
                    setMobRandomMovement(mob);
                }
            }
            const speed: i32 = @as(i32, if (mob.danger) 2 else 1) << fbits;
            if (mob.danger_t > 0) {
                mob.*.danger_t -= 1;
            }
            if (danger and (!mob.danger or mob.danger_t > 0)) {
                mob.*.lx = 0;
                mob.*.ly = 0;
            } else if (mob.*.target_map_x != 0) {
                const tx: i32 = (mob.*.target_map_x << cell_size_bits) + cell_size_half;
                const ty: i32 = (mob.*.target_map_y << cell_size_bits) + cell_size_half;
                mob.*.lx = @max(-speed, @min(speed, tx - mob.x));
                mob.*.ly = @max(-speed, @min(speed, ty - mob.y));
                if (mob.x + mob.*.lx == tx and mob.y + mob.*.ly == ty) {
                    mob.*.ai_timer = 0;

                    if (testPortals(mob_hitbox_local.translate(mob.x, mob.y))) |portal| {
                        mob.x = portal.dest.x;
                        mob.y = portal.dest.y;
                        mob.*.danger = false;
                        sfx.portal();
                    }
                }
            } else {
                if (danger) {
                    if (mob.is_student or mob.attack_t > 0) {
                        mobRunAwayBeh(mob, hero.x, hero.y, speed);
                    } else {
                        mobSetMove(mob, hero.x - mob.x, hero.y - mob.y, speed);
                    }
                }
                mob.*.ai_timer -= 1;
            }
            // block move to hidden hero
            if (!danger and dist_to_hero < (64 << fbits) and hero_hp != 0) {
                mobRunAwayBeh(mob, hero.x, hero.y, speed);
            }
            if (mob.*.lx != 0 or mob.*.ly != 0) {
                mob.*.move_timer +%= 2;
                const new_x = mob.x + mob.*.lx;
                const new_y = mob.y + mob.*.ly;
                if (!map.testRect(mob_hitbox_local.translate(new_x, mob.y))) {
                    mob.*.x = new_x;
                } else {
                    mob.*.lx = -mob.*.lx;
                }
                if (!map.testRect(mob_hitbox_local.translate(mob.x, new_y))) {
                    mob.*.y = new_y;
                } else {
                    mob.*.ly = -mob.*.ly;
                }
            } else {
                mob.*.move_timer = 0;
            }

            if (mob.hit_timer > 0) {
                mob.*.hit_timer -= 1;
            }

            if (mob.hp < mob_max_hp and g_rnd.next() & 0x7 == 0) {
                const mob_aabb = mob_hitbox_local.translate(mob.x, mob.y);
                particles.add(1, mob_aabb.cx(), mob_aabb.cy(), 20 << fbits);
            }
            if (game_state == 1) {
                if (mob.text_t > 0) {
                    mob.*.text_t -= 1;
                    if (mob.*.text_t == 0) {
                        clearMobText(i);
                    } else {
                        setText(@bitCast(i + 1), texts.mob[mob.text_i], FPVec2.init(mob.x, mob.y - (48 << fbits)), 0xFFFFFF, 2);
                    }
                } else {
                    if (g_rnd.next() & 63 == 0) {
                        var start_index: u32 = 5;
                        if (mob.danger) {
                            if (mob.is_student) {
                                start_index = 0;
                            } else {
                                start_index = 10;
                            }
                        }
                        selectMobText(i, start_index + (g_rnd.next() % 5));
                        // pick text index
                    }
                }
            }

            if (hero_hp != 0) {
                const mob_aabb = mob_hitbox_local.translate(mob.x, mob.y);
                const mob_overlaps_hero = mob_aabb.overlaps(hero_aabb);
                if (mob_overlaps_hero) {
                    if (mob.hit_timer < (hit_timer_max >> 1) and hero_attack_t > 24) {
                        if (!mob.danger) {
                            mob.*.hp -= mob_max_hp;
                        } else {
                            mob.*.hp -= g_rnd.int(2, 3);
                        }
                        mob.*.hit_timer = hit_timer_max;
                        //mob.*.lx = mob.x - aabb.cx();
                        //mob.*.ly = mob.y - aabb.cy();
                        sfx.hit();
                        const kx = mob_aabb.cx();
                        const ky = mob_aabb.cy();
                        particles.add(32, kx, ky, 20 << fbits);
                        if (mob.hp <= 0) {
                            const c = getMobColor(mob.kind);
                            var rc = FPRect.init(0, 0, 0, 4 << fbits).expandInt(5);
                            particles.addPart(kx, ky, c, 1, rc);
                            rc = FPRect.init(0, 0, 0, 0).expand(2 << fbits, 5 << fbits);
                            particles.addPart(kx - (4 >> fbits), ky, c, 0, rc);
                            particles.addPart(kx + (4 >> fbits), ky, c, 0, rc);
                            particles.addPart(kx - (4 >> fbits), ky + (10 >> fbits), c, 0, rc);
                            particles.addPart(kx + (4 >> fbits), ky + (10 >> fbits), c, 0, rc);

                            mob.*.kind = 0;
                            clearMobText(i);

                            if (mob.is_student) {
                                kills += 1;
                            }
                        }
                    }

                    if (!mob.is_student and mob.attack_t == 0) {
                        mob.*.attack_t = 32;
                        // attack sfx;
                        sfx.hit();
                        hero_hp = @max(0, hero_hp - g_rnd.int(1, 3));
                        //mob.*.hit_timer = hit_timer_max;
                        const kx = hero_aabb.cx();
                        const ky = hero_aabb.cy();
                        particles.add(32, kx, ky, 20 << fbits);
                        if (hero_hp == 0) {
                            //particles.add(64, kx, ky);
                            const c = colors.hero_body_color;
                            var rc = FPRect.init(0, 0, 0, 4 << fbits).expandInt(5);
                            particles.addPart(kx, ky, c, 1, rc);
                            particles.addPart(kx, ky, c, 2, rc);
                            particles.addPart(kx, ky, c, 3, rc);
                            rc = FPRect.init(0, 0, 0, 0).expand(2 << fbits, 5 << fbits);
                            particles.addPart(kx - (4 >> fbits), ky, c, 0, rc);
                            particles.addPart(kx + (4 >> fbits), ky, c, 0, rc);
                            particles.addPart(kx - (4 >> fbits), ky + (10 >> fbits), c, 0, rc);
                            particles.addPart(kx + (4 >> fbits), ky + (10 >> fbits), c, 0, rc);

                            // mob.*.kind = 0;
                            unsetText(0);
                            game_over_t = game_over_t_max;
                        }
                    }
                }
            }

            if (mob.attack_t > 0) {
                mob.*.attack_t -= 1;
            }
        }
    }
}

fn selectMobText(i: u32, phrase: u32) void {
    mobs[i].text_i = phrase;
    mobs[i].text_t = texts.mob[phrase].len << 2;
}

fn clearMobText(i: u32) void {
    unsetText(@bitCast(i + 1));
}

fn getInputVector(speed: i32) FPVec2 {
    const keys = gain.keyboard;
    // 5190
    var dx: i32 = 0;
    var dy: i32 = 0;
    if ((keys.down[keys.Code.a] | keys.down[keys.Code.arrow_left]) != 0) {
        dx -= 1;
    }
    if ((keys.down[keys.Code.d] | keys.down[keys.Code.arrow_right]) != 0) {
        dx += 1;
    }
    if ((keys.down[keys.Code.w] | keys.down[keys.Code.arrow_up]) != 0) {
        dy -= 1;
    }
    if ((keys.down[keys.Code.s] | keys.down[keys.Code.arrow_down]) != 0) {
        dy += 1;
    }

    if (gain.pointers.primary()) |p| {
        if (p.is_down) {
            const dist = camera.scale * (32 << fbits);
            const d = p.pos.sub(p.start);
            if (d.length() > dist) {
                dx = @intFromFloat(d.x);
                dy = @intFromFloat(d.y);
            }
        }
    }

    return FPVec2.init(dx, dy).rescale(speed);
}

fn updateHero() void {
    if (hero_hp == 0) return;

    const max_speed: i32 = if (hero_visible > 8) 2 else 1;
    const speed: i32 = @min(max_speed, 1 + (hero_move_timer >> 4)) << fbits;
    const move_dir = getInputVector(speed);
    const dx: i32 = move_dir.x;
    const dy: i32 = move_dir.y;
    // 5208
    // var vx: i32 = 0;
    // var vy: i32 = 0;
    // vy -= keys.down[keys.Code.w] | keys.down[keys.Code.arrow_up];
    // vy += keys.down[keys.Code.s] | keys.down[keys.Code.arrow_down];
    // vx -= keys.down[keys.Code.a] | keys.down[keys.Code.arrow_left];
    // vx += keys.down[keys.Code.d] | keys.down[keys.Code.arrow_right];

    // 5209
    // const vx: i32 = @as(i32, (keys.down[keys.Code.d] | keys.down[keys.Code.arrow_right])) - @as(i32, (keys.down[keys.Code.a] | keys.down[keys.Code.arrow_left]));
    // const vy: i32 = @as(i32, (keys.down[keys.Code.s] | keys.down[keys.Code.arrow_down])) - @as(i32, (keys.down[keys.Code.w] | keys.down[keys.Code.arrow_up]));

    if (dx != 0 or dy != 0) {
        hero_move_timer +%= 2;
        hero_look_x = dx;
        hero_look_y = dy;

        if ((hero_move_timer & 0x1F) == 0) {
            sfx.step(hero_visible);
        }
    } else {
        hero_move_timer = 0;
    }

    const new_x = hero.x + dx;
    const new_y = hero.y + dy;
    if (!map.testRect(hero_ground_aabb_local.translate(new_x, hero.y))) {
        hero.x = new_x;
    }
    if (!map.testRect(hero_ground_aabb_local.translate(hero.x, new_y))) {
        hero.y = new_y;
    }

    const aabb = hero_ground_aabb_local.translate(hero.x, hero.y);
    for (0..items_num) |i| {
        const item = items[i];
        if (item.kind != 0 and item_aabb.translate(item.x, item.y).overlaps(aabb)) {
            if (i == 0 and !hero_mask) {
                hero_mask = true;
            } else if (i == 1 and !hero_knife) {
                hero_knife = true;
            }
            items[i].kind = 0;
            sfx.collect();
        }
    }

    if (map.getPoint(aabb.cx(), aabb.cy()) > 1) {
        if (hero_visible > 0) {
            hero_visible -= 1;
        }
    } else if (hero_visible < hero_visible_max) {
        hero_visible += 1;
    }

    if (testPortals(aabb)) |portal| {
        //level += 1;
        //level_started = false;
        hero.x = portal.dest.x;
        hero.y = portal.dest.y;
        no_black_screen_target = 15;
        sfx.portal();
    }

    if (hero_knife and hero_mask) {
        if (hero_attack_t > 0) {
            hero_attack_t -= 1;
        }
        if (hero_attack_t == 0 and hero_visible > 8) {
            hero_attack_t = 32;
            sfx.attack();
        }
    }
}
fn updateGame() void {
    updateHero();
    updateMobs();
}

fn testPortals(rc: FPRect) ?*Portal {
    for (0..portals_num) |i| {
        if (portals[i].rc.overlaps(rc)) {
            return &portals[i];
        }
    }
    return null;
}

fn findClosestPortal(x: i32, y: i32) ?*Portal {
    var min_dist: i32 = 1000000;
    var min_portal: ?*Portal = null;
    for (0..portals_num) |i| {
        const dist = fp32.dist(x, y, portals[i].rc.x, portals[i].rc.y);
        if (dist < min_dist) {
            min_dist = dist;
            min_portal = &portals[i];
        }
    }
    return min_portal;
}

var hero_text_i: u32 = 0;
var hero_text_t: u32 = 0;
pub fn update() void {
    updateGameState();
    updateGame();

    sfx.update();
    particles.update();

    if (hero_visible > 8 and game_state == 1 and hero_hp != 0) {
        if (hero_text_t > 0) {
            const msg = texts.hero[hero_text_i];
            setText(0, msg, FPVec2.init(hero.x, hero.y - (48 << fbits)), 0xFF0000, 2);
            hero_text_t -= 1;
        } else {
            unsetText(0);
            if (g_rnd.next() & 0x7F == 0) {
                hero_text_i = g_rnd.next() % texts.hero.len;
                hero_text_t = texts.hero[hero_text_i].len << 2;
            }
        }
    }

    if (hero_hp <= 0) {
        if (game_over_t > 0) {
            game_over_t -= 1;
        } else if (game_over_t == 0) {
            if (gain.pointers.primary()) |p| {
                if (p.is_down) {
                    setGameState(1);
                    initLevel();
                }
            }
        }
    }
}

fn setText(handle: i32, text: []const u8, pos: FPVec2, color: u32, size: i32) void {
    if (camera.rc.test2(pos.x, pos.y)) {
        const xy = Vec2.fromIntegers(pos.x, pos.y).transform(camera.matrix);
        gain.js.text(handle, @intFromFloat(xy.x), @intFromFloat(xy.y), color, size, text.ptr, text.len);
    } else {
        unsetText(handle);
    }
}

fn unsetText(handle: i32) void {
    gain.js.text(handle, 0, 0, 0, 0, "", 0);
}

fn unsetAllTexts() void {
    for (0..mobs_max + 3) |i| {
        unsetText(@bitCast(i));
    }
}

fn getHeroOffY(move_timer: i32) i32 {
    return @intCast((((move_timer & 31) + 7) >> 4) << fbits);
}

fn drawTempMan(px: i32, py: i32, dx: i32, dy: i32, move_timer: i32, body_color: u32, head_color: u32, cloth_color: u32, is_hero: bool, is_male: bool, is_student: bool) void {
    const x = px + hero_aabb_local.x;
    const y = py + hero_aabb_local.y;
    const hero_y_off = getHeroOffY(move_timer);
    const is_mask = is_hero and hero_mask;
    const is_knife = is_hero and hero_knife;
    const ss = gain.math.sintau(fp32.toFloat(move_timer >> 1)) / 40.0;

    if (is_knife and is_mask) {
        gfx.push(x + (hero_w >> 1) + (1 << fbits), y + (16 << fbits) - hero_y_off, 0);
        gfx.color(colors.red);
        gfx.banner13();
        gfx.restore();
    }

    if (is_knife) {
        var ang = ss;
        if (hero_attack_t > 15) {
            ang = @floatFromInt(hero_attack_t - 15);
            ang /= 15;
        }
        gfx.push(x + hero_w, y + (18 << fbits) - hero_y_off, -ang);
        gfx.knife(@max(0, (hero_attack_t - 8) << fbits));
        gfx.restore();
    }
    if (is_mask) {
        const ang = -ss / 2;
        gfx.push(x + (hero_w >> 1), y + (4 << fbits) - (hero_y_off >> 1), ang);
        gfx.hockeyMask(head_color);
        gfx.restore();
    }

    if (!is_hero) {
        if (is_student) {
            if (!is_male) {
                // swimming top
                gfx.color(cloth_color);
                gfx.push(x + (hero_w >> 1), y + (14 << fbits) - hero_y_off, 0);
                if (dy >= 0) {
                    gfx.circle(-3 << fbits, 0, 3 << fbits, 2 << fbits, 4);
                    gfx.circle(3 << fbits, 0, 3 << fbits, 2 << fbits, 4);
                } else {
                    gfx.line(-5 << fbits, 0, 5 << fbits, 0, 1 << fbits, 1 << fbits);
                }
                gfx.restore();
            } else {
                if (dy >= 0) {
                    // draw NIPPLES
                    gfx.push(x + (hero_w >> 1), y + (14 << fbits) - hero_y_off, 0);
                    gfx.color(0xFF999999);
                    gfx.circle(-3 << fbits, 0, 1 << fbits, 1 << fbits, 4);
                    gfx.circle(3 << fbits, 0, 1 << fbits, 1 << fbits, 4);
                    gfx.restore();
                }
            }
        }
    }

    if (!is_mask) {
        gfx.push(x + (hero_w >> 1), y + (4 << fbits) - (hero_y_off >> 1), -ss);
        gfx.head(dx, dy, head_color, 0x0, 0xFF000000);
        gfx.restore();
    }

    if (!is_hero and is_student) {
        gfx.color(cloth_color);
        gfx.push(x + (hero_w >> 1), y + (20 << fbits) - hero_y_off, ss);
        gfx.trouses();
        gfx.restore();
    }
    gfx.quad(x, y - hero_y_off + (8 << fbits), hero_w, hero_h - hero_y_off - (2 << fbits) - (8 << fbits), body_color);

    gfx.quad(x - (2 << fbits), y + (10 << fbits) - hero_y_off, 2 << fbits, 8 << fbits, body_color);
    gfx.quad(x + hero_w, y + (10 << fbits) - hero_y_off, 2 << fbits, 8 << fbits, body_color);

    gfx.quad(x, y - (hero_y_off << 1) + (hero_h - (2 << fbits)), 4 << fbits, 2 << fbits, body_color);
    gfx.quad(x + (6 << fbits), y - (hero_y_off << 1) + (hero_h - (2 << fbits)), 4 << fbits, 2 << fbits, body_color);
}

fn drawHero() void {
    if (hero_hp != 0) {
        const head_color = Color32.lerp8888b(0xFF888888, 0xFFFFFFFF, hero_visible << 3);
        const body_color = Color32.lerp8888b(0xFF000000, 0xFF333333, hero_visible << 3);
        gfx.depth(hero.x, hero.y);
        drawTempMan(hero.x, hero.y, hero_look_x, hero_look_y, hero_move_timer, body_color, head_color, 0, true, true, false);
    }
}

fn drawManShadow(x: i32, y: i32, move_timer: i32) void {
    const y_off = getHeroOffY(move_timer) >> fbits;
    gfx.shadow(x, y, 7 << fbits, @as(u32, @intCast(0x44 - 0x20 * y_off)) << 24);
}

fn drawPortals() void {
    for (0..portals_num) |i| {
        const p = portals[i];
        gfx.depth(0, p.rc.b());
        gfx.rect(p.rc.expandInt(-2), 0xFF000000);
        gfx.rect(p.rc, 0xFFFFFFFF);
    }
}

fn drawItem(i: usize) void {
    const item = items[i];
    const x = item.x;
    const y = item.y;
    gfx.depth(x, y);
    gfx.push(x, y - (8 << fbits), fp32.toFloat(@bitCast(gain.app.tic + (i << 4))) / 10);
    if (i == 0) {
        // draw mask
        gfx.hockeyMask(0xFFFFFFFF);
    } else if (i == 1) {
        gfx.knife(0);
        // draw knife
    } else {
        const rc = FPRect.fromInt(0, 0, 0, 0).expandInt(4);
        gfx.rect(rc, 0xFF00FF00);
        gfx.rect(rc.expandInt(1), 0xFF444444);
    }
    gfx.restore();
}

fn getMobColor(kind: i32) u32 {
    return switch (kind) {
        1 => 0xFFFFBB99,
        2 => 0xFFFFCCCC,
        3 => 0xFFCCAA66,
        else => 0xFFCCFF99,
    };
}

fn getMobTrousesColor(kind: i32) u32 {
    return switch (kind) {
        1 => 0xFFFF00FF,
        2 => 0xFFFFFF00,
        3 => 0xFFFF0000,
        else => 0xFF000000,
    };
}

fn drawMob(i: usize) void {
    const mob = mobs[i];
    var x = mob.x;
    var y = mob.y;

    gfx.depth(x, y);

    if (mob.danger_t > 0) {
        x += g_rnd.int(-1, 1) << fbits;
        y += g_rnd.int(-2, 0) << fbits;
        gfx.push(x + (8 << fbits), y - (32 << fbits), 0);
        gfx.scream();
        gfx.restore();
    }

    if (mob.attention > 0 and !mob.danger) {
        gfx.push(x, y - (32 << fbits), 0);
        gfx.attention();
        gfx.restore();
    }

    var head_color = getMobColor(mob.kind);
    var body_color = head_color;
    if (!mob.is_student) {
        body_color = 0xFF666688;
    }
    head_color = Color32.lerp8888b(head_color, 0xFFFFFFFF, mob.hit_timer << 4);
    body_color = Color32.lerp8888b(body_color, 0xFFFFFFFF, mob.hit_timer << 4);
    drawTempMan(x, y, mob.lx, mob.ly, mob.move_timer, body_color, head_color, getMobTrousesColor(mob.kind), false, mob.male, mob.is_student);
}

fn drawVPad() void {
    if (gain.pointers.primary()) |p| {
        if (p.is_down) {
            const scale = camera.scale;
            gain.gfx.state.z = 10 << fbits;
            const q = FPVec2.init(@intFromFloat(p.pos.x), @intFromFloat(p.pos.y));
            const s = FPVec2.init(@intFromFloat(p.start.x), @intFromFloat(p.start.y));
            const r = fp32.scale(fp32.fromInt(24), scale);
            const r2 = fp32.scale(fp32.fromInt(60), scale);
            const r3 = fp32.scale(fp32.fromInt(64), scale);
            gfx.color(0xFF999999);
            gfx.circle(q.x, q.y, r, r, 64);
            gfx.color(0xFF444444);
            gfx.circle(s.x, s.y, r2, r2, 64);
            gfx.color(0xFF111111);
            gfx.circle(s.x, s.y, r3, r3, 64);
        }
    }
}

pub fn render() void {
    camera.update(hero.x, hero.y);

    gain.gfx.setupOpaquePass();
    gain.gfx.state.matrix = Mat2d.identity();

    drawVPad();

    gain.gfx.state.matrix = camera.matrix;

    //drawMiniMap();

    drawHero();

    drawPortals();

    for (0..items_num) |i| {
        const item = items[i];
        if (item.kind != 0 and item_aabb.translate(item.x, item.y).overlaps(camera.rc)) {
            drawItem(i);
        }
    }

    for (0..mobs_num) |i| {
        const mob = mobs[i];
        if (mob.kind != 0 and mob_quad_local.translate(mob.x, mob.y).overlaps(camera.rc)) {
            drawMob(i);
        }
    }

    particles.draw(camera.rc);
    drawMap(camera.rc);
    drawBack(camera.rc);

    gain.gfx.setupBlendPass();

    if (hero_hp != 0 and hero_attack_t > 15) {
        gfx.depth(hero.x, hero.y);
        gfx.color(Color32.lerp8888b(0x00000000, 0xFFFFFFFF, @bitCast(hero_attack_t)));
        gfx.circle(hero.x, hero.y, 24 << fbits, 16 << fbits, 32);
    }

    for (0..mobs_num) |i| {
        const mob = mobs[i];
        if (mob.kind != 0 and mob_quad_local.translate(mob.x, mob.y).overlaps(camera.rc)) {
            if (mob.attack_t > 8) {
                gfx.depth(mob.x, mob.y);
                gfx.color(Color32.lerp8888b(0x00000000, 0xFFFFFFFF, @bitCast(mob.attack_t)));
                gfx.circle(mob.x, mob.y, 24 << fbits, 16 << fbits, 32);
            }
        }
    }

    gain.gfx.state.z = 4 << fbits;
    if (hero_hp != 0) {
        drawManShadow(hero.x, hero.y, hero_move_timer);
    }
    particles.drawShadows();

    for (0..mobs_num) |i| {
        const mob = mobs[i];
        if (mob.kind != 0 and mob_quad_local.translate(mob.x, mob.y).overlaps(camera.rc)) {
            drawManShadow(mob.x, mob.y, mob.move_timer);
        }
    }

    for (0..items_num) |i| {
        const item = items[i];
        if (item.kind != 0 and item_aabb.translate(item.x, item.y).overlaps(camera.rc)) {
            gfx.shadow(item.x, item.y, 8 << fbits, colors.shadow);
        }
    }

    if (game_state == 1) {
        drawHUD();
    }
    drawMenu();
}

fn drawHUD() void {
    gain.gfx.state.z = (1 << 15) << fbits;
    //gfx.state.matrix = Mat2d.identity();
    const space_x: i32 = @divTrunc(512 << fbits, 14);
    gain.gfx.state.matrix = gain.gfx.state.matrix
        .translate(Vec2.fromIntegers(camera.rc.cx(), camera.rc.y))
        .translate(Vec2.fromIntegers((-(512 << fbits) >> 1), 20 << fbits));
    for (0..13) |i| {
        var rc = FPRect.init(0, 0, 0, 0);

        gain.gfx.state.matrix = gain.gfx.state.matrix.translate(Vec2.fromIntegers(space_x, 0));
        const mat = gain.gfx.state.matrix;
        gain.gfx.state.matrix = gain.gfx.state.matrix.rotate(0.1); // * @as(f32, @floatFromInt(i / 3)));
        //gfx.state.matrix = gfx.state.matrix.rotate(0.1);
        gfx.rect(rc.expandInt(12).translate(1 << fbits, 1 << fbits), 0xFF111111);
        gfx.rect(rc.expandInt(10), 0xFFCCCCCC);
        if (i < kills) {
            gfx.color(0xFF880000);
            rc = rc.expandInt(8);
            gfx.line(rc.x, rc.y, rc.r(), rc.b(), 4 << fbits, 2 << fbits);
            gfx.line(rc.x, rc.b(), rc.r(), rc.y, 3 << fbits, 4 << fbits);
        }
        gain.gfx.state.matrix = mat;
    }
}

fn drawMap(camera_rc: FPRect) void {
    const _cx = camera_rc.x >> cell_size_bits;
    const _cy = camera_rc.y >> cell_size_bits;
    const _cw = camera_rc.w >> cell_size_bits;
    const _ch = camera_rc.h >> cell_size_bits;
    const ccx0: usize = @intCast(@max(0, _cx));
    const ccx1: usize = @intCast(@max(0, _cx + _cw + 2));
    const ccy0: usize = @intCast(@max(0, _cy));
    const ccy1: usize = @intCast(@max(0, _cy + _ch + 2));

    //drawPath();

    for (ccy0..ccy1) |cy| {
        const index = cy << map.size_bits;
        for (ccx0..ccx1) |cx| {
            const cell = map.map[index + cx];
            if (cell != 0) {
                gain.gfx.state.z = 2 << fbits;
                const x: i32 = @intCast((cx << cell_size_bits) + cell_size_half);
                const y: i32 = @intCast((cy << cell_size_bits) + cell_size_half);
                // const sz0: i32 = invDist(hero.x, hero.y, x, y);
                // const sz = sz0 + ((@as(i32, @intCast((app.tic >> 3) + (cx *% cy))) & 7) << (fbits - 4));
                // const cell_size_v = Vec2.fromIntegers(sz << 1, sz << 1);
                // gfx.state.matrix = matrix
                //     .translate(Vec2.fromIntegers(x, y))
                //     .rotate(std.math.pi * (1 - @as(f32, @floatFromInt(sz0)) / (cell_size_half)));
                // gfx.quad(Vec2.fromIntegers(-sz, -sz), cell_size_v, 0xFF338866);

                var color = map.colormap[map.colors[map.addr(cx, cy)]];
                if (cell > 1) {
                    color = Color32.lerp8888b(color, 0xFF000000, 16);
                }
                gfx.rect(FPRect.init(x, y, 0, 0).expand(cell_size_half, cell_size_half), color);

                if (map.map[index + cx - map.size] == 0) {
                    gfx.rect(FPRect.init(x, y - cell_size_half, 0, 0).expand(cell_size_half, cell_size_half), 0xFF223322);
                }

                if (cell > 1) {
                    gfx.depth(x, y + cell_size_half);
                    if (cell == 2) {
                        for (0..2) |iy| {
                            const iiy: i32 = @intCast(iy);
                            gfx.quad(x - cell_size_half, y + (iiy * cell_size_half >> 1), cell_size, 4 << fbits, 0xFF664433);
                        }
                        for (0..5) |ix| {
                            const iix: i32 = @intCast(ix);
                            gfx.quad(x - cell_size_half + (iix * cell_size >> 2), y, 2 << fbits, cell_size_half, 0xFF664433);
                        }
                    } else if (cell == 3) {
                        const ss = gain.math.sintau(fp32.toFloat(@bitCast(app.tic +% (cx * cy))) / 8) / 100.0;
                        gfx.depth(x, y + (cell_size_half >> 1));
                        gfx.color(0xFF336633);
                        gfx.push(x, y + (8 << fbits), ss);
                        gfx.circle(0, -(24 << fbits), 16 << fbits, 16 << fbits, 8);
                        gfx.quad(-(2 << fbits), -cell_size_half, 4 << fbits, cell_size_half, 0xFF664400);
                        gfx.restore();
                    } else if (cell == 4) {
                        // const ss: f32 = 0.1 * gain.math.sintau(fp32.toFloat(@bitCast(app.tic +% (cx * cy))) / 8);
                        gfx.push(x, y + (8 << fbits), 0);
                        gfx.color(0xFF336633);
                        gfx.circle(0, -4 << fbits, 10 << fbits, 12 << fbits, 8);
                        gfx.circle(-8 << fbits, 0, 8 << fbits, 8 << fbits, 8);
                        gfx.circle(8 << fbits, 0, 8 << fbits, 8 << fbits, 8);
                        //gfx.quad(x - cell_size_half, y, cell_size, cell_size_half, 0xFF003300);
                        gfx.restore();
                    }
                }
            } else {
                // const x: i32 = @intCast((cx << cell_size_bits) + cell_size_half);
                // const y: i32 = @intCast((cy << cell_size_bits) + cell_size_half);
                //drawRect(FPRect.init(x, y, 0, 0).expand(cell_size_half, cell_size_half), 0xFF001100);
            }
        }
    }
}

fn drawMiniMap() void {
    //gain.gfx.state.matrix = Mat2d.identity();
    gain.gfx.state.z = (1 << 15) << fbits;
    for (0..map.size) |cy| {
        const index = cy << map.size_bits;
        for (0..map.size) |cx| {
            const cell = map.map[index + cx];
            const rc = FPRect.fromInt(@bitCast(cx), @bitCast(cy), 1, 1).translate(hero.x, hero.y);
            var color: u32 = 0xFF000000;
            if (cell != 0) {
                color = map.colormap[map.colors[map.addr(cx, cy)]];
                if (cell > 1) {
                    color = Color32.lerp8888b(color, 0xFF000000, 16);
                }
            }
            gfx.rect(rc, color);
        }
    }
}

fn drawPath() void {
    const rc = FPRect.init(cell_size_half, cell_size_half, 0, 0).expandInt(4);
    for (0..map.path_num) |i| {
        gfx.rect(rc.translate(map.path_x[i] << cell_size_bits, map.path_y[i] << cell_size_bits), if (map.path_num > 0) 0xFFFFFFFF else 0xFFFFFF00);
    }
    gfx.rect(rc.translate(map.path_dest_x << cell_size_bits, map.path_dest_y << cell_size_bits), 0xFFFF0000);
}

fn drawBack(camera_rc: FPRect) void {
    gain.gfx.state.z = 2 << fbits;
    const tile_size = 64 << fbits;
    var cy = camera_rc.y;
    while (cy < camera_rc.b() + tile_size) {
        var cx = camera_rc.x;
        while (cx < camera_rc.r() + tile_size) {
            const x = (cx >> (6 + fbits)) << (6 + fbits);
            const y = (cy >> (6 + fbits)) << (6 + fbits);
            const local_seed = x +% (y << 8);
            var rnd = gain.math.Rnd{ .seed = @bitCast(local_seed) };
            var n = rnd.next() & 3;
            while (n != 0) {
                const dx = rnd.int(-32 << fbits, 32 << fbits);
                const dy = rnd.int(-32 << fbits, 32 << fbits);
                const a = (rnd.float() - 0.5) / 16.0;
                const t = fp32.toFloat(dx - dy + @as(i32, @bitCast(app.tic))) / 2;
                const t2 = fp32.toFloat(dx + dy - @as(i32, @bitCast(app.tic))) / 4;
                const fx = fp32.fromFloat(gain.math.costau(t) * 2);
                const fy = fp32.fromFloat(gain.math.sintau(t));
                const size = rnd.int(1 << fbits, 3 << fbits);
                if (gain.math.sintau(t2) > 0.5) {
                    gfx.push(x + dx + fx, y + dy + fy, a);
                    gfx.color(0xFF666666);
                    gfx.circle(0, 0, size, size, 8);
                    gfx.color(0xFF000000);
                    gfx.circle(0, 0, size * 3, size, 6);
                    gfx.restore();
                }
                n -= 1;
            }
            cx += 64 << fbits;
        }
        cy += 64 << fbits;
    }

    gain.gfx.state.z = 1 << fbits;
    gfx.rect(camera_rc, 0xFF222222);
    gain.gfx.state.z = 0;
    gfx.rect(camera_rc.expandInt(128 << fbits), 0xFF000000);
}

// MENU
var game_state: u8 = 0;
var game_state_init: bool = false;
var no_black_screen_t: u8 = 0;
var no_black_screen_target: u8 = 0;
var game_state_tics: i32 = 0;

fn setGameState(state: u8) void {
    game_state_tics = 0;
    no_black_screen_target = 15;
    no_black_screen_t = 0;
    game_state = state;
}

fn updateGameState() void {
    game_state_tics += 1;
    if (game_state == 0) {
        setText(100, "FRI3", FPVec2.init(hero.x, hero.y - (128 << fbits)), 0xFF0000, 10);
        setText(101, "TAP TO START", FPVec2.init(hero.x, hero.y + (64 << fbits)), 0x880000, 4);
        setText(102, "js13k game by\n\nIlya Kuzmichev\n&\nAlexandra Alhovik", FPVec2.init(hero.x, hero.y + (128 << fbits)), 0xCCCCCC, 2);

        if (game_state_tics == 1) {
            no_black_screen_target = 15;
            hero_hp = 1;
            hero_mask = true;
            hero_knife = true;
            map.current_color = 2;
            for (4..16) |cy| {
                for (4..16) |cx| {
                    map.set(cx, cy, @intCast(g_rnd.int(1, 4)));
                    if (cx & 1 == 1 and cy & 1 == 0) {
                        placeMob(@bitCast(cx), @bitCast(cy), g_rnd.int(1, 3), g_rnd.next() & 1 == 1, true);
                    }
                }
            }
            hero.x = (10 << cell_size_bits);
            hero.y = (10 << cell_size_bits);
            level_started = true;
        }
        if (gain.pointers.primary()) |p| {
            if (p.down) {
                setGameState(1);
                initLevel();
            }
        }
    }

    if (no_black_screen_t < no_black_screen_target) {
        no_black_screen_t += 1;
    } else if (no_black_screen_t > no_black_screen_target) {
        no_black_screen_t -= 1;
    }
}

fn drawMenu() void {
    // draw text
    if (no_black_screen_t < 15) {
        gain.gfx.state.matrix = Mat2d.identity();
        gfx.rect(FPRect.init(0, 0, @intCast(app.w), @intCast(app.h)), Color32.lerp8888b(
            0xFF000000,
            0x00000000,
            no_black_screen_t << 4,
        ));
    }
}
