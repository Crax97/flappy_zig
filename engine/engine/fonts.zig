const std = @import("std");
const core = @import("core");
const renderer = @import("renderer");
const sdl_util = renderer.sdl_util;

const math = @import("math");

const GenArena = core.GenArena;
const TextureHandle = renderer.TextureHandle;

const Allocator = std.mem.Allocator;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Rect2 = math.Rect2;

const ft = @import("freetype.zig");

pub const FontManagerError = error{} || Allocator.Error;

const Glyph = struct {
    texture: ?TextureHandle,
    width: f32,
    height: f32,
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
    metrics: ft.FT_Glyph_Metrics,
};
const Glyphs = std.AutoArrayHashMap(u8, Glyph);
pub const RenderTextInfo = struct {
    font: FontHandle,
    text: []const u8 = "",
    offset: Vec2 = Vec2.ZERO,
    scale: f32 = 1.0,
};
pub const Font = struct {
    face: ft.FT_Face,
    glyphs: Glyphs,
    sampler_settings: renderer.SamplerConfig = renderer.SamplerConfig.LINEAR,
};
pub const FontHandle = core.Index(Font);
pub const FontDescription = struct {
    data: []const u8,
    size: u32,
    sampler_settings: renderer.SamplerConfig = renderer.SamplerConfig.LINEAR,
};

pub const FontManager = struct {
    library: ft.FT_Library,
    fonts: GenArena(Font),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !FontManager {
        var library: ft.FT_Library = undefined;
        ft_check(ft.FT_Init_FreeType(&library), "Failed to init library");

        return .{
            .library = library,
            .allocator = allocator,
            .fonts = try GenArena(Font).init(allocator),
        };
    }

    pub fn deinit(this: *FontManager, renderer_inst: *renderer.Renderer) void {
        var itr = this.fonts.iterator();
        while (itr.next()) |font| {
            for (font.glyphs.values()) |glyph| {
                if (glyph.texture) |tex| {
                    renderer_inst.free_texture(tex);
                }
            }
            font.glyphs.deinit();
            ft_check(ft.FT_Done_Face(font.face), "Failed to close font face");
        }

        this.fonts.deinit();
        ft_check(ft.FT_Done_FreeType(this.library), "Failed to close library");
    }

    pub fn load(this: *FontManager, description: FontDescription) FontManagerError!FontHandle {
        var face: ft.FT_Face = undefined;
        ft_check(ft.FT_New_Memory_Face(this.library, description.data.ptr, @intCast(description.data.len), 0, &face), "Failed to load font");

        ft_check(ft.FT_Set_Pixel_Sizes(face, 0, description.size), "Failed to set font size");
        const font = Font{
            .face = face,
            .glyphs = Glyphs.init(this.allocator),
            .sampler_settings = description.sampler_settings,
        };
        const index = try this.fonts.push(font);
        return index;
    }

    pub fn render_text(this: *FontManager, renderer_inst: *renderer.Renderer, info: RenderTextInfo) FontManagerError!void {
        const ft_font = this.fonts.get_ptr(info.font).?;
        var offset_x: f32 = info.offset.x();
        for (info.text) |ch| {
            const glyph_p = try ft_font.glyphs.getOrPut(ch);
            if (!glyph_p.found_existing) {
                glyph_p.value_ptr.* = try load_glyph(ft_font.face, ch, renderer_inst, ft_font.sampler_settings);
            }
            const glyph = glyph_p.value_ptr.*;
            const x: f32 = offset_x + @as(f32, @floatFromInt(glyph.metrics.horiBearingX >> 6)) * info.scale;
            const y: f32 = info.offset.y() + @as(f32, @floatFromInt(glyph.metrics.vertBearingY >> 6));

            if (glyph.texture) |tex| {
                try renderer_inst.draw_texture(.{
                    .texture = tex,
                    .position = Vec2.new(.{ x, y }),
                    .scale = Vec2.ONE,
                    .color = Vec4.ONE,
                    .region = Rect2{
                        .offset = Vec2.ZERO,
                        .extent = Vec2.new(.{
                            glyph.width,
                            glyph.height,
                        }),
                    },
                    .flags = .{
                        .is_text = true,
                    },
                });
            }
            offset_x += glyph.advance;
        }
    }

    pub fn render_text_formatted(this: *FontManager, renderer_inst: *renderer.Renderer, comptime fmt: []const u8, params: anytype, info: RenderTextInfo) FontManagerError!void {
        const text = try std.fmt.allocPrint(this.allocator, fmt, params);
        defer this.allocator.free(text);

        var info_n = info;
        info_n.text = text;
        return this.render_text(renderer_inst, info_n);
    }

    fn load_glyph(face: ft.FT_Face, char: u8, renderer_inst: *renderer.Renderer, sampler_settings: renderer.SamplerConfig) !Glyph {
        ft_check(ft.FT_Load_Char(face, char, ft.FT_LOAD_RENDER), "Failed to load char");
        ft_check(ft.FT_Render_Glyph(face.*.glyph, ft.FT_RENDER_MODE_NORMAL), "Failed to render char");
        var texture: ?TextureHandle = null;
        const glyph = face.*.glyph.*;
        if (glyph.bitmap.buffer != null) {
            const buf = glyph.bitmap.buffer[0 .. glyph.bitmap.width * glyph.bitmap.rows];
            texture = try renderer_inst.alloc_texture(.{
                .width = face.*.glyph.*.bitmap.width,
                .height = face.*.glyph.*.bitmap.rows,
                .depth = 1,
                .format = .r_8,
                .initial_bytes = buf,
                .flags = .{},
                .sampler_config = sampler_settings,
            });
        }

        return Glyph{
            .texture = texture,
            .width = @floatFromInt(glyph.bitmap.width),
            .height = @floatFromInt(glyph.bitmap.rows),
            .advance = @floatFromInt(glyph.advance.x >> 6),
            .bearing_x = @floatFromInt(glyph.bitmap_left),
            .bearing_y = @floatFromInt(glyph.bitmap_top),
            .metrics = glyph.metrics,
        };
    }
};

fn ft_check(condition: ft.FT_Error, comptime errmsg: []const u8) void {
    if (condition != ft.FT_Err_Ok) {
        sdl_util.message_box("Freetype error", "Freetype error: " ++ errmsg, .Error);
    }
}
