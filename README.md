A library that implements pattern matching in fully userland zig. Tested on zig version 0.14.0-dev.1391+e084c46ed but should probably work on master

## Code example
```zig
const ki = @import("zkinder");
const bind = ki.bind;
const __ = ki.__;

const thing: struct {
    age: u32,
    birth: u64,
    pos: struct { x: u8, y: u8 } 
} = .{.age = 3, .birth = 2, .pos = .{.x = 90, .y = 20}};

const m = ki.match(&thing);
// bind puts the value of the variable in the result
const res = m.arm(.{.age = 3, .birth = bind("hello"), .pos = .{.x = bind("x"), .y = 20}});
try std.testing.expectEqual(2, res.?.hello);
try std.testing.expectEqual(90, res.?.x);

const res2 = m.arm(.{.age = 3, .birth = bind("hello"), .pos = bind("pos")});
try std.testing.expectEqual(2, res2.?.hello);
try std.testing.expectEqual(90, res2.?.pos.x);
try std.testing.expectEqual(20, res2.?.pos.y);

// this arm doesn't match because age = 2, will return null
const res3 = m.arm(.{.age = 2, .birth = bind("hello"), .pos = bind("pos")});
try std.testing.expectEqual(null, res3);

// __ will match on anything
const res4 = m.arm(.{.age = __, .birth = __, .pos = .{.x = __, .y = bind("y")}});
try std.testing.expectEqual(20, res4.?.y);
```
## Current features:
- arbitrary nested patterns
  - structs
  - union(enum) (TODO: more testing)
  - enums (TODO: more testing)
  - ints, floats, bools (TODO: more testing)
  - optionals (TODO: more testing)
    - match on double optionals using `nonnull`
  - arrays
    - can even match on a subarray using `ref_rest` (see "custom array matchers")
  - single item pointers (patterns match on the child type)
  - slices
    - support same features as arrays, plus different length patterns
- `matching` for no exhaustive checking, single arm
- extracting values out via `bind`
- matching aginst anything via `__`
- matching on integer ranges via `range`
- extracting values out only if it matches a predicate with `bind_if`
- support for creating your own match predicates
  - both `bind` and `__` use no special casing, you could implement yourself
  - any custom matcher must be of type `fn (comptime type) CustomMatcher`
  - the impl will take in this type, pass in the type it needs to bind to and collect all the needed captures
  - TODO: make like 10x more ergonomic
## Planned features:
- matching on vectors, others maybe?
- optimize this so its not just willy nilly checking basically
- exhaustive patterns (hardmode)
- unreachable pattern errors (if I feel like it)
- more helper match predicates such as `partial`, `ref`,
- safety check for ensuring a match only ever matches on one branch

## Custom matchers:
A custom matcher is any function of the form `fn (comptime type) Matcher`, where the input is the type it is being matched against. `bind(<name>)` and `__` are both custom matchers implementable you could just as easily implement

For example, in the pattern,

`.{.age = 2, .birth = __, .pos = __}`

`__` is actually a function which will take the types of `thing.birth` and `thing.pos` respectively. 

`Matcher` is defined as such:
```zig
pub const Matcher = struct {
    captures: type,
    tryBind: fn (self: Matcher, val_ptr: anytype, out_ptr: anytype) bool,
};
```
`captures` is a struct type where each field is an output the matcher produces. This is needed for features like `bind`. All fields are combined, using comptime, into one giant struct that is returned from the arm.

`tryBind` is where all the magic happens.
- `self` allows you to access the `captures` field
- `val_ptr` is a pointer to the field being matched against. The fields type will be the same type that was passed into the custom matcher.
- `out_ptr` lets you write to the `out` of the arm, if you had any captures. For example, `out_ptr.hello = 2` would write 2 to the `hello` field of the output. You can only write to fields that were already declared as captures
- return `true` if the value in `val_ptr` matches whatever criteria you want, or `false` if not

## Custom array matchers:
These are similar to custom matchers, but they only work in array or slice patterns. `ref_rest(<name>)` is a custom array matcher. Instead of having to have a pattern for the entire length of the array, you can match over part of it.

You can only have custom array matcher per array/slice pattern

```test "match: arrays" {
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
```

To make your own, you need a thing of type `fn (comptime type, comptime ?usize) SubSliceMatcher`. The first parameter is the child type of the array or slice, and the second is the length of the array, or null if it is a slice
SubSliceMatcher has a `captures` field similar to a custom matcher, as well as a `tryBind` fn. The only difference is that instead of `val_ptr`, it will take `subslice`,

If the matched against type is an array, `subslice` will be a pointer to the subarray that is not matched against in the rest of the pattern
If the matched againt type is a slice, `subslice` will be the subslice that is not matched against in the rest of the pattern
