const std = @import("std");

pub fn match(thing: anytype) Matcher(PointerChildOfSingle(@TypeOf(thing))) {
    return .{
        .thing_ptr = thing,
    };
}

pub fn PointerChildOfSingle(T: type) type {
    return switch (@typeInfo(T)) {
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => ptr_info.child,
            .Many, .Slice, .C => @compileError("Thing passed into match must be single item pointer"),
        },
        else => @compileError("Thing passed into match must be single item pointer"),
    };
}

pub fn Matcher(T_: type) type {
    return struct {
        pub const T = T_;
        thing_ptr: *const T,

        // TODO: should pattern have to be comptime known
        pub fn arm(self: @This(), pattern: anytype) ?MatchOut(T, pattern) {
            var out: MatchOut(T, pattern) = undefined;
            if(!armInner(self.thing_ptr, pattern, &out)) return null;
            return out;
        }

        fn armInner(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
            const ValType = @typeInfo(@TypeOf(val_ptr)).Pointer.child;
            if(@TypeOf(pattern) == CustomMatcherType) {
                const capture_group = pattern(ValType);
                return capture_group.iface_impl.tryBind(capture_group, val_ptr, out_ptr);
            }
            return switch(@typeInfo(ValType)) {
                .Struct => tryBindStruct(val_ptr, pattern, out_ptr),
                .Union => tryBindUnion(val_ptr, pattern, out_ptr),
                .Optional => tryBindOptional(val_ptr, pattern, out_ptr),
                // TODO: add additional features for matching on scalars
                .Int, .ComptimeInt, .Bool, .Float, .ComptimeFloat, .Enum => pattern == val_ptr.*,
                // TODO: implement other types
                else => @compileError("TODO: implement other types"),
            };
        }
        fn tryBindStruct(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
            const ValType = @typeInfo(@TypeOf(val_ptr)).Pointer.child;
            inline for(@typeInfo(ValType).Struct.fields) |field| {
                if(!armInner(&@field(val_ptr, field.name), @field(pattern, field.name), out_ptr)) return false;
            }
            return true;
        }
        fn tryBindUnion(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
            const TagEnum = @typeInfo(@TypeOf(val_ptr.*)).Union.tag_type orelse @compileError("matching on a union requires a tag type");
            const variant_name = @typeInfo(@TypeOf(pattern)).Struct.fields[0].name;
            // TODO: this might be inefficient
            if(std.meta.activeTag(val_ptr.*) != @field(TagEnum, variant_name)) return false;
            return armInner(&@field(val_ptr, variant_name), @field(pattern, variant_name), out_ptr);
        }
        fn tryBindOptional(val_ptr: anytype, pattern: anytype, out_ptr: anytype) bool {
            if(@TypeOf(pattern) == @TypeOf(null)) return val_ptr.* == null;

            if(val_ptr.* == null) return @TypeOf(pattern) == @TypeOf(null);

            const NewValPtrType = comptime blk: {
                const ChildValType = @typeInfo(@TypeOf(val_ptr.*)).Optional.child;
                var typeinfo = @typeInfo(@TypeOf(val_ptr));
                typeinfo.Pointer.child = ChildValType;
                break :blk @Type(typeinfo);
            };
            return armInner(@as(NewValPtrType, @ptrCast(val_ptr)), pattern, out_ptr);
        }
    };
}

pub fn MatchOut(T: type, pattern: anytype) type {
    if (@TypeOf(pattern) == CustomMatcherType) return pattern(T).captures;
    return switch (@typeInfo(T)) {
        .Struct => MatchOutStruct(T, pattern),
        .Union => MatchOutUnion(T, pattern),
        .Optional => MatchOutOptional(T, pattern),
        .Int, .ComptimeInt, .Bool, .Float, .ComptimeFloat, .Enum => struct {},
        // TODO: implement other types
        else => { @compileLog(T, pattern); @compileError("TODO: implement other types"); },
    };
}

/// assumes T is a struct type
pub fn MatchOutStruct(T: type, pattern: anytype) type {
    validateStructPattern(pattern);
    const pattern_info = @typeInfo(@TypeOf(pattern)).Struct;
    if(@typeInfo(T).Struct.fields.len != pattern_info.fields.len) @compileError(std.fmt.comptimePrint(
        \\ Found {d} fields in the pattern. Expected {d} in the match type. Use the __ function to always match
        ,.{pattern_info.fields.len, @typeInfo(T).Struct.fields.len}));
    var out_types: [pattern_info.fields.len]type = undefined;
    for(&out_types, pattern_info.fields) |*out, field_info| {
        if (!@hasField(T, field_info.name)) @compileError(std.fmt.comptimePrint("Field name \"{s}\" in pattern does not exist in match type", .{field_info.name}));
        out.* = MatchOut(@TypeOf(@field(@as(T, undefined), field_info.name)), @field(pattern, field_info.name));
    }
    return FlattenStructs(&out_types);
}

pub fn MatchOutUnion(T: type, pattern: anytype) type {
    validateStructPattern(pattern);
    const pattern_info = @typeInfo(@TypeOf(pattern)).Struct;
    if(pattern_info.fields.len > 1) @compileError("Pattern contains multiple variants of the same union for matching, use oneof for this purpose");
    const variant_name = pattern_info.fields[0].name;
    return MatchOut(@TypeOf(@field(@as(T, undefined), variant_name)), @field(pattern, variant_name));
}

pub fn MatchOutOptional(T: type, pattern: anytype) type {
    if(@TypeOf(pattern) == @TypeOf(null)) return struct {};

    return MatchOut(@typeInfo(T).Optional.child, pattern);
    
}

/// asserts that a pattern is of struct type and not a tuple
pub fn validateStructPattern(pattern: anytype) void {
    const pattern_info = @typeInfo(@TypeOf(pattern));
    if (std.meta.activeTag(pattern_info) != .Struct) @compileError(std.fmt.comptimePrint("Expected a struct type for pattern, found: {}", .{@TypeOf(pattern)}));
    if (pattern_info.Struct.is_tuple) @compileError("Found tuple type when pattern matching against struct, must use a struct with the field names");
}

pub const CustomMatcherType = fn (comptime type) CustomMatcher;

pub const CustomMatcher = struct {
    /// struct type of all the captures
    captures: type,
    ctx: ?struct {
        /// T is the child type of ptr
        T: type,
        /// pointer points to a T
        ptr: *const anyopaque,
    } = null,

    iface_impl: struct {
        // TODO: do we want val_ptr or just val
        tryBind: fn (self: CustomMatcher, val_ptr: anytype, out_ptr: anytype) bool,
    },
};

/// binds a fields value to the name, to be accessed in the out of the arm
pub fn bind(name: [:0]const u8) CustomMatcherType {
    const tryBind = struct {
        pub fn f(self: CustomMatcher, val_ptr: anytype, out_ptr: anytype) bool {
            const fields = @typeInfo(self.captures).Struct.fields;
            @field(out_ptr, fields[0].name) = val_ptr.*;
            return true;
        }
    }.f;
    return struct {
        /// TODO: maybe have to pass in alignment?
        pub fn f(comptime T: type) CustomMatcher {
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
                .iface_impl = .{
                    .tryBind = tryBind,
                }
            };
        }
    }.f;
}

/// matches everything successfully
pub fn __(_: type) CustomMatcher {
    return .{
        .captures = struct {},
        .iface_impl = .{
            .tryBind = struct {
                pub fn f(_: CustomMatcher, _: anytype, _: anytype) bool {
                    return true;
                }
            }.f
        }
    };
}

/// flattens an array of struct types into 1 struct type
pub fn FlattenStructs(types: []type) type {
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

/// basically std.meta.FieldEnum
fn StructFieldEnum(fields_info: []const std.builtin.Type.StructField) type {
    var enum_fields: [fields_info.len]std.builtin.Type.EnumField = undefined;
    for (fields_info, &enum_fields, 0..) |field, *enum_field, val| {
        enum_field.* = .{ .name = field.name, .value = val };
    }
    return @Type(.{ .Enum = .{
        .tag_type = if (fields_info.len == 0) u0 else std.math.IntFittingRange(0, fields_info.len - 1),
        .is_exhaustive = true,
        .fields = &enum_fields,
        .decls = &.{},
    } });
}

test MatchOut {
    const thing: struct { age: u32, birth: u64 } = undefined;
    const out = @typeInfo(MatchOut(@TypeOf(thing), .{ .age = bind("age_years"), .birth = bind("birthday_utc") }));
    const exp_out = @typeInfo(struct { age_years: u32, birthday_utc: u64 });

    // for some reason this errors if called without comptime
    try comptime std.testing.expectEqualDeep(exp_out, out);
}

test match {
    const thing: struct { age: u32, birth: u64, pos: struct { x: u8, y: u8 } } = .{.age = 3, .birth = 2, .pos = .{.x = 90, .y = 20}};
    const m = comptime match(&thing);
    const res = m.arm(.{.age = 3, .birth = bind("hello"), .pos = .{.x = bind("__x__"), .y = 20}});
    try std.testing.expectEqual(2, res.?.hello);
    try std.testing.expectEqual(90, res.?.__x__);

    const res2 = m.arm(.{.age = 3, .birth = bind("hello"), .pos = bind("pos")});
    try std.testing.expectEqual(2, res2.?.hello);
    try std.testing.expectEqual(90, res2.?.pos.x);
    try std.testing.expectEqual(20, res2.?.pos.y);

    const res3 = m.arm(.{.age = __, .birth = __, .pos = .{.x = __, .y = bind("y")}});
    try std.testing.expectEqual(20, res3.?.y);
}
test "match: unions" {
    const Thing = struct {
        val: u32,
        impl: union(enum) {
            foo: u64,
            bar: f64
        }
    };
    {
        const thing: Thing = .{.val = 1000, .impl = .{.foo = 90}};
        const m = comptime match(&thing);

        const res = m.arm(.{.val = 1000, .impl = .{.bar = __}});
        const res2 = m.arm(.{.val = __, .impl = .{.foo = 91}});
        const res3 = m.arm(.{.val = __, .impl = .{.foo = bind("hello")}});

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
        const thing: House = .{.address = null, .quality = null, .proof = 1};
        const m = comptime match(&thing);
        const res = m.arm(.{.address = null, .quality = null, .proof = bind("proof")});
        const res2 = m.arm(.{.address = .{.number = __, .street_num = __, .duplex_is_first = __}, .quality = null, .proof = 1});
        const res3 = m.arm(.{.address = __, .quality = null, .proof = bind("proof")});

        try std.testing.expectEqual(1, res.?.proof);
        try std.testing.expectEqual(null, res2);
        try std.testing.expectEqual(1, res3.?.proof);
    }
    {
        const thing: House = .{.address = .{.number = 1235, .street_num = 2, .duplex_is_first = true }, .quality = 2, .proof = 1};
        const m = comptime match(&thing);
        const res = m.arm(.{.address = null, .quality = null, .proof = 1});
        const res2 = m.arm(.{.address = .{.number = __, .street_num = __, .duplex_is_first = __}, .quality = null, .proof = 1});
        const res3 = m.arm(.{.address = __, .quality = null, .proof = 1});

        try std.testing.expectEqual(null, res);
        try std.testing.expectEqual(null, res2);
        try std.testing.expectEqualDeep(null, res3);
    }
}
