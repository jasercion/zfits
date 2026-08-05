# zfits

zfits is a small, dependency-free FITS reader and editor for Zig. It reads
and writes FITS header cards and unpadded HDU data without requiring a third-
party library.

The package currently targets Zig `0.17.0` or newer.

## Features

- Parse the primary HDU or any indexed extension in a complete FITS file.
- Read and update header keywords while retaining cards the library does not
  interpret.
- Read and replace data payloads.
- Write an HDU to a writer or standalone file.
- Replace one HDU in an existing FITS file while preserving the other HDUs.
- Handle FITS 2880-byte header and data-block padding, including `PCOUNT` and
  `GCOUNT` data sizing.

## Add the package

Use the package as a module dependency in `build.zig`:

```zig
const zfits = b.dependency("zfits", .{}).module("zfits");
exe.root_module.addImport("zfits", zfits);
```

Then import it in Zig:

```zig
const zfits = @import("zfits");
```

## Read and edit the primary HDU

```zig
const std = @import("std");
const zfits = @import("zfits");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var fits = try zfits.Fits.load(allocator, "image.fits");
    defer fits.deinit();

    const object = fits.getString("OBJECT") orelse "unknown";
    std.debug.print("object: {s}\n", .{object});

    try fits.set("OBJECT", "'edited'", null);
    try fits.save("edited.fits");
}
```

Values are stored as raw FITS value-field text. For example, string values
normally include their FITS quotes (`"'edited'"`), while numeric values can be
set with `setInt` or `setFloat`.

## Read and replace an extension

HDU indexes are zero-based: index `0` is the primary HDU, index `1` is the
first extension, and so on.

```zig
var extension = try zfits.Fits.loadExtension(allocator, "cube.fits", 2);
defer extension.deinit();

const width = try extension.getInt(usize, "NAXIS1");
try extension.set("EXTNAME", "'UPDATED'", null);
try extension.saveExtension("cube.fits", 2);
```

`saveExtension` reads the original file before replacing the selected HDU, so
all other HDUs remain in place. The replacement may have a different header
or data length. `writeExtension` is an alias for `saveExtension`.

## Construct an HDU

```zig
var fits = zfits.Fits.init(allocator);
defer fits.deinit();

try fits.set("SIMPLE", "T", null);
try fits.setInt("BITPIX", 8, null);
try fits.setInt("NAXIS", 1, null);
try fits.setInt("NAXIS1", 3, "pixels");
try fits.setData(&[_]u8{ 1, 2, 3 });
try fits.save("new.fits");
```

The header dimensions must describe the exact unpadded length passed to
`setData`. FITS padding is added automatically when writing.

## API reference

See [docs/API.md](docs/API.md) for the public types, methods, ownership rules,
and errors.

## Test

```sh
zig build test
```
