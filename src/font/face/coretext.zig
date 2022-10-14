const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");
const Atlas = @import("../../Atlas.zig");

pub const Face = struct {
    /// Our font face
    font: *macos.text.Font,

    /// Harfbuzz font corresponding to this face.
    hb_font: harfbuzz.Font,

    /// The presentation for this font.
    presentation: font.Presentation,

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.face.Metrics,

    /// Initialize a CoreText-based font from a TTF/TTC in memory.
    pub fn init(lib: font.Library, source: [:0]const u8, size: font.face.DesiredSize) !Face {
        _ = lib;

        const data = try macos.foundation.Data.createWithBytesNoCopy(source);
        defer data.release();

        const arr = macos.text.createFontDescriptorsFromData(data) orelse
            return error.FontInitFailure;
        defer arr.release();

        const desc = arr.getValueAtIndex(macos.text.FontDescriptor, 0);
        const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
        defer ct_font.release();

        return try initFontCopy(ct_font, size);
    }

    /// Initialize a CoreText-based face from another initialized font face
    /// but with a new size. This is often how CoreText fonts are initialized
    /// because the font is loaded at a default size during discovery, and then
    /// adjusted to the final size for final load.
    pub fn initFontCopy(base: *macos.text.Font, size: font.face.DesiredSize) !Face {
        // Create a copy
        const ct_font = try base.copyWithAttributes(@intToFloat(f32, size.points), null);
        errdefer ct_font.release();

        var hb_font = try harfbuzz.coretext.createFont(ct_font);
        errdefer hb_font.destroy();

        const traits = ct_font.getSymbolicTraits();

        return Face{
            .font = ct_font,
            .hb_font = hb_font,
            .presentation = if (traits.color_glyphs) .emoji else .text,
            .metrics = try calcMetrics(ct_font),
        };
    }

    pub fn deinit(self: *Face) void {
        self.font.release();
        self.hb_font.destroy();
        self.* = undefined;
    }

    /// Returns the glyph index for the given Unicode code point. If this
    /// face doesn't support this glyph, null is returned.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        // Turn UTF-32 into UTF-16 for CT API
        var unichars: [2]u16 = undefined;
        const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
        const len: usize = if (pair) 2 else 1;

        // Get our glyphs
        var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
        if (!self.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]))
            return null;

        // We can have pairs due to chars like emoji but we expect all of them
        // to decode down into exactly one glyph ID.
        if (pair) assert(glyphs[1] == 0);

        return @intCast(u32, glyphs[0]);
    }

    /// Render a glyph using the glyph index. The rendered glyph is stored in the
    /// given texture atlas.
    pub fn renderGlyph(self: Face, alloc: Allocator, atlas: *Atlas, glyph_index: u32) !font.Glyph {
        var glyphs = [_]macos.graphics.Glyph{@intCast(macos.graphics.Glyph, glyph_index)};

        // Get the bounding rect for this glyph to determine the width/height
        // of the bitmap. We use the rounded up width/height of the bounding rect.
        var bounding: [1]macos.graphics.Rect = undefined;
        _ = self.font.getBoundingRectForGlyphs(.horizontal, &glyphs, &bounding);
        const glyph_width = @floatToInt(u32, @ceil(bounding[0].size.width));
        const glyph_height = @floatToInt(u32, @ceil(bounding[0].size.height));
        _ = glyph_height;
        const width = @floatToInt(u32, self.metrics.cell_width);
        const height = @floatToInt(u32, self.metrics.cell_height);

        // This bitmap is blank. I've seen it happen in a font, I don't know why.
        // If it is empty, we just return a valid glyph struct that does nothing.
        if (glyph_width == 0) return font.Glyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .atlas_x = 0,
            .atlas_y = 0,
            .advance_x = 0,
        };

        //std.log.warn("bound={}", .{bounding[0]});

        // Get the advance that we need for the glyph
        var advances: [1]macos.graphics.Size = undefined;
        _ = self.font.getAdvancesForGlyphs(.horizontal, &glyphs, &advances);

        // Our buffer for rendering
        // TODO(perf): cache this buffer
        // TODO(mitchellh): color is going to require a depth here
        var buf = try alloc.alloc(u8, width * height);
        defer alloc.free(buf);

        const space = try macos.graphics.ColorSpace.createDeviceGray();
        defer space.release();

        const ctx = try macos.graphics.BitmapContext.create(
            buf,
            width,
            height,
            8,
            width,
            space,
            @enumToInt(macos.graphics.BitmapInfo.alpha_mask) &
                @enumToInt(macos.graphics.ImageAlphaInfo.none),
        );
        defer ctx.release();

        ctx.setAllowsAntialiasing(false);
        ctx.setShouldAntialias(false);
        ctx.setShouldSmoothFonts(false);
        ctx.setGrayFillColor(1, 1);
        ctx.setGrayStrokeColor(1, 1);
        ctx.setTextDrawingMode(.fill_stroke);
        ctx.setTextMatrix(macos.graphics.AffineTransform.identity());
        ctx.setTextPosition(0, @intToFloat(f32, height) - self.metrics.cell_baseline);

        var pos = [_]macos.graphics.Point{.{ .x = 0, .y = 0 }};
        self.font.drawGlyphs(&glyphs, &pos, ctx);

        const region = try atlas.reserve(alloc, width, height);
        atlas.set(region, buf);

        return font.Glyph{
            .width = width,
            .height = height,
            .offset_x = 0,

            // Offset is full cell height because for CoreText we render
            // an entire cell.
            .offset_y = @floatToInt(i32, self.metrics.cell_height),

            .atlas_x = region.x,
            .atlas_y = region.y,
            .advance_x = @floatCast(f32, advances[0].width),
        };
    }

    fn calcMetrics(ct_font: *macos.text.Font) !font.face.Metrics {
        // Cell width is calculated by calculating the widest width of the
        // visible ASCII characters. Usually 'M' is widest but we just take
        // whatever is widest.
        const cell_width: f32 = cell_width: {
            // Build a comptime array of all the ASCII chars
            const unichars = comptime unichars: {
                const len = 127 - 32;
                var result: [len]u16 = undefined;
                var i: u16 = 32;
                while (i < 127) : (i += 1) {
                    result[i - 32] = i;
                }

                break :unichars result;
            };

            // Get our glyph IDs for the ASCII chars
            var glyphs: [unichars.len]macos.graphics.Glyph = undefined;
            _ = ct_font.getGlyphsForCharacters(&unichars, &glyphs);

            // Get all our advances
            var advances: [unichars.len]macos.graphics.Size = undefined;
            _ = ct_font.getAdvancesForGlyphs(.horizontal, &glyphs, &advances);

            // Find the maximum advance
            var max: f64 = 0;
            var i: usize = 0;
            while (i < advances.len) : (i += 1) {
                max = @maximum(advances[i].width, max);
            }

            break :cell_width @floatCast(f32, max);
        };

        // Calculate the cell height by using CoreText's layout engine
        // to tell us after laying out some text. This is inspired by Kitty's
        // approach. Previously we were using descent/ascent math and it wasn't
        // quite the same with CoreText and I never figured out why.
        const layout_metrics: struct {
            height: f32,
            ascent: f32,
        } = metrics: {
            const unit = "AQWMH_gyl " ** 100;

            // Setup our string we'll layout. We just stylize a string of
            // ASCII characters to setup the letters.
            const string = try macos.foundation.MutableAttributedString.create(unit.len);
            defer string.release();
            const rep = try macos.foundation.String.createWithBytes(unit, .utf8, false);
            defer rep.release();
            string.replaceString(macos.foundation.Range.init(0, 0), rep);
            string.setAttribute(
                macos.foundation.Range.init(0, unit.len),
                macos.text.StringAttribute.font,
                ct_font,
            );

            // Create our framesetter with our string. This is used to
            // emit "frames" for the layout.
            const fs = try macos.text.Framesetter.createWithAttributedString(
                @ptrCast(*macos.foundation.AttributedString, string),
            );
            defer fs.release();

            // Create a rectangle to fit all of this and create a frame of it.
            const path = try macos.graphics.MutablePath.create();
            path.addRect(null, macos.graphics.Rect.init(10, 10, 200, 200));
            defer path.release();
            const frame = try fs.createFrame(
                macos.foundation.Range.init(0, 0),
                @ptrCast(*macos.graphics.Path, path),
                null,
            );
            defer frame.release();

            // Use our text layout from earlier to measure the difference
            // between the lines.
            var points: [2]macos.graphics.Point = undefined;
            frame.getLineOrigins(macos.foundation.Range.init(0, 1), points[0..]);
            frame.getLineOrigins(macos.foundation.Range.init(1, 1), points[1..]);

            const lines = frame.getLines();
            const line = lines.getValueAtIndex(macos.text.Line, 0);

            // NOTE(mitchellh): For some reason, CTLineGetBoundsWithOptions
            // returns garbage and I can't figure out why... so we use the
            // raw ascender.

            var ascent: f64 = 0;
            var descent: f64 = 0;
            var leading: f64 = 0;
            _ = line.getTypographicBounds(&ascent, &descent, &leading);
            //std.log.warn("ascent={} descent={} leading={}", .{ ascent, descent, leading });

            break :metrics .{
                .height = @floatCast(f32, points[0].y - points[1].y),
                .ascent = @floatCast(f32, ascent),
            };
        };

        // All of these metrics are based on our layout above.
        const cell_height = layout_metrics.height;
        const cell_baseline = layout_metrics.ascent;
        const underline_position = @ceil(layout_metrics.ascent -
            @floatCast(f32, ct_font.getUnderlinePosition()));
        const underline_thickness = @ceil(@floatCast(f32, ct_font.getUnderlineThickness()));
        const strikethrough_position = cell_baseline * 0.6;
        const strikethrough_thickness = underline_thickness;

        // std.log.warn("width={d}, height={d} baseline={d} underline_pos={d} underline_thickness={d}", .{
        //     cell_width,
        //     cell_height,
        //     cell_baseline,
        //     underline_position,
        //     underline_thickness,
        // });
        return font.face.Metrics{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .cell_baseline = cell_baseline,
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
            .strikethrough_position = strikethrough_position,
            .strikethrough_thickness = strikethrough_thickness,
        };
    }
};

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas = try Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    const name = try macos.foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .points = 12 });
    defer face.deinit();

    try testing.expectEqual(font.Presentation.text, face.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?);
    }
}

test "emoji" {
    const testing = std.testing;

    const name = try macos.foundation.String.createWithBytes("Apple Color Emoji", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .points = 18 });
    defer face.deinit();

    // Presentation
    try testing.expectEqual(font.Presentation.emoji, face.presentation);

    // Glyph index check
    try testing.expect(face.glyphIndex('🥸') != null);
}

test "in-memory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("../test.zig").fontRegular;

    var atlas = try Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    var lib = try font.Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .points = 12 });
    defer face.deinit();

    try testing.expectEqual(font.Presentation.text, face.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?);
    }
}