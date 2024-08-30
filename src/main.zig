const std = @import("std");

pub fn match(thing: anytype) ArmMatcher(PointerChildOfSingle(@TypeOf(thing))) {
    return .{
        .thing_ptr = thing,
    };
}

pub fn PointerChildOfSingle(T: type) type {
    return switch (@typeInfo(T)) {
        .Pointer => |ptrinfo| switch (ptrinfo.size) {
            .One => ptrinfo.child,
            .Many, .Slice, .C => @compileError("Thing passed into match must be single item pointer"),
        },
        else => @compileError("Thing passed into match must be single item pointer"),
    };
}

pub fn ArmMatcher(T_: type) type {
    return struct {
        pub const T = T_;
        thing_ptr: *const T,

        // TODO: should pattern have to be comptime known
        pub fn arm(self: @This(), pattern: anytype) ?Captures(T, pattern) {
            var out: Captures(T, pattern) = undefined;
            if (!tryBind(self.thing_ptr, pattern, &out)) return null;
            return out;
        }
    };
}

fn tryBind(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
    const ValType = @typeInfo(@TypeOf(val_ptr)).Pointer.child;
    if (@TypeOf(pattern) == MatcherType) {
        const custom_matcher = pattern(ValType);
        return custom_matcher.tryBind(custom_matcher, val_ptr, out_ptr);
    }
    return switch (@typeInfo(ValType)) {
        .Struct => tryBindStruct(val_ptr, pattern, out_ptr),
        .Union => tryBindUnion(val_ptr, pattern, out_ptr),
        .Optional => tryBindOptional(val_ptr, pattern, out_ptr),
        .Array => tryBindArray(val_ptr, pattern, out_ptr),
        // TODO: add additional features for matching on scalars
        .Int, .ComptimeInt, .Bool, .Float, .ComptimeFloat, .Enum => pattern == val_ptr.*,
        .Pointer => |payload| switch (payload.size) {
            .One => tryBind(val_ptr.*, pattern, out_ptr),
            .Slice => tryBindSlice(val_ptr.*, pattern, out_ptr),
            // already compile errors in PointerCaptures
            .Many, .C => unreachable,
        },
        // TODO: implement other types
        else => @compileError("TODO: implement other types"),
    };
}

fn tryBindStruct(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
    const ValType = @typeInfo(@TypeOf(val_ptr)).Pointer.child;
    inline for (@typeInfo(ValType).Struct.fields) |field| {
        if (!tryBind(&@field(val_ptr, field.name), @field(pattern, field.name), out_ptr)) return false;
    }
    return true;
}

fn tryBindUnion(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
    const TagEnum = @typeInfo(@TypeOf(val_ptr.*)).Union.tag_type orelse @compileError("matching on a union requires a tag type");
    const variant_name = @typeInfo(@TypeOf(pattern)).Struct.fields[0].name;
    // TODO: this might be inefficient
    if (std.meta.activeTag(val_ptr.*) != @field(TagEnum, variant_name)) return false;
    return tryBind(&@field(val_ptr, variant_name), @field(pattern, variant_name), out_ptr);
}

fn tryBindOptional(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
    if (@TypeOf(pattern) == @TypeOf(null)) return val_ptr.* == null;
    if (val_ptr.* == null) return @TypeOf(pattern) == @TypeOf(null);

    const NewValPtrType = comptime blk: {
        const ChildValType = @typeInfo(@TypeOf(val_ptr.*)).Optional.child;
        var typeinfo = @typeInfo(@TypeOf(val_ptr));
        typeinfo.Pointer.child = ChildValType;
        break :blk @Type(typeinfo);
    };
    return tryBind(@as(NewValPtrType, @ptrCast(val_ptr)), pattern, out_ptr);
}

fn tryBindSinglePointer(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
    // cases with double pointers are handled in PointerCaptures
    return tryBind(val_ptr.*, pattern, out_ptr);
}

fn tryBindArray(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
    // all invalid patterns should have been caught by ArrayCaptures (such as .{ ..., thing2, ...}) but in the future analysis order might change, causing confusing errors here
    const ValType = @typeInfo(@TypeOf(val_ptr)).Pointer.child;
    const real_len = @typeInfo(@TypeOf(val_ptr.*)).Array.len;
    const ChildT = @typeInfo(ValType).Array.child;
    const subslice_len = real_len - pattern.len + 1;
    if (real_len < pattern.len) @compileError("Array pattern is longer than the actual array");
    const idx_of_matcher: ?usize = comptime for (&pattern, 0..) |pattern_field, i| {
        if (@TypeOf(pattern_field) == SubSliceMatcherType) break i;
    } else null;
    // case where there is a special SubArrayMatcher somewhere
    if (idx_of_matcher) |idx_of_matcher_| {
        const start_subarray = idx_of_matcher_;
        const end_subarray = real_len - pattern.len + 1 + idx_of_matcher_;

        // TODO: use slicing of tuples https://github.com/ziglang/zig/issues/4625
        // start
        inline for (0..idx_of_matcher_) |i| {
            if (!tryBind(&val_ptr[i], pattern[i], out_ptr)) return false;
        }
        // middle
        const custom_matcher = pattern[idx_of_matcher_](ChildT, subslice_len);
        if (!custom_matcher.tryBind(custom_matcher, val_ptr[start_subarray..end_subarray], out_ptr)) return false;
        //end
        inline for (idx_of_matcher_ + 1..pattern.len, end_subarray..real_len) |pattern_i, i| {
            if (!tryBind(&val_ptr[i], pattern[pattern_i], out_ptr)) return false;
        }
        // case where theres no special SubArrayMatcher
    } else {
        inline for (pattern, 0..) |pattern_field, i| {
            if (!tryBind(&val_ptr[i], pattern_field, out_ptr)) return false;
        }
    }
    return true;
}

fn tryBindSlice(val_slice: anytype, pattern: anytype, out_ptr: anytype) bool {
    // all invalid patterns should have been caught by SliceCaptures (such as .{ ..., thing2, ...}) but in the future analysis order might change, causing confusing errors here
    const real_len = val_slice.len;
    const ChildT = @typeInfo(@TypeOf(val_slice)).Pointer.child;
    if (real_len < pattern.len) return false;
    const idx_of_matcher: ?usize = comptime for (&pattern, 0..) |pattern_field, i| {
        if (@TypeOf(pattern_field) == SubSliceMatcherType) break i;
    } else null;
    // case where there is a special SubArrayMatcher somewhere
    if (idx_of_matcher) |idx_of_matcher_| {
        const start_subarray = idx_of_matcher_;
        const end_subarray = real_len - pattern.len + 1 + idx_of_matcher_;

        // TODO: use slicing of tuples https://github.com/ziglang/zig/issues/4625
        // start
        inline for (0..idx_of_matcher_) |i| {
            if (!tryBind(&val_slice[i], pattern[i], out_ptr)) return false;
        }
        // middle
        const custom_matcher = pattern[idx_of_matcher_](ChildT, null);
        if (!custom_matcher.tryBind(custom_matcher, val_slice[start_subarray..end_subarray], out_ptr)) return false;
        //end
        inline for (idx_of_matcher_ + 1..pattern.len, end_subarray..real_len) |pattern_i, i| {
            if (!tryBind(&val_slice[i], pattern[pattern_i], out_ptr)) return false;
        }
        // case where theres no special SubArrayMatcher
    } else {
        if (real_len != pattern.len) return false;
        inline for (pattern, 0..) |pattern_field, i| {
            if (!tryBind(&val_slice[i], pattern_field, out_ptr)) return false;
        }
    }
    return true;
}

fn Captures(T: type, pattern: anytype) type {
    if (@TypeOf(pattern) == MatcherType) return pattern(T).captures;
    return switch (@typeInfo(T)) {
        .Struct => StructCaptures(T, pattern),
        .Union => UnionCaptures(T, pattern),
        .Optional => OptionalCaptures(T, pattern),
        .Array => ArrayCaptures(T, pattern),
        .Int, .ComptimeInt, .Bool, .Float, .ComptimeFloat, .Enum => struct {},
        .Pointer => PointerCaptures(T, pattern),
        // TODO: implement other types
        else => {
            @compileLog(T, pattern);
            @compileError("TODO: implement other types");
        },
    };
}

/// assumes T is a struct type
fn StructCaptures(T: type, pattern: anytype) type {
    validateStructPattern(pattern);
    const pattern_info = @typeInfo(@TypeOf(pattern)).Struct;
    if (@typeInfo(T).Struct.fields.len != pattern_info.fields.len) @compileError(std.fmt.comptimePrint(
        \\ Found {d} fields in the pattern. Expected {d} in the match type. Use the __ function to always match
    , .{ pattern_info.fields.len, @typeInfo(T).Struct.fields.len }));
    var out_types: [pattern_info.fields.len]type = undefined;
    for (&out_types, pattern_info.fields) |*out, fieldinfo| {
        if (!@hasField(T, fieldinfo.name)) @compileError(std.fmt.comptimePrint("Field name \"{s}\" in pattern does not exist in match type", .{fieldinfo.name}));
        out.* = Captures(@TypeOf(@field(@as(T, undefined), fieldinfo.name)), @field(pattern, fieldinfo.name));
    }
    return FlattenStructs(&out_types);
}

fn UnionCaptures(T: type, pattern: anytype) type {
    validateStructPattern(pattern);
    const pattern_info = @typeInfo(@TypeOf(pattern)).Struct;
    if (pattern_info.fields.len > 1) @compileError("Pattern contains multiple variants of the same union for matching, use oneof for this purpose");
    const variant_name = pattern_info.fields[0].name;
    return Captures(@TypeOf(@field(@as(T, undefined), variant_name)), @field(pattern, variant_name));
}

fn OptionalCaptures(T: type, pattern: anytype) type {
    if (@TypeOf(pattern) == @TypeOf(null)) return struct {};

    return Captures(@typeInfo(T).Optional.child, pattern);
}

// TODO: maybe disallow double pointer captures (status quo is just deref them all bc thats easiest)
fn PointerCaptures(T: type, pattern: anytype) type {
    const T_info = @typeInfo(T).Pointer;
    return switch (T_info.size) {
        .One => Captures(T_info.child, pattern),
        .Slice => SliceCaptures(T, pattern),
        .Many, .C => @compileError("Cannot match against many or C pointer types"),
    };
}

fn ArrayCaptures(T: type, pattern: anytype) type {
    const pattern_info = @typeInfo(@TypeOf(pattern));
    if (pattern_info != .Struct) @compileError(std.fmt.comptimePrint("Matching against arrays expects tuple type for pattern, found {}", .{@TypeOf(pattern)}));
    if (!pattern_info.Struct.is_tuple) @compileError("Expected a tuple type when matching against arrays");
    const T_info = @typeInfo(T);
    var out_types: [pattern.len]type = undefined;

    if (@TypeOf(pattern[0]) == SubSliceMatcherType and @TypeOf(pattern[pattern.len - 1]) == SubSliceMatcherType) {
        @compileError("subslice matchers cannot be at both the start and the end of the pattern");
    }

    const real_len = @typeInfo(T).Array.len;
    if (real_len < pattern.len) @compileError("Array pattern is longer than the actual array");
    const ChildT = T_info.Array.child;
    const subslice_len = real_len - pattern.len + 1;
    // TODO: the position of things in out do not matter so all of this could be one block
    // .{ thing1, thing2, ... }
    if (@TypeOf(pattern[pattern.len - 1]) == SubSliceMatcherType) {
        for (out_types[0 .. pattern.len - 1], 0..) |*out, i| {
            if (@TypeOf(pattern[i]) == SubSliceMatcherType) @compileError("Cannot have a subslice matcher at both the middle and end of a pattern");
            out.* = Captures(ChildT, pattern[i]);
        }
        out_types[pattern.len - 1] = pattern[pattern.len - 1](ChildT, subslice_len).captures;
        // .{ ..., thing3, thing4 }
    } else if (@TypeOf(pattern[0]) == SubSliceMatcherType) {
        out_types[0] = pattern[0](ChildT, subslice_len).captures;
        for (out_types[1..pattern.len], 1..) |*out, i| {
            if (@TypeOf(pattern[i]) == SubSliceMatcherType) @compileError("Cannot have a subslice matcher at both the start and middle of a pattern");
            out.* = Captures(ChildT, pattern[i]);
        }
    } else {
        for (&out_types, 0..) |*out, i| {
            // .{ thing1, thing2, thing3, thing4 }
            if (@TypeOf(pattern[i]) != SubSliceMatcherType) {
                out.* = Captures(ChildT, pattern[i]);
                continue;
            }
            // .{ thing1, ..., thing4 }
            out_types[i] = pattern[i](ChildT, subslice_len).captures;
            for (out_types[i + 1 ..], i + 1..) |*out_, i_| {
                if (@TypeOf(pattern[i_]) == SubSliceMatcherType) @compileError("Cannot have 2 subarray matchers in a pattern");
                out_.* = Captures(ChildT, pattern[i_]);
            }
            break;
            // the loop finished successfully, meaning no subarray matchers were found
        } else {
            if (T_info.Array.len != pattern.len) @compileError("Array pattern without subarray matcher is not the same size as the actual array");
        }
    }

    return FlattenStructs(&out_types);
}

fn SliceCaptures(T: type, pattern: anytype) type {
    const pattern_info = @typeInfo(@TypeOf(pattern));
    if (pattern_info != .Struct) @compileError(std.fmt.comptimePrint("Matching against slices expects tuple type for pattern, found {}", .{@TypeOf(pattern)}));
    if (!pattern_info.Struct.is_tuple) @compileError("Expected a tuple type when matching against slices");
    const T_info = @typeInfo(T);
    var out_types: [pattern.len]type = undefined;

    const ChildT = T_info.Pointer.child;
    var found_matcher = false;
    var idx_of_matcher: ?usize = null;
    for (&pattern, 0..) |pattern_field, i| {
        if (@TypeOf(pattern_field) == SubSliceMatcherType) {
            if (found_matcher) @compileError("Cannot have more than 1 subslice matcher matching against a slice");
            idx_of_matcher = i;
            found_matcher = true;
        }
    }
    for (&out_types, 0..) |*out, i| {
        out.* = if (i == idx_of_matcher) pattern[i](ChildT, null).captures else Captures(ChildT, pattern[i]);
    }
    return FlattenStructs(&out_types);
}

/// asserts that a pattern is of struct type and not a tuple
fn validateStructPattern(pattern: anytype) void {
    const pattern_info = @typeInfo(@TypeOf(pattern));
    if (pattern_info != .Struct) @compileError(std.fmt.comptimePrint("Expected a struct type for pattern, found: {}", .{@TypeOf(pattern)}));
    if (pattern_info.Struct.is_tuple) @compileError("Found tuple type when pattern matching against struct, must use a struct with the field names");
}

pub const MatcherType = fn (comptime type) Matcher;

pub const Matcher = struct {
    /// struct type of all the captures
    captures: type,
    // TODO: add back context field if it turns out to have a use
    tryBind: fn (self: Matcher, val_ptr: anytype, out_ptr: anytype) bool,
};

/// receives the child type and subslice length (or null if its runtime known)
pub const SubSliceMatcherType = fn (comptime type, comptime ?usize) SubSliceMatcher;

pub const SubSliceMatcher = struct {
    captures: type,
    tryBind: fn (self: SubSliceMatcher, subslice: anytype, out_ptr: anytype) bool,
};

/// binds a fields value to the name, to be accessed in the out of the arm
pub fn bind(name: [:0]const u8) MatcherType {
    const try_bind_fn = struct {
        pub fn f(self: Matcher, val_ptr: anytype, out_ptr: anytype) bool {
            const fields = @typeInfo(self.captures).Struct.fields;
            @field(out_ptr, fields[0].name) = val_ptr.*;
            return true;
        }
    }.f;
    return struct {
        /// TODO: maybe have to pass in alignment?
        pub fn f(comptime T: type) Matcher {
            const capture_field: std.builtin.Type.StructField = .{
                .name = name,
                .is_comptime = false,
                .default_value = null,
                .alignment = @alignOf(T),
                .type = T,
            };
            const capture_type = @Type(.{ .Struct = .{
                .layout = .auto,
                .is_tuple = false,
                .fields = &.{capture_field},
                .decls = &.{},
            } });
            return .{
                .captures = capture_type,
                .tryBind = try_bind_fn,
            };
        }
    }.f;
}

/// matches everything successfully
pub fn __(_: type) Matcher {
    return .{
        .captures = struct {},
        .tryBind = struct {
            pub fn f(_: Matcher, _: anytype, _: anytype) bool {
                return true;
            }
        }.f,
    };
}

/// binds a ptr to the rest of an array or slice pattern to `name`
pub fn ref_rest(name: [:0]const u8) SubSliceMatcherType {
    const try_bind_fn = struct {
        pub fn f(self: SubSliceMatcher, subslice_ptr: anytype, out_ptr: anytype) bool {
            const fields = @typeInfo(self.captures).Struct.fields;
            @field(out_ptr, fields[0].name) = subslice_ptr;
            return true;
        }
    }.f;
    return struct {
        // TODO: should arrays be captured by value or as a slice? (currently I do it by value)
        pub fn f(comptime ChildT: type, comptime length: ?usize) SubSliceMatcher {
            const FieldType = if (length) |len| *const [len]ChildT else []const ChildT;
            const capture_field: std.builtin.Type.StructField = .{
                .name = name,
                .is_comptime = false,
                .default_value = null,
                .alignment = @alignOf(FieldType),
                .type = FieldType,
            };
            const capture_type = @Type(.{ .Struct = .{
                .layout = .auto,
                .is_tuple = false,
                .fields = &.{capture_field},
                .decls = &.{},
            } });
            return .{
                .captures = capture_type,
                .tryBind = try_bind_fn,
            };
        }
    }.f;
}

pub fn ignore_rest(_: type, _: ?usize) SubSliceMatcher {
    return .{
        .captures = struct {},
        .tryBind = struct {
            pub fn f(_: SubSliceMatcher, _: anytype, _: anytype) bool {
                return true;
            }
        }.f,
    };
}

/// flattens an array of struct types into 1 struct type
fn FlattenStructs(types: []type) type {
    var acc: comptime_int = 0;
    for (types) |type_| acc += @typeInfo(type_).Struct.fields.len;

    var fields: [acc]std.builtin.Type.StructField = undefined;
    var i: comptime_int = 0;
    for (types) |type_| {
        for (@typeInfo(type_).Struct.fields) |field| {
            fields[i] = field;
            i += 1;
        }
    }
    return @Type(.{ .Struct = .{
        .is_tuple = false,
        .layout = .auto,
        .decls = &.{},
        .fields = &fields,
    } });
}

test Captures {
    const thing: struct { age: u32, birth: u64 } = undefined;
    const out = @typeInfo(Captures(@TypeOf(thing), .{ .age = bind("age_years"), .birth = bind("birthday_utc") }));
    const exp_out = @typeInfo(struct { age_years: u32, birthday_utc: u64 });

    // for some reason this errors if called without comptime
    try comptime std.testing.expectEqualDeep(exp_out, out);
}

// comptime for match is not required, I use it here to demonstrate that there is no runtime overhead
test match {
    const thing: struct { age: u32, birth: u64, pos: struct { x: u8, y: u8 } } = .{ .age = 3, .birth = 2, .pos = .{ .x = 90, .y = 20 } };
    const m = comptime match(&thing);
    const res = m.arm(.{ .age = 3, .birth = bind("hello"), .pos = .{ .x = bind("__x__"), .y = 20 } });
    try std.testing.expectEqual(2, res.?.hello);
    try std.testing.expectEqual(90, res.?.__x__);

    const res2 = m.arm(.{ .age = 3, .birth = bind("hello"), .pos = bind("pos") });
    try std.testing.expectEqual(2, res2.?.hello);
    try std.testing.expectEqual(90, res2.?.pos.x);
    try std.testing.expectEqual(20, res2.?.pos.y);

    const res3 = m.arm(.{ .age = __, .birth = __, .pos = .{ .x = __, .y = bind("y") } });
    try std.testing.expectEqual(20, res3.?.y);
}
test "match: unions" {
    const Thing = struct { val: u32, impl: union(enum) { foo: u64, bar: f64 } };
    {
        const thing: Thing = .{ .val = 1000, .impl = .{ .foo = 90 } };
        const m = comptime match(&thing);

        const res = m.arm(.{ .val = 1000, .impl = .{ .bar = __ } });
        const res2 = m.arm(.{ .val = __, .impl = .{ .foo = 91 } });
        const res3 = m.arm(.{ .val = __, .impl = .{ .foo = bind("hello") } });

        try std.testing.expectEqual(null, res);
        try std.testing.expectEqual(null, res2);
        try std.testing.expectEqual(90, res3.?.hello);
    }
}

test "match: optionals" {
    const House = struct {
        address: ?struct {
            number: u32,
            street_num: u64,
            duplex_is_first: ?bool,
        },
        quality: ?u32,
        proof: u32,
    };
    {
        const thing: House = .{ .address = null, .quality = null, .proof = 1 };
        const m = comptime match(&thing);
        const res = m.arm(.{ .address = null, .quality = null, .proof = bind("proof") });
        const res2 = m.arm(.{ .address = .{ .number = __, .street_num = __, .duplex_is_first = __ }, .quality = null, .proof = 1 });
        const res3 = m.arm(.{ .address = __, .quality = null, .proof = bind("proof") });

        try std.testing.expectEqual(1, res.?.proof);
        try std.testing.expectEqual(null, res2);
        try std.testing.expectEqual(1, res3.?.proof);
    }
    {
        const thing: House = .{ .address = .{ .number = 1235, .street_num = 2, .duplex_is_first = true }, .quality = 2, .proof = 1 };
        const m = comptime match(&thing);
        const res = m.arm(.{ .address = null, .quality = null, .proof = 1 });
        const res2 = m.arm(.{ .address = .{ .number = __, .street_num = __, .duplex_is_first = __ }, .quality = null, .proof = 1 });
        const res3 = m.arm(.{ .address = __, .quality = null, .proof = 1 });

        try std.testing.expectEqual(null, res);
        try std.testing.expectEqual(null, res2);
        try std.testing.expectEqualDeep(null, res3);
    }
}

test "match: arrays" {
    const list = [_]u8{ 0, 9, 100, 140 };
    const m = comptime match(&list);
    const res = m.arm(.{ 0, 9, 100, bind("num") });
    const res2 = m.arm(.{ ref_rest("first2"), 100, 140 });
    const res3 = m.arm(.{ bind("head"), ref_rest("tail") });
    const res4 = m.arm(.{ 1, ref_rest("tail") });
    const res5 = m.arm(.{ 0, ref_rest("middle"), 140 });

    try std.testing.expectEqual(140, res.?.num);
    try std.testing.expectEqualSlices(u8, &.{ 0, 9 }, res2.?.first2);
    try std.testing.expectEqual(0, res3.?.head);
    try std.testing.expectEqualSlices(u8, &.{ 9, 100, 140 }, res3.?.tail);
    try std.testing.expectEqual(null, res4);
    try std.testing.expectEqualSlices(u8, &.{ 9, 100 }, res5.?.middle);
}

test "match: single pointers" {
    const House = struct {
        address: ?*const struct {
            number: u32,
            street_num: *const u64,
            duplex_is_first: ?bool,
        },
        quality: *const u32,
        proof: u32,
    };
    const house: House = .{
        .address = &.{
            .number = 233,
            .street_num = &3,
            .duplex_is_first = true,
        },
        .quality = &0,
        .proof = 1,
    };
    const m = comptime match(&house);

    const res = m.arm(.{ .address = __, .quality = 0, .proof = bind("proof") });
    const res2 = m.arm(.{ .address = __, .quality = 1, .proof = bind("proof") });
    const res3 = m.arm(.{ .address = __, .quality = __, .proof = bind("proof") });
    try std.testing.expectEqual(1, res.?.proof);
    try std.testing.expectEqual(null, res2);
    try std.testing.expectEqual(1, res3.?.proof);

    const res4 = m.arm(.{ .address = .{ .number = 233, .street_num = __, .duplex_is_first = true }, .quality = __, .proof = bind("proof") });
    const res5 = m.arm(.{ .address = .{ .number = 999, .street_num = __, .duplex_is_first = false }, .quality = __, .proof = bind("proof") });
    try std.testing.expectEqual(1, res4.?.proof);
    try std.testing.expectEqual(null, res5);

    const res6 = m.arm(.{ .address = .{ .number = __, .street_num = 3, .duplex_is_first = __ }, .quality = __, .proof = bind("proof") });
    const res7 = m.arm(.{ .address = .{ .number = __, .street_num = 23339, .duplex_is_first = __ }, .quality = __, .proof = bind("proof") });
    try std.testing.expectEqual(1, res6.?.proof);
    try std.testing.expectEqual(null, res7);
}

test "match: slices" {
    const list: []const u8 = &.{ 0, 9, 100, 140 };
    const m = comptime match(&list);
    const res = m.arm(.{ 0, 9, 100, bind("num") });
    const res2 = m.arm(.{ ref_rest("first2"), 100, 140 });
    const res3 = m.arm(.{ bind("head"), ref_rest("tail") });
    const res4 = m.arm(.{ 1, ref_rest("tail") });
    const res5 = m.arm(.{ 0, ref_rest("middle"), 140 });
    const res6 = m.arm(.{ 0, 9, bind("num") });
    const res7 = m.arm(.{ 0, 9, 100, 140, bind("num") });

    try std.testing.expectEqual(140, res.?.num);
    try std.testing.expectEqualSlices(u8, &.{ 0, 9 }, res2.?.first2);
    try std.testing.expectEqual(0, res3.?.head);
    try std.testing.expectEqualSlices(u8, &.{ 9, 100, 140 }, res3.?.tail);
    try std.testing.expectEqual(null, res4);
    try std.testing.expectEqualSlices(u8, &.{ 9, 100 }, res5.?.middle);
    try std.testing.expectEqual(null, res6);
    try std.testing.expectEqual(null, res7);
}
