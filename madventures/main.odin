#+feature dynamic-literals
package main

import "base:runtime"
import "base:intrinsics"
import t "core:time"
import "core:fmt"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:math/ease"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import time "core:time"
import rand "core:math/rand"
import json "core:encoding/json"

import sapp "sokol/app"
import sg "sokol/gfx"
import sglue "sokol/glue"
import slog "sokol/log"

import stbi "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

import win32 "core:sys/windows"
import strconv "core:strconv"

app_state: struct {
	pass_action: sg.Pass_Action,
	pip: sg.Pipeline,
	bind: sg.Bindings,
	game: Game_State,
	input_state: Input_State,
    last_frame_time: time.Time
}

window_w :: 1024
window_h :: 768

main :: proc() {
	sapp.run({
		init_cb = init,
		frame_cb = frame,
		cleanup_cb = cleanup,
		event_cb = event,
		width = window_w,
		height = window_h,
		window_title = "Maki's Adventures",
		icon = { sokol_default = true },
		logger = { func = slog.func },
	})
}

init :: proc "c" () {
	using linalg, fmt
	context = runtime.default_context()

	init_time = t.now()

	sg.setup({
        environment = sglue.environment(),
		logger = { func = slog.func },
		d3d11_shader_debugging = ODIN_DEBUG,
	})

	load_tileset()

	init_images()
	init_fonts()
	init_sound()


	if !load_map("res_workbench/tiled/test_map.json") {
	   log_error("Failed to load map")
	}


	if !ODIN_DEBUG {
		play_sound("beat")
	}

	if ODIN_OS == .Windows {
		hwnd := sapp.win32_get_hwnd()
		if hwnd != nil {
			style := win32.GetWindowLongPtrW(auto_cast hwnd, win32.GWL_STYLE)

			style &= auto_cast ~win32.WS_SIZEBOX
			style &= auto_cast ~win32.WS_MAXIMIZEBOX

			win32.SetWindowLongPtrW(auto_cast hwnd, win32.GWL_STYLE, style)

			win32.SetWindowPos(auto_cast hwnd, nil, 0, 0, window_w, window_h,
				win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED)
		}
	}

	// :init
	gs = &app_state.game

	init_game()

    for &e, kind in entity_data {
        setup_entity(&e, kind)
    }

	app_state.bind.vertex_buffers[0] = sg.make_buffer({
		usage = .DYNAMIC,
		size = size_of(Quad) * len(draw_frame.quads),
	})

	index_buffer_count :: MAX_QUADS*6
	indices : [index_buffer_count]u16;
	i := 0;
	for i < index_buffer_count {
		indices[i + 0] = auto_cast ((i/6)*4 + 0)
		indices[i + 1] = auto_cast ((i/6)*4 + 1)
		indices[i + 2] = auto_cast ((i/6)*4 + 2)
		indices[i + 3] = auto_cast ((i/6)*4 + 0)
		indices[i + 4] = auto_cast ((i/6)*4 + 2)
		indices[i + 5] = auto_cast ((i/6)*4 + 3)
		i += 6;
	}
	app_state.bind.index_buffer = sg.make_buffer({
		type = .INDEXBUFFER,
		data = { ptr = &indices, size = size_of(indices) },
	})

	app_state.bind.samplers[SMP_default_sampler] = sg.make_sampler({})

	pipeline_desc : sg.Pipeline_Desc = {
		shader = sg.make_shader(quad_shader_desc(sg.query_backend())),
		index_type = .UINT16,
		layout = {
			attrs = {
				ATTR_quad_position = { format = .FLOAT2 },
				ATTR_quad_color0 = { format = .FLOAT4 },
				ATTR_quad_uv0 = { format = .FLOAT2 },
				ATTR_quad_bytes0 = { format = .UBYTE4N },
				ATTR_quad_color_override0 = { format = .FLOAT4 }
			},
		}
	}
	blend_state : sg.Blend_State = {
		enabled = true,
		src_factor_rgb = .SRC_ALPHA,
		dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
		op_rgb = .ADD,
		src_factor_alpha = .ONE,
		dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
		op_alpha = .ADD,
	}
	pipeline_desc.colors[0] = { blend = blend_state }
	app_state.pip = sg.make_pipeline(pipeline_desc)

	app_state.pass_action = {
		colors = {
			0 = { load_action = .CLEAR, clear_value = { 0, 0, 0, 1 }},
		},
	}
}

//
// :frame
frame :: proc "c" () {
	using runtime, linalg
	context = runtime.default_context()

    width := sapp.width()
    height := sapp.height()
    target_ratio := f32(game_res_w) / f32(game_res_h)
    window_ratio := f32(width) / f32(height)

    viewport_x, viewport_y : i32
    viewport_w, viewport_h : i32

    if window_ratio > target_ratio {
        viewport_h = auto_cast height
        viewport_w = i32(f32(height) * target_ratio)
        viewport_x = (auto_cast width - viewport_w) / 2
        viewport_y = 0
    } else {
        viewport_w = auto_cast width
        viewport_h = i32(f32(width) / target_ratio)
        viewport_x = 0
        viewport_y = (auto_cast height - viewport_h) / 2
    }

	draw_frame.reset = {}

	current_time := time.now()
	if app_state.last_frame_time._nsec == 0{
	   app_state.last_frame_time = current_time
	}

	frame_duration := time.diff(app_state.last_frame_time, current_time)
	app_state.last_frame_time = current_time
	dt := time.duration_seconds(frame_duration)

	update(dt)
	render()

	app_state.bind.images[IMG_tex0] = atlas.sg_image
	app_state.bind.images[IMG_tex1] = images[font.img_id].sg_img

	verts: Raw_Slice
	verts.len = draw_frame.quad_count
	verts.data = &draw_frame.quads[0]

	_v := transmute([]Quad)verts

	slice.stable_sort_by_cmp(_v, proc(a, b: Quad) -> slice.Ordering{
		return slice.cmp(a[0].z_layer, b[0].z_layer)
	})

	sg.update_buffer(
		app_state.bind.vertex_buffers[0],
		{ ptr = &draw_frame.quads[0], size = size_of(Quad) * len(draw_frame.quads) }
	)
	sg.begin_pass({ action = app_state.pass_action, swapchain = sglue.swapchain() })
	sg.apply_pipeline(app_state.pip)
	sg.apply_bindings(app_state.bind)
	sg.draw(0, 6*draw_frame.quad_count, 1)
	sg.end_pass()
	sg.commit()

	reset_input_state_for_next_frame(&app_state.input_state)
    free_all(context.temp_allocator)
}

cleanup :: proc "c" () {
	context = runtime.default_context()
	free_map()
	sg.shutdown()
}

//
// :UTILS

DEFAULT_UV :: v4{0, 0, 1, 1}
Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32
v2 :: Vector2
v3 :: Vector3
v4 :: Vector4
Matrix4 :: linalg.Matrix4f32;

COLOR_WHITE :: Vector4 {1,1,1,1}
COLOR_BLACK :: Vector4{0,0,0,1}
COLOR_RED :: Vector4{1,0,0,1}

loggie :: fmt.println
log_error :: fmt.println
log_warning :: fmt.println

init_time: t.Time;
seconds_since_init :: proc() -> f64 {
	using t
	if init_time._nsec == 0 {
		log_error("invalid time")
		return 0
	}
	return duration_seconds(since(init_time))
}

xform_translate :: proc(pos: Vector2) -> Matrix4 {
	return linalg.matrix4_translate(v3{pos.x, pos.y, 0})
}
xform_rotate :: proc(angle: f32) -> Matrix4 {
	return linalg.matrix4_rotate(math.to_radians(angle), v3{0,0,1})
}
xform_scale :: proc(scale: Vector2) -> Matrix4 {
	return linalg.matrix4_scale(v3{scale.x, scale.y, 1});
}

sign :: proc(x: f32) -> f32 {
    if x < 0 do return -1
    if x > 0 do return 1
    return 0
}

Pivot :: enum {
	bottom_left,
	bottom_center,
	bottom_right,
	center_left,
	center_center,
	center_right,
	top_left,
	top_center,
	top_right,
}

scale_from_pivot :: proc(pivot: Pivot) -> Vector2 {
	switch pivot {
		case .bottom_left: return v2{0.0, 0.0}
		case .bottom_center: return v2{0.5, 0.0}
		case .bottom_right: return v2{1.0, 0.0}
		case .center_left: return v2{0.0, 0.5}
		case .center_center: return v2{0.5, 0.5}
		case .center_right: return v2{1.0, 0.5}
		case .top_center: return v2{0.5, 1.0}
		case .top_left: return v2{0.0, 1.0}
		case .top_right: return v2{1.0, 1.0}
	}
	return {};
}

sine_breathe :: proc(p: $T) -> T where intrinsics.type_is_float(T) {
	return (math.sin((p - .25) * 2.0 * math.PI) / 2.0) + 0.5
}

animate_to_target_f32 :: proc(current: ^f32, target: f32, dt: f32, rate: f32 = 10.0) {
    diff := target - current^
    current^ += diff * min(1.0, dt * rate)
}

interpolate :: proc(a, b: $T, t: f32) -> T where intrinsics.type_is_float(T) {
    return a + (b - a) * t
}

//
// :RENDER STUFF

draw_sprite :: proc(pos: Vector2, img_id: Image_Id, pivot:= Pivot.bottom_left, xform := Matrix4(1), color_override:= v4{0,0,0,0}, z_layer := ZLayer.nil) {
	image := images[img_id]
	size := v2{auto_cast image.width, auto_cast image.height}

	RES :: 256
	p_scale := f32(RES) / max(f32(image.width), f32(image.height))

	xform0 := Matrix4(1)
	xform0 *= xform_translate(pos)
	xform0 *= xform
	xform0 *= xform_scale(v2{p_scale, p_scale})
	xform0 *= xform_translate(size * -scale_from_pivot(pivot))

	draw_rect_xform(xform0, size, img_id=img_id, color_override=color_override, z_layer=z_layer)
}

draw_sprite_1024 :: proc(pos: Vector2, size := v2{0,0} , img_id: Image_Id, pivot:= Pivot.bottom_left, xform := Matrix4(1), color_override:= v4{0,0,0,0}, z_layer := ZLayer.nil) {
	image := images[img_id]
	size := size

	RES :: 1024
	p_scale := f32(RES) / max(f32(image.width), f32(image.height))

	xform0 := Matrix4(1)
	xform0 *= xform_translate(pos)
	xform0 *= xform
	xform0 *= xform_scale(v2{p_scale, p_scale})
	xform0 *= xform_translate(size * -scale_from_pivot(pivot))

	draw_rect_xform(xform0, size, img_id=img_id, color_override=color_override, z_layer=z_layer)
}

fit_size_to_square :: proc(target_size: Vector2) -> Vector2{
    max_dim := max(target_size.x, target_size.y)
    return Vector2{max_dim, max_dim}
}

draw_sprite_with_size :: proc(pos: Vector2, size := v2{0,0} , img_id: Image_Id, pivot:= Pivot.bottom_left, xform := Matrix4(1), color_override:= v4{0,0,0,0}, z_layer := ZLayer.nil) {
	image := images[img_id]
	size := size

	RES :: 256
	p_scale := f32(RES) / max(f32(image.width), f32(image.height))

	xform0 := Matrix4(1)
	xform0 *= xform_translate(pos)
	xform0 *= xform
	xform0 *= xform_scale(v2{p_scale, p_scale})
	xform0 *= xform_translate(size * -scale_from_pivot(pivot))

	draw_rect_xform(xform0, size, img_id=img_id, color_override=color_override, z_layer=z_layer)
}

draw_nores_sprite_with_size :: proc(pos: Vector2, size: Vector2, img_id: Image_Id, pivot := Pivot.bottom_left, xform := Matrix4(1), color_override := v4{0,0,0,0}, z_layer := ZLayer.nil) {
    image := images[img_id]

    xform0 := Matrix4(1)
    xform0 *= xform_translate(pos)
    xform0 *= xform
    xform0 *= xform_translate(size * -scale_from_pivot(pivot))

    draw_rect_xform(xform0, size, img_id=img_id, color_override=color_override, z_layer=z_layer)
}

draw_sprite_in_rect :: proc(img_id: Image_Id, pos: Vector2, size: Vector2, xform := Matrix4(1), col := COLOR_WHITE, color_override := v4{0,0,0,0}, z_layer := ZLayer.nil){
    image := images[img_id]
    img_size := v2{auto_cast image.width, auto_cast image.height}

    pos0 := pos
    pos0.x += (size.x - img_size.x) * 0.5
    pos0.y += (size.y - img_size.y) * 0.5

    draw_rect_aabb(pos0, img_size, col = col, img_id = img_id, color_override = color_override, z_layer = z_layer)
}

draw_rect_aabb_actually :: proc(
	aabb: AABB,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0},
	z_layer:=ZLayer.nil,
) {
	xform := linalg.matrix4_translate(v3{aabb.x, aabb.y, 0})
	draw_rect_xform(xform, aabb_size(aabb), col, uv, img_id, color_override, z_layer=z_layer)
}

draw_rect_aabb :: proc(
	pos: Vector2,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0},
	z_layer := ZLayer.nil,
) {
	xform := linalg.matrix4_translate(v3{pos.x, pos.y, 0})
	draw_rect_xform(xform, size, col, uv, img_id, color_override, z_layer=z_layer)
}

draw_rect_xform :: proc(
	xform: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0},
	z_layer := ZLayer.nil,
) {
	draw_rect_projected(draw_frame.coord_space.proj * draw_frame.coord_space.camera * xform, size, col, uv, img_id, color_override, z_layer=z_layer)
}

Vertex :: struct {
	pos: Vector2,
	col: Vector4,
	uv: Vector2,
	tex_index: u8,
	z_layer: u8,
	_: [2]u8,
	color_override: Vector4,
}

Quad :: [4]Vertex;

MAX_QUADS :: 8192
MAX_VERTS :: MAX_QUADS * 4

Draw_Frame :: struct {
	quads: [MAX_QUADS]Quad,

    using reset: struct {
        coord_space: Coord_Space,
        quad_count: int,
        flip_v: bool,
        active_z_layer: ZLayer,
    }
}
draw_frame : Draw_Frame

ZLayer :: enum u8{
    nil,
    background,
    player,
    foreground,
    midground,
    ui,
    xp_bars,
    bow,
}

Coord_Space :: struct {
    proj: Matrix4,
    camera: Matrix4,
}

set_coord_space :: proc(coord: Coord_Space) {
	draw_frame.coord_space = coord
}

@(deferred_out=set_coord_space)
push_coord_space :: proc(coord: Coord_Space) -> Coord_Space {
    og := draw_frame.coord_space
    draw_frame.coord_space = coord
    return og
}

set_z_layer :: proc(zlayer: ZLayer) {
	draw_frame.active_z_layer = zlayer
}
@(deferred_out=set_z_layer)
push_z_layer :: proc(zlayer: ZLayer) -> ZLayer {
	og := draw_frame.active_z_layer
	draw_frame.active_z_layer = zlayer
	return og
}

// below is the lower level draw rect stuff

draw_rect_projected :: proc(
	world_to_clip: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0},
	z_layer := ZLayer.nil,
) {

	bl := v2{ 0, 0 }
	tl := v2{ 0, size.y }
	tr := v2{ size.x, size.y }
	br := v2{ size.x, 0 }

	uv0 := uv
	if uv == DEFAULT_UV {
		uv0 = images[img_id].atlas_uvs
	}

    if draw_frame.flip_v {
        uv0.y, uv0.w = uv0.w, uv0.y
    }

	tex_index :u8= images[img_id].tex_index
	if img_id == .nil {
		tex_index = 255
	}

	draw_quad_projected(world_to_clip, {bl, tl, tr, br}, {col, col, col, col}, {uv0.xy, uv0.xw, uv0.zw, uv0.zy}, {tex_index,tex_index,tex_index,tex_index}, {color_override,color_override,color_override,color_override}, z_layer = z_layer)

}

draw_quad_projected :: proc(
	world_to_clip:   Matrix4,
	positions:       [4]Vector2,
	colors:          [4]Vector4,
	uvs:             [4]Vector2,
	tex_indicies:       [4]u8,
	//flags:           [4]Quad_Flags,
	color_overrides: [4]Vector4,
	z_layer: ZLayer=.nil,
	//hsv:             [4]Vector3
) {
	using linalg

	if draw_frame.quad_count >= MAX_QUADS {
		log_error("max quads reached")
		return
	}

	z_layer0 := z_layer
	if z_layer0 == .nil {
		z_layer0 = draw_frame.active_z_layer
	}

	verts := cast(^[4]Vertex)&draw_frame.quads[draw_frame.quad_count];
	draw_frame.quad_count += 1;

	verts[0].pos = (world_to_clip * Vector4{positions[0].x, positions[0].y, 0.0, 1.0}).xy
	verts[1].pos = (world_to_clip * Vector4{positions[1].x, positions[1].y, 0.0, 1.0}).xy
	verts[2].pos = (world_to_clip * Vector4{positions[2].x, positions[2].y, 0.0, 1.0}).xy
	verts[3].pos = (world_to_clip * Vector4{positions[3].x, positions[3].y, 0.0, 1.0}).xy

	verts[0].col = colors[0]
	verts[1].col = colors[1]
	verts[2].col = colors[2]
	verts[3].col = colors[3]

	verts[0].uv = uvs[0]
	verts[1].uv = uvs[1]
	verts[2].uv = uvs[2]
	verts[3].uv = uvs[3]

	verts[0].tex_index = tex_indicies[0]
	verts[1].tex_index = tex_indicies[1]
	verts[2].tex_index = tex_indicies[2]
	verts[3].tex_index = tex_indicies[3]

	verts[0].color_override = color_overrides[0]
	verts[1].color_override = color_overrides[1]
	verts[2].color_override = color_overrides[2]
	verts[3].color_override = color_overrides[3]

	verts[0].z_layer = u8(z_layer0)
	verts[1].z_layer = u8(z_layer0)
	verts[2].z_layer = u8(z_layer0)
	verts[3].z_layer = u8(z_layer0)
}

//
// :IMAGE STUFF
//
Image_Id :: enum {
	nil,

	background,
	midground,
	foreground,
    fmod_logo,
    maki_logo,

    tileset_overworld,
    player,
}

Image :: struct {
	width, height: i32,
	tex_index: u8,
	sg_img: sg.Image,
	data: [^]byte,
	atlas_uvs: Vector4,
}
images: [128]Image
image_count: int

init_images :: proc() {
	using fmt

	img_dir := "res/images/"

	highest_id := 0;
	for img_name, id in Image_Id {
		if id == 0 { continue }

		if id > highest_id {
			highest_id = id
		}

		path := tprint(img_dir, img_name, ".png", sep="")
		png_data, succ := os.read_entire_file(path)
		assert(succ, tprint(path, "not found"))

		stbi.set_flip_vertically_on_load(1)
		width, height, channels: i32
		img_data := stbi.load_from_memory(raw_data(png_data), auto_cast len(png_data), &width, &height, &channels, 4)
		assert(img_data != nil, "stbi load failed, invalid image?")

		img : Image;
		img.width = width
		img.height = height
		img.data = img_data

		images[id] = img
	}
	image_count = highest_id + 1

	pack_images_into_atlas()
}

Atlas :: struct {
	w, h: int,
	sg_image: sg.Image,
}
atlas: Atlas

pack_images_into_atlas :: proc() {
    max_width := 0
    max_height := 0
    total_area := 0

    for img, id in images {
        if img.width == 0 do continue
        max_width = max(max_width, int(img.width))
        max_height = max(max_height, int(img.height))
        total_area += int(img.width) * int(img.height)
    }

    min_size := 128
    for min_size * min_size < total_area * 2 {
        min_size *= 2
    }

    atlas.w = min_size
    atlas.h = min_size

    nodes := make([dynamic]stbrp.Node, atlas.w)
    defer delete(nodes)

    cont: stbrp.Context
    stbrp.init_target(&cont, auto_cast atlas.w, auto_cast atlas.h, raw_data(nodes), auto_cast len(nodes))

    rects := make([dynamic]stbrp.Rect)
    defer delete(rects)

    for img, id in images {
        if img.width == 0 do continue
        rect := stbrp.Rect{
            id = auto_cast id,
            w = auto_cast img.width,
            h = auto_cast img.height,
        }
        append(&rects, rect)
    }

    if len(rects) == 0 {
        return
    }

    succ := stbrp.pack_rects(&cont, raw_data(rects), auto_cast len(rects))
    if succ == 0 {
        for rect, i in rects {
            fmt.printf("Rect %d: %dx%d = %d pixels\n",
                rect.id, rect.w, rect.h, rect.w * rect.h)
        }
        assert(false, "failed to pack all the rects, ran out of space?")
    }

    // allocate big atlas with proper size
    raw_data_size := atlas.w * atlas.h * 4
    atlas_data, err := mem.alloc(raw_data_size)
    if err != nil {
        return
    }
    defer mem.free(atlas_data)

    mem.set(atlas_data, 255, raw_data_size)

    // copy rect row-by-row into destination atlas
    for rect in rects {
        img := &images[rect.id]
        if img == nil || img.data == nil {
            continue
        }

        // copy row by row into atlas
        for row in 0 ..< rect.h {
            src_row := mem.ptr_offset(&img.data[0], row * rect.w * 4)
            dest_row := mem.ptr_offset(
                cast(^u8)atlas_data,
                ((rect.y + row) * auto_cast atlas.w + rect.x) * 4,
            )
            mem.copy(dest_row, src_row, auto_cast rect.w * 4)
        }

        stbi.image_free(img.data)
        img.data = nil

        img.atlas_uvs.x = cast(f32)rect.x / cast(f32)atlas.w
        img.atlas_uvs.y = cast(f32)rect.y / cast(f32)atlas.h
        img.atlas_uvs.z = img.atlas_uvs.x + cast(f32)img.width / cast(f32)atlas.w
        img.atlas_uvs.w = img.atlas_uvs.y + cast(f32)img.height / cast(f32)atlas.h
    }

    // Write debug atlas
    stbi.write_png(
        "./atlases/atlas.png",
        auto_cast atlas.w,
        auto_cast atlas.h,
        4,
        atlas_data,
        4 * auto_cast atlas.w,
    )

    // setup image for GPU
    desc: sg.Image_Desc
    desc.width = auto_cast atlas.w
    desc.height = auto_cast atlas.h
    desc.pixel_format = .RGBA8
    desc.data.subimage[0][0] = {
        ptr = atlas_data,
        size = auto_cast raw_data_size,
    }

    atlas.sg_image = sg.make_image(desc)
    if atlas.sg_image.id == sg.INVALID_ID {
        log_error("failed to make image")
    }
}

//
// :FONT
//
draw_text :: proc(pos: Vector2, text: string, col:=COLOR_WHITE, scale:= 1.0, pivot:=Pivot.bottom_left, z_layer:= ZLayer.nil) {
	using stbtt

	push_z_layer(z_layer)

	total_size : v2
	for char, i in text {

		advance_x: f32
		advance_y: f32
		q: aligned_quad
		GetBakedQuad(&font.char_data[0], font_bitmap_w, font_bitmap_h, cast(i32)char - 32, &advance_x, &advance_y, &q, false)

		size := v2{ abs(q.x0 - q.x1), abs(q.y0 - q.y1) }

		bottom_left := v2{ q.x0, -q.y1 }
		top_right := v2{ q.x1, -q.y0 }
		assert(bottom_left + size == top_right)

		if i == len(text)-1 {
			total_size.x += size.x
		} else {
			total_size.x += advance_x
		}

		total_size.y = max(total_size.y, top_right.y)
	}

	pivot_offset := total_size * -scale_from_pivot(pivot)

	debug_text := false
	if debug_text {
		draw_rect_aabb(pos + pivot_offset, total_size, col=COLOR_BLACK)
	}

	x: f32
	y: f32
	for char in text {

		advance_x: f32
		advance_y: f32
		q: aligned_quad
		GetBakedQuad(&font.char_data[0], font_bitmap_w, font_bitmap_h, cast(i32)char - 32, &advance_x, &advance_y, &q, false)

		size := v2{ abs(q.x0 - q.x1), abs(q.y0 - q.y1) }

		bottom_left := v2{ q.x0, -q.y1 }
		top_right := v2{ q.x1, -q.y0 }
		assert(bottom_left + size == top_right)

		offset_to_render_at := v2{x,y} + bottom_left

		offset_to_render_at += pivot_offset

		uv := v4{ q.s0, q.t1,
							q.s1, q.t0 }

		xform := Matrix4(1)
		xform *= xform_translate(pos)
		xform *= xform_scale(v2{auto_cast scale, auto_cast scale})
		xform *= xform_translate(offset_to_render_at)

		if debug_text {
			draw_rect_xform(xform, size, col=v4{1,1,1,0.8})
		}

		draw_rect_xform(xform, size, uv=uv, img_id=font.img_id, col=col)

		x += advance_x
		y += -advance_y
	}

}

font_bitmap_w :: 256
font_bitmap_h :: 256
char_count :: 96
Font :: struct {
	char_data: [char_count]stbtt.bakedchar,
	img_id: Image_Id,
}
font: Font

init_fonts :: proc() {
	using stbtt

	bitmap, _ := mem.alloc(font_bitmap_w * font_bitmap_h)
	font_height := 15
	path := "res/fonts/alagard.ttf"
	ttf_data, err := os.read_entire_file(path)
	assert(ttf_data != nil, "failed to read font")

	ret := BakeFontBitmap(raw_data(ttf_data), 0, auto_cast font_height, auto_cast bitmap, font_bitmap_w, font_bitmap_h, 32, char_count, &font.char_data[0])
	assert(ret > 0, "not enough space in bitmap")

	stbi.write_png("font.png", auto_cast font_bitmap_w, auto_cast font_bitmap_h, 1, bitmap, auto_cast font_bitmap_w)

	desc : sg.Image_Desc
	desc.width = auto_cast font_bitmap_w
	desc.height = auto_cast font_bitmap_h
	desc.pixel_format = .R8
	desc.data.subimage[0][0] = {ptr=bitmap, size=auto_cast (font_bitmap_w*font_bitmap_h)}
	sg_img := sg.make_image(desc)
	if sg_img.id == sg.INVALID_ID {
		log_error("failed to make image")
	}

	id := store_image(font_bitmap_w, font_bitmap_h, 1, sg_img)
	font.img_id = id
}

store_image :: proc(w: int, h: int, tex_index: u8, sg_img: sg.Image) -> Image_Id {

	img : Image
	img.width = auto_cast w
	img.height = auto_cast h
	img.tex_index = tex_index
	img.sg_img = sg_img
	img.atlas_uvs = DEFAULT_UV

	id := image_count
	images[id] = img
	image_count += 1

	return auto_cast id
}

//
// :game state
//

Game_State :: struct {
	ticks: u64,
	entities: [128]Entity,
	latest_entity_id: u64,
	player_handle: Entity_Handle,
}
gs: ^Game_State

init_game :: proc() {
    gs.player_handle = init_player()
}

// :update

get_player :: proc() -> ^Entity {
	return handle_to_entity(gs.player_handle)
}

get_delta_time :: proc() -> f64 {
    return time.duration_seconds(time.diff(app_state.last_frame_time, time.now()))
}

game_res_w :: 1024
game_res_h :: 768

update :: proc(dt: f64) {
	using linalg

    width := sapp.width()
    height := sapp.height()
    update_projection(int(width), int(height))
    update_sound()

	gs.ticks += 1
}

render :: proc() {
	using linalg

    width := sapp.width()
    height := sapp.height()
    proj := matrix_ortho3d_f32(
        game_res_w * -0.5,
        game_res_w * 0.5,
        game_res_h * -0.5,
        game_res_h * 0.5,
        -1,
        1,
    )
    coord := Coord_Space{
        proj = proj,
        camera = Matrix4(1),
    }
    set_coord_space(coord)

    map_pos := v2{
        game_res_w * -0.5,
        game_res_h * -0.5,
    }

    render_map(map_pos)
	render_player(map_pos)

	gs.ticks += 1
}

mouse_pos_in_screen_space :: proc() -> Vector2 {
	if draw_frame.coord_space.proj == {} {
		log_error("no projection matrix set yet")
	}

	mouse := v2{app_state.input_state.mouse_x, app_state.input_state.mouse_y}
	x := mouse.x / f32(window_w);
	y := mouse.y / f32(window_h) - 1.0;
	y *= -1
	return v2{x * game_res_w, y * game_res_h}
}

mouse_pos_in_world_space :: proc() -> Vector2 {
    if draw_frame.coord_space.proj == {} {
        log_error("no projection matrix set yet")
        return v2{0, 0}
    }

    mouse := v2{app_state.input_state.mouse_x, app_state.input_state.mouse_y}

    width := f32(sapp.width())
    height := f32(sapp.height())

    ndc_x := (mouse.x / width) * 2.0 - 1.0
    ndc_y := -((mouse.y / height) * 2.0 - 1.0)

    mouse_clip := v4{ndc_x, ndc_y, 0, 1}

    view_proj := draw_frame.coord_space.proj * draw_frame.coord_space.camera
    inv_view_proj := linalg.inverse(view_proj)
    world_pos := mouse_clip * inv_view_proj

    return world_pos.xy
}

//
// :entity
//

Entity_Flags :: enum {
	allocated,
	//physics
}

Entity_Kind :: enum {
	nil,
	Player,
}

Entity :: struct {
	handle: Entity_Handle,
	kind: Entity_Kind,
	flags: bit_set[Entity_Flags],
	pos: Vector2,
	frame: struct{
		input_axis: Vector2,
	},
}

entity_data: [Entity_Kind]Entity

Entity_Handle :: struct {
    id: u64,
    index: int,
}

handle_to_entity :: proc(handle: Entity_Handle) -> ^Entity {
    en := &gs.entities[handle.index]
    if en.handle.id == handle.id{
        return en
    }
	log_error("entity no longer valid")
	return nil
}

entity_to_handle :: proc(entity: Entity) -> Entity_Handle {
	return entity.handle
}

entity_create :: proc() -> ^Entity {
	spare_en : ^Entity
	index := -1
	for &en, i in gs.entities {
		if !(.allocated in en.flags) {
			spare_en = &en
			index = i
			break
		}
	}

	if spare_en == nil {
		log_error("ran out of entities, increase size")
		return nil
	} else {
		spare_en.flags = { .allocated }
		gs.latest_entity_id += 1
		spare_en.handle.id = gs.latest_entity_id
		spare_en.handle.index = index
		return spare_en
	}
}

entity_destroy :: proc(entity: ^Entity, dt: f32 = 0) {
    mem.set(entity, 0, size_of(Entity))
}

setup_entity :: proc(e: ^Entity, kind: Entity_Kind){
	#partial switch kind {
		case .Player:
			// SOMETHING
	}
}


//
// :input

Key_Code :: enum {
	INVALID = 0,
	SPACE = 32,
	APOSTROPHE = 39,
	COMMA = 44,
	MINUS = 45,
	PERIOD = 46,
	SLASH = 47,
	_0 = 48,
	_1 = 49,
	_2 = 50,
	_3 = 51,
	_4 = 52,
	_5 = 53,
	_6 = 54,
	_7 = 55,
	_8 = 56,
	_9 = 57,
	SEMICOLON = 59,
	EQUAL = 61,
	A = 65,
	B = 66,
	C = 67,
	D = 68,
	E = 69,
	F = 70,
	G = 71,
	H = 72,
	I = 73,
	J = 74,
	K = 75,
	L = 76,
	M = 77,
	N = 78,
	O = 79,
	P = 80,
	Q = 81,
	R = 82,
	S = 83,
	T = 84,
	U = 85,
	V = 86,
	W = 87,
	X = 88,
	Y = 89,
	Z = 90,
	LEFT_BRACKET = 91,
	BACKSLASH = 92,
	RIGHT_BRACKET = 93,
	GRAVE_ACCENT = 96,
	WORLD_1 = 161,
	WORLD_2 = 162,
	ESCAPE = 256,
	ENTER = 257,
	TAB = 258,
	BACKSPACE = 259,
	INSERT = 260,
	DELETE = 261,
	RIGHT = 262,
	LEFT = 263,
	DOWN = 264,
	UP = 265,
	PAGE_UP = 266,
	PAGE_DOWN = 267,
	HOME = 268,
	END = 269,
	CAPS_LOCK = 280,
	SCROLL_LOCK = 281,
	NUM_LOCK = 282,
	PRINT_SCREEN = 283,
	PAUSE = 284,
	F1 = 290,
	F2 = 291,
	F3 = 292,
	F4 = 293,
	F5 = 294,
	F6 = 295,
	F7 = 296,
	F8 = 297,
	F9 = 298,
	F10 = 299,
	F11 = 300,
	F12 = 301,
	F13 = 302,
	F14 = 303,
	F15 = 304,
	F16 = 305,
	F17 = 306,
	F18 = 307,
	F19 = 308,
	F20 = 309,
	F21 = 310,
	F22 = 311,
	F23 = 312,
	F24 = 313,
	F25 = 314,
	KP_0 = 320,
	KP_1 = 321,
	KP_2 = 322,
	KP_3 = 323,
	KP_4 = 324,
	KP_5 = 325,
	KP_6 = 326,
	KP_7 = 327,
	KP_8 = 328,
	KP_9 = 329,
	KP_DECIMAL = 330,
	KP_DIVIDE = 331,
	KP_MULTIPLY = 332,
	KP_SUBTRACT = 333,
	KP_ADD = 334,
	KP_ENTER = 335,
	KP_EQUAL = 336,
	LEFT_SHIFT = 340,
	LEFT_CONTROL = 341,
	LEFT_ALT = 342,
	LEFT_SUPER = 343,
	RIGHT_SHIFT = 344,
	RIGHT_CONTROL = 345,
	RIGHT_ALT = 346,
	RIGHT_SUPER = 347,
	MENU = 348,

	LEFT_MOUSE = 400,
	RIGHT_MOUSE = 401,
	MIDDLE_MOUSE = 402,
}
MAX_KEYCODES :: sapp.MAX_KEYCODES
map_sokol_mouse_button :: proc "c" (sokol_mouse_button: sapp.Mousebutton) -> Key_Code {
	#partial switch sokol_mouse_button {
		case .LEFT: return .LEFT_MOUSE
		case .RIGHT: return .RIGHT_MOUSE
		case .MIDDLE: return .MIDDLE_MOUSE
	}
	return nil
}

Input_State_Flags :: enum {
	down,
	just_pressed,
	just_released,
	repeat,
}

Input_State :: struct {
	keys: [MAX_KEYCODES]bit_set[Input_State_Flags],
	mouse_x, mouse_y: f32,
}

reset_input_state_for_next_frame :: proc(state: ^Input_State) {
	for &set in state.keys {
		set -= {.just_pressed, .just_released, .repeat}
	}
}

key_just_pressed :: proc(code: Key_Code) -> bool {
	return .just_pressed in app_state.input_state.keys[code]
}
key_down :: proc(code: Key_Code) -> bool {
	return .down in app_state.input_state.keys[code]
}
key_just_released :: proc(code: Key_Code) -> bool {
	return .just_released in app_state.input_state.keys[code]
}
key_repeat :: proc(code: Key_Code) -> bool {
	return .repeat in app_state.input_state.keys[code]
}

event :: proc "c" (event: ^sapp.Event) {
    context = runtime.default_context()
	input_state := &app_state.input_state

	#partial switch event.type {
	    case .RESIZED:
	       update_projection(auto_cast event.window_width, auto_cast event.window_height)
		case .MOUSE_UP:
		if .down in input_state.keys[map_sokol_mouse_button(event.mouse_button)] {
			input_state.keys[map_sokol_mouse_button(event.mouse_button)] -= { .down }
			input_state.keys[map_sokol_mouse_button(event.mouse_button)] += { .just_released }
		}
		case .MOUSE_DOWN:
		if !(.down in input_state.keys[map_sokol_mouse_button(event.mouse_button)]) {
			input_state.keys[map_sokol_mouse_button(event.mouse_button)] += { .down, .just_pressed }
		}

		case .MOUSE_MOVE:
		input_state.mouse_x = event.mouse_x
		input_state.mouse_y = event.mouse_y

		case .KEY_UP:
		if .down in input_state.keys[event.key_code] {
			input_state.keys[event.key_code] -= { .down }
			input_state.keys[event.key_code] += { .just_released }
		}
		case .KEY_DOWN:
		if !event.key_repeat && !(.down in input_state.keys[event.key_code]) {
			input_state.keys[event.key_code] += { .down, .just_pressed }
		}
		if event.key_repeat {
			input_state.keys[event.key_code] += { .repeat }
		}
	}
}

update_projection :: proc(width, height: int) {
    using linalg
    draw_frame.coord_space.proj = matrix_ortho3d_f32(
        game_res_w * -0.5,
        game_res_w * 0.5,
        game_res_h * -0.5,
        game_res_h * 0.5,
        -1,
        1,
    )
    draw_frame.coord_space.camera = Matrix4(1)
}



//
// :collision

AABB :: Vector4

aabb_collide :: proc(a, b: Vector4) ->bool {
    return !(a.z < b.x || a.x > b.z || a.w < b.y || a.y > b.w)
}

aabb_collide_aabb :: proc(a: AABB, b: AABB) -> (bool, Vector2) {
	dx := (a.z + a.x) / 2 - (b.z + b.x) / 2;
	dy := (a.w + a.y) / 2 - (b.w + b.y) / 2;
	overlap_x := (a.z - a.x) / 2 + (b.z - b.x) / 2 - abs(dx);
	overlap_y := (a.w - a.y) / 2 + (b.w - b.y) / 2 - abs(dy);
	if overlap_x <= 0 || overlap_y <= 0 {
		return false, Vector2{};
	}
	penetration := Vector2{};
	if overlap_x < overlap_y {
		penetration.x = overlap_x if dx > 0 else -overlap_x;
	} else {
		penetration.y = overlap_y if dy > 0 else -overlap_y;
	}
	return true, penetration;
}

aabb_get_center :: proc(a: Vector4) -> Vector2 {
	min := a.xy;
	max := a.zw;
	return { min.x + 0.5 * (max.x-min.x), min.y + 0.5 * (max.y-min.y) };
}

aabb_make_with_pos :: proc(pos: Vector2, size: Vector2, pivot: Pivot) -> Vector4 {
	aabb := (Vector4){0,0,size.x,size.y};
	aabb = aabb_shift(aabb, pos - scale_from_pivot(pivot) * size);
	return aabb;
}

aabb_make_with_size :: proc(size: Vector2, pivot: Pivot) -> Vector4 {
	return aabb_make({}, size, pivot);
}

aabb_make :: proc{
	aabb_make_with_pos,
	aabb_make_with_size
}

aabb_shift :: proc(aabb: Vector4, amount: Vector2) -> Vector4 {
	return {aabb.x + amount.x, aabb.y + amount.y, aabb.z + amount.x, aabb.w + amount.y};
}

aabb_contains :: proc(aabb: Vector4, p: Vector2) -> bool {
	return (p.x >= aabb.x) && (p.x <= aabb.z) &&
           (p.y >= aabb.y) && (p.y <= aabb.w);
}

aabb_size :: proc(aabb: AABB) -> Vector2 {
	return { abs(aabb.x - aabb.z), abs(aabb.y - aabb.w) }
}

// :tilemap

Tile_Map :: struct {
    width, height: int,
    tile_width, tile_height: int,
    render_width, render_height: int,
    layers: []Tile_Layer,
    tileset_image_id: Image_Id,
    tileset_columns: int,
    tileset_tile_width, tileset_tile_height: int,
    tileset_tile_count: int,
    first_gid: int,
    loaded: bool,
    tileset_collisions: map[int][]Collision_Shape,
}

Tile_Layer :: struct {
    name: string,
    data: []int,
    width, height: int,
    visible: bool,
}

Tiled_Layer_Json :: struct {
    name: string,
    data: []int,
    width, height: int,
    visible: bool,
    type: string,
}

Tiled_Map_Json :: struct {
    width, height: int,
    tilewidth, tileheight: int,
    layers: []Tiled_Layer_Json,
    tilesets: []Tiled_Tileset_Json,
}

Tiled_Tileset_Json :: struct {
    firstgid: int,
    source: string,
}

Tiled_Tileset_XML :: struct {
    name: string,
    tilewidth, tileheight: int,
    tilecount: int,
    columns: int,
    image_souce: string,
}

Shape_Type :: enum {
    Rectangle,
    Polygon,
    Ellipse,
    Point,
}

Collision_Shape :: struct {
    shape_type: Shape_Type,
    x, y: f32,
    width, height: f32,
    points: []Vector2,
}

Tiled_Tileset_Tsx :: struct {
    name: string,
    tilewidth, tileheight: int,
    tilecount: int,
    columns: int,
    image_source: string,
    tiles: []Tiled_Tile,
}

Tiled_Tile :: struct {
    id: int,
    objectgroup: Tiled_Objectgroup,
}

Tiled_Objectgroup :: struct {
    objects: []Tiled_Object,
}

Tiled_Object :: struct {
    id: int,
    x, y: f32,
    width, height: f32,
    object_type: string,
    polygon_points: string,
}

current_map: Tile_Map

load_map :: proc(path: string) -> bool {
    fmt.println("Attempting to load map from:", path)

    json_data, read_ok := os.read_entire_file(path)
    if !read_ok {
        fmt.println("Failed to read map file:", path)
        return false
    }
    defer delete(json_data)

    game_map := &current_map

    tiled_map: Tiled_Map_Json
    json_err := json.unmarshal(json_data, &tiled_map)
    if json_err != nil {
        fmt.println("Failed to parse map JSON:", json_err)
        return false
    }
    fmt.println("Map loaded successfully. Size:", tiled_map.width, "x", tiled_map.height)
    fmt.println("Number of layers:", len(tiled_map.layers))

    game_map.width = tiled_map.width
    game_map.height = tiled_map.height
    game_map.tile_width = tiled_map.tilewidth
    game_map.tile_height = tiled_map.tileheight
    game_map.render_width = 32  // Keep render size at 32x32
    game_map.render_height = 32

    if game_map.layers != nil {
        for layer in game_map.layers {
            delete(layer.name)
            delete(layer.data)
        }
        delete(game_map.layers)
    }

    tile_layer_count := 0
    for layer in tiled_map.layers {
        if layer.type == "tilelayer" {
            tile_layer_count += 1
        }
    }

    game_map.layers = make([]Tile_Layer, tile_layer_count)

    layer_index := 0
    for layer in tiled_map.layers {
        if layer.type == "tilelayer" {
            game_map.layers[layer_index] = Tile_Layer{
                name = strings.clone(layer.name),
                data = make([]int, len(layer.data)),
                width = layer.width,
                height = layer.height,
                visible = layer.visible,
            }
            copy(game_map.layers[layer_index].data, layer.data)
            layer_index += 1
        }
    }

    if len(tiled_map.tilesets) > 0 {
        game_map.first_gid = tiled_map.tilesets[0].firstgid
        game_map.tileset_image_id = .tileset_overworld

        game_map.tileset_tile_width = 8
        game_map.tileset_tile_height = 8

        tileset_img := images[game_map.tileset_image_id]
        game_map.tileset_columns = int(tileset_img.width) / game_map.tileset_tile_width

        game_map.tileset_tile_count = int(tileset_img.width / i32(game_map.tileset_tile_width)) *
                                     int(tileset_img.height / i32(game_map.tileset_tile_height))

        if len(tiled_map.tilesets[0].source) > 0 {
            dir_path := filepath.dir(path)
            tsx_path := filepath.join({dir_path, tiled_map.tilesets[0].source})

            collisions, ok := load_tileset_collisions(tsx_path)
            if ok {
                if game_map.tileset_collisions != nil {
                    for _, shapes in game_map.tileset_collisions {
                        for shape in shapes {
                            if shape.points != nil {
                                delete(shape.points)
                            }
                        }
                        delete(shapes)
                    }
                    delete(game_map.tileset_collisions)
                }

                game_map.tileset_collisions = collisions
            } else {
                fmt.println("Failed to load collision data from:", tsx_path)
            }
        }
    }

    game_map.loaded = true
    return true
}

get_tile_at :: proc(x, y: int) -> int {
    game_map := &current_map

    if !game_map.loaded || x < 0 || y < 0 || x > game_map.width || y >= game_map.height {
        return 0
    }

    if len(game_map.layers) > 0 {
        layer := game_map.layers[0]
        index := y * game_map.width + x
        if index < len(layer.data) {
            return layer.data[index]
        }
    }

    return 0
}

Map_Orientation :: enum {
    Standard,       // Original rendering (x, y)
    Flipped_X,      // Flip along X axis (width-x-1, y)
    Flipped_Y,      // Flip along Y axis (x, height-y-1)
    Flipped_Both,   // Flip along both axes - 180° rotation (width-x-1, height-y-1)
    Transposed,     // Transpose X and Y - 90° + flip (y, x)
    Transposed_Alt, // Alternate transposition - 90° rotation (y, width-x-1)
}

map_orientation := Map_Orientation.Flipped_Y

render_map :: proc(position: Vector2) {
    game_map := &current_map

    if !game_map.loaded || game_map.tileset_image_id == .nil {
        fmt.println("Map not loaded or no tileset, can't render")
        return
    }

    tile_count := 0

    for layer in game_map.layers {
        if !layer.visible {
            continue
        }

        for y in 0..<game_map.height {
            for x in 0..<game_map.width {
                map_x, map_y := x, y

                #partial switch map_orientation {
                    case .Standard:
                        map_x, map_y = x, y
                    case .Flipped_X:
                        map_x, map_y = game_map.width - x - 1, y
                    case .Flipped_Y:
                        map_x, map_y = x, game_map.height - y - 1
                    case .Flipped_Both:
                        map_x, map_y = game_map.width - x - 1, game_map.height - y - 1
                    case .Transposed:
                        map_x, map_y = y, x
                    case .Transposed_Alt:
                        map_x, map_y = y, game_map.width - x - 1
                }

                index := map_y * game_map.width + map_x
                if index >= len(layer.data) {
                    continue
                }

                tile_index := layer.data[index]
                if tile_index == 0 {
                    continue
                }

                tile_count += 1

                tileset_index := tile_index - game_map.first_gid

                tileset_col := tileset_index % game_map.tileset_columns

                total_rows := (game_map.tileset_tile_count + game_map.tileset_columns - 1) / game_map.tileset_columns

                tileset_row := total_rows - 1 - (tileset_index / game_map.tileset_columns)

                tileset_img := images[game_map.tileset_image_id]
                atlas_uvs := tileset_img.atlas_uvs
                img_width := f32(tileset_img.width)
                img_height := f32(tileset_img.height)

                tile_width_rel := f32(game_map.tileset_tile_width) / img_width
                tile_height_rel := f32(game_map.tileset_tile_height) / img_height

                u1 := atlas_uvs.x + (atlas_uvs.z - atlas_uvs.x) * (f32(tileset_col) * tile_width_rel)
                v1 := atlas_uvs.y + (atlas_uvs.w - atlas_uvs.y) * (f32(tileset_row) * tile_height_rel)
                u2 := u1 + tile_width_rel * (atlas_uvs.z - atlas_uvs.x)
                v2 := v1 + tile_height_rel * (atlas_uvs.w - atlas_uvs.y)

                tile_pos := position + {
                    f32(x * game_map.render_width),
                    f32(y * game_map.render_height),
                }

                draw_rect_aabb(
                    tile_pos,
                    {f32(game_map.render_width), f32(game_map.render_height)},
                    uv = {u1, v1, u2, v2},
                    img_id = game_map.tileset_image_id,
                    z_layer = .background,
                )
            }
        }
    }
}

free_map :: proc() {
    game_map := &current_map

    if game_map.layers != nil {
        for layer in game_map.layers {
            delete(layer.name)
            delete(layer.data)
        }
        delete(game_map.layers)
        game_map.layers = nil
    }

    if game_map.tileset_collisions != nil {
        for _, shapes in game_map.tileset_collisions {
            for shape in shapes {
                if shape.points != nil {
                    delete(shape.points)
                }
            }
            delete(shapes)
        }
        delete(game_map.tileset_collisions)
        game_map.tileset_collisions = nil
    }

    game_map.loaded = false
}

load_tileset :: proc() -> bool {
    // Use relative path instead of absolute path
    tileset_path := "res/images/tiles/Overworld.png"

    png_data, succ := os.read_entire_file(tileset_path)
    if !succ {
        log_error("Failed to load tileset image:", tileset_path)
        return false
    }

    stbi.set_flip_vertically_on_load(1)
    width, height, channels: i32
    img_data := stbi.load_from_memory(raw_data(png_data), auto_cast len(png_data), &width, &height, &channels, 4)

    if img_data == nil {
        log_error("Failed to decode tileset image")
        return false
    }

    fmt.println("Loaded tileset:", width, "x", height, "pixels")

    img : Image
    img.width = width
    img.height = height
    img.data = img_data

    id := Image_Id.tileset_overworld
    images[id] = img

    if int(id) > image_count - 1 {
        image_count = int(id) + 1
    }

    return true
}

load_tileset_collisions :: proc(tsx_path: string) -> (map[int][]Collision_Shape, bool) {
    collisions := make(map[int][]Collision_Shape)

    tsx_data, ok := os.read_entire_file(tsx_path)
    if !ok {
        fmt.println("Failed to read tileset file:", tsx_path)
        return collisions, false
    }
    defer delete(tsx_data)

    data := string(tsx_data)

    tile_start := 0
    for {
        next_tile := strings.index(data[tile_start:], "<tile id=")
        if next_tile < 0 do break
        tile_start += next_tile

        id_start := tile_start + strings.index(data[tile_start:], "id=\"") + 4
        id_end := id_start + strings.index(data[id_start:], "\"")
        id_str := data[id_start:id_end]
        tile_id, parse_ok := strconv.parse_int(id_str)
        if !parse_ok do continue

        objectgroup_idx := strings.index(data[tile_start:], "<objectgroup")
        if objectgroup_idx < 0 {
            tile_start += 1
            continue
        }

        objectgroup_start := tile_start + objectgroup_idx
        tile_end_idx := strings.index(data[tile_start:], "</tile>")
        if tile_end_idx < 0 {
            tile_start += 1
            continue
        }

        tile_end := tile_start + tile_end_idx
        if objectgroup_start > tile_end {
            tile_start += 1
            continue
        }

        object_pos := objectgroup_start
        shapes := make([dynamic]Collision_Shape)

        for {
            object_idx := strings.index(data[object_pos:], "<object ")
            if object_idx < 0 do break

            object_pos += object_idx
            if object_pos > tile_end do break

            x_attr := parse_xml_attribute(data[object_pos:], "x")
            y_attr := parse_xml_attribute(data[object_pos:], "y")
            w_attr := parse_xml_attribute(data[object_pos:], "width")
            h_attr := parse_xml_attribute(data[object_pos:], "height")

            x, x_ok := strconv.parse_f32(x_attr)
            y, y_ok := strconv.parse_f32(y_attr)
            width, w_ok := strconv.parse_f32(w_attr)
            height, h_ok := strconv.parse_f32(h_attr)

            if !x_ok || !y_ok || !w_ok || !h_ok {
                object_pos += 1
                continue
            }

            shape_type := Shape_Type.Rectangle

            polygon_attr := parse_xml_attribute(data[object_pos:], "points")
            polygon_points: [dynamic]Vector2

            if polygon_attr != "" {
                shape_type = Shape_Type.Polygon

                point_pairs := strings.split(polygon_attr, " ")
                for pair in point_pairs {
                    coords := strings.split(pair, ",")
                    if len(coords) == 2 {
                        px, px_ok := strconv.parse_f32(coords[0])
                        py, py_ok := strconv.parse_f32(coords[1])
                        if px_ok && py_ok {
                            append(&polygon_points, Vector2{px, py})
                        }
                    }
                }
            }

            shape := Collision_Shape{
                shape_type = shape_type,
                x = x,
                y = y,
                width = width,
                height = height,
            }

            if shape_type == Shape_Type.Polygon {
                shape.points = make([]Vector2, len(polygon_points))
                for p, i in polygon_points {
                    shape.points[i] = p
                }
            }

            append(&shapes, shape)
            object_pos += 1
        }

        if len(shapes) > 0 {
            collisions[tile_id] = make([]Collision_Shape, len(shapes))
            for shape, i in shapes {
                collisions[tile_id][i] = shape
            }
        }

        delete(shapes)
        tile_start += 1
    }

    return collisions, true
}

parse_xml_attribute :: proc(xml: string, attr_name: string) -> string {
    attr_search := fmt.tprintf("%s=\"", attr_name)
    attr_idx := strings.index(xml, attr_search)
    if attr_idx < 0 do return ""

    attr_start := attr_idx + len(attr_search)
    attr_end_idx := strings.index(xml[attr_start:], "\"")
    if attr_end_idx < 0 do return ""

    return xml[attr_start:attr_start + attr_end_idx]
}

has_collision :: proc(tile_id: int) -> bool {
    game_map := &current_map

    if !game_map.loaded {
        return false
    }

    adjusted_id := tile_id - game_map.first_gid

    shapes, exists := game_map.tileset_collisions[adjusted_id]
    return exists && len(shapes) > 0
}

get_tile_collision_shapes :: proc(tile_id: int) -> []Collision_Shape {
    game_map := &current_map

    if !game_map.loaded {
        return nil
    }

    adjusted_id := tile_id - game_map.first_gid

    return game_map.tileset_collisions[adjusted_id]
}

is_tile_solid :: proc(x, y: int) -> bool {
    tile_id := get_tile_at(x, y)
    return has_collision(tile_id)
}

//
// :player

init_player :: proc() -> Entity_Handle {
    player := entity_create()
    if player == nil {
        log_error("Failed to create player entity")
        return {}
    }

    player.kind = .Player

    player.pos = v2{5, 5}

    return entity_to_handle(player^)
}

render_player :: proc(map_pos: Vector2) {
    player := get_player()
    if player == nil {
        return
    }

    grid_pos := v2{
        map_pos.x + player.pos.x * f32(current_map.render_width),
        map_pos.y + player.pos.y * f32(current_map.render_height)
    }

    draw_sprite_with_size(
        grid_pos,
        v2{1, 1},
        .player,
        pivot = .bottom_left,
        z_layer = .player
    )
}