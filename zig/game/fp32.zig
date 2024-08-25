pub const fbits = 4;
pub const fp32 = i32;

pub fn fromInt(integer_value: i32) fp32 {
    return integer_value << fbits;
}

pub fn getInt(v: fp32) i32 {
    return v >> fbits;
}

pub fn toFloat(v: fp32) f32 {
    return @as(f32, @floatFromInt(v)) / (1 << fbits);
}

pub fn fromFloat(v: f32) fp32 {
    return @intFromFloat(v * (1 << fbits));
}

pub fn scale(v: fp32, f: f32) fp32 {
    // 8362
    const sc: i32 = @intFromFloat(f * (1 << fbits));
    return (sc * v) >> fbits;

    // 8378
    // return fromFloat(toFloat(v) * f);
}

pub fn mul(a: fp32, b: fp32) fp32 {
    //return fromFloat(toFloat(a) * toFloat(b));
    return (a * b) >> fbits;
}

pub fn div(a: fp32, b: fp32) fp32 {
    //return fromFloat(toFloat(a) / toFloat(b));
    return @divTrunc(a << fbits, b);
}
