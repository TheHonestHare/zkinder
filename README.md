A library that implements pattern matching in fully userland zig

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
  - arrays
    - can even match on a subarray using `ref_rest` (see test "match: arrays")
  - single item pointers (patterns match on the child type)
  - slices
    - support same features as arrays, plus different length patterns
- extracting values out via `bind`
- matching aginst anything via `__`
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
- more helper match predicates such as `partial`, `bindif`, `ref`, `range`
- safety check for ensuring a match only ever matches on one branch
  - a new `matchMultiple` will basically act as how match is right now, as basically allowing `if let` from Rust
