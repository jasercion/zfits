# zfits API reference

The package root is `@import("zfits")`. The public API is defined in
`src/main.zig` and re-exported by `src/root.zig`.

## `Fits`

`Fits` represents one FITS Header/Data Unit (HDU), not an entire collection of
HDUs. Use an extension index when selecting an HDU from a multi-extension
file. The index is zero-based; the primary HDU is index `0`.

### Lifecycle and file access

```zig
pub fn init(allocator: std.mem.Allocator) Fits
pub fn deinit(self: *Fits) void
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Fits
pub fn parseExtension(allocator: std.mem.Allocator, bytes: []const u8, index: usize) !Fits
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Fits
pub fn loadExtension(allocator: std.mem.Allocator, path: []const u8, index: usize) !Fits
```

- `init` creates an empty HDU whose cards and data use `allocator`.
- `deinit` must be called exactly once for every successfully initialized or
  parsed `Fits` value.
- `parse` reads the primary HDU from a complete, 2880-byte-aligned FITS
  buffer. Additional HDUs may follow it.
- `parseExtension` scans the complete buffer and returns the HDU at `index`.
- `load` and `loadExtension` are the file-path equivalents of `parse` and
  `parseExtension`.

### Writing

```zig
pub fn write(self: *const Fits, writer: anytype) !void
pub fn save(self: *const Fits, path: []const u8) !void
pub fn saveExtension(self: *const Fits, path: []const u8, index: usize) !void
pub fn writeExtension(self: *const Fits, path: []const u8, index: usize) !void
```

`write` writes one complete HDU to any object exposing `writeAll`. `save`
creates or truncates a path and writes one standalone HDU. `saveExtension`
reads the existing file, replaces only the selected HDU, and writes the full
file back. The other HDUs are retained. `writeExtension` is an alias for
`saveExtension`.

Writing validates that the data length agrees with `BITPIX`, `NAXISn`,
`PCOUNT`, and `GCOUNT`. Header and data padding is generated automatically;
`dataBytes` and `setData` use unpadded payloads.

### Header cards

```zig
pub fn getCard(self: *const Fits, keyword: []const u8) ?*const Card
pub fn getString(self: *const Fits, keyword: []const u8) ?[]const u8
pub fn getInt(self: *const Fits, comptime T: type, keyword: []const u8) !?T
pub fn getFloat(self: *const Fits, comptime T: type, keyword: []const u8) !?T
pub fn set(self: *Fits, keyword: []const u8, value: []const u8, comment: ?[]const u8) !void
pub fn setInt(self: *Fits, keyword: []const u8, value: anytype, comment: ?[]const u8) !void
pub fn setFloat(self: *Fits, keyword: []const u8, value: anytype, comment: ?[]const u8) !void
pub fn remove(self: *Fits, keyword: []const u8) bool
```

Keyword matching is ASCII case-insensitive. `getCard` returns the first
matching card. `getString` returns its raw value field; string quoting and
other FITS formatting are not decoded. `getInt` and `getFloat` trim surrounding
spaces and parse the raw value.

`set` inserts or replaces the first matching keyword. It copies the keyword,
value, and optional comment, so the input slices may be temporary. Keyword
names must be 1–8 printable characters and may not contain `=`. `setInt` and
`setFloat` format their values before calling `set`. `remove` frees and removes
the first matching card.

### Data

```zig
pub fn setData(self: *Fits, bytes: []const u8) !void
pub fn dataBytes(self: *const Fits) []const u8
```

`setData` copies an unpadded payload. `dataBytes` returns the current payload;
the slice remains valid until the next mutating operation that reallocates or
replaces the data, or until `deinit`.

## `Card`

```zig
pub const Card = struct {
    keyword: []u8,
    value: ?[]u8,
    comment: ?[]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Card) void
};
```

Cards retain the logical keyword, raw value field, and optional comment. Cards
owned by a `Fits` are managed by that `Fits`; callers normally only need to
call `Fits.deinit`.

## Errors

Operations return errors from the following set where applicable:

| Error | Meaning |
| --- | --- |
| `InvalidFits` | The file, HDU structure, alignment, or payload is invalid. |
| `InvalidCard` | A card cannot be parsed or serialized. |
| `InvalidKeyword` | A keyword is empty, too long, non-printable, or contains `=`. |
| `InvalidValue` | A header value cannot be parsed as the requested number. |
| `MissingRequiredKeyword` | A required structural keyword is absent. |
| `UnsupportedHeader` | Header values such as `BITPIX` are unsupported. |
| `DataSizeOverflow` | A calculated FITS data length overflows `usize`. |

File operations can additionally return errors from `std.fs` and the supplied
allocator or writer.
