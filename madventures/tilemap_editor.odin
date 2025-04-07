package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:encoding/json"
import "core:math"
import "core:math/linalg"

import "core:strconv"

Tile_Type :: enum {
    Empty,
    Floor,
    Wall,
    Obstacle,
    Item,
    Enemy_Spawn,
    Player_Spawn,
    Exit,
    // Add more types as needed
}

Tile_Metadata :: struct {
    int_values: map[string]int,
    bool_values: map[string]bool,
    string_values: map[string]string,
}

Tile :: struct {
    type: Tile_Type,
    img_id: Image_Id,
    walkable: bool,
    metadata: Tile_Metadata,
}

Tile_Map :: struct {
    width, height: int,
    tile_size: int,
    tiles: [dynamic]Tile,
    layers: [dynamic]Tile_Layer,
    active_layer: int,
}

Tile_Layer :: struct {
    name: string,
    visible: bool,
    tiles: [dynamic]Tile,
}

Editor_Mode :: enum {
    Place,
    Select,
    Erase,
    Properties,
}

Editor_State :: struct {
    tilemap: Tile_Map,
    current_mode: Editor_Mode,
    current_tile_type: Tile_Type,
    brush_size: int,
    show_grid: bool,
    grid_color: Vector4,
    camera_offset: Vector2,
    camera_zoom: f32,
    selected_tile_x, selected_tile_y: int,
    has_selection: bool,
    drag_start_x, drag_start_y: int,
    is_dragging: bool,
    property_panel_open: bool,
    unsaved_changes: bool,
}

editor: Editor_State

init_tile_map_editor :: proc() {
    editor = Editor_State{
        current_mode = .Place,
        current_tile_type = .Floor,
        brush_size = 1,
        show_grid = true,
        grid_color = {0.3, 0.3, 0.3, 0.5},
        camera_zoom = 1.0,
        camera_offset = {0, 0},
    }

    create_new_map(20, 15, 32)
}

create_new_map :: proc(width, height, tile_size: int) {
    editor.tilemap = Tile_Map{
        width = width,
        height = height,
        tile_size = tile_size,
    }

    resize(&editor.tilemap.tiles, width * height)

    for i in 0..<len(editor.tilemap.tiles) {
        editor.tilemap.tiles[i] = Tile{
            type = .Empty,
            walkable = true,
            metadata = Tile_Metadata{
                int_values = make(map[string]int),
                bool_values = make(map[string]bool),
                string_values = make(map[string]string),
            },
        }
    }

    append(&editor.tilemap.layers, Tile_Layer{
        name = "Base",
        visible = true,
        tiles = editor.tilemap.tiles,
    })

    editor.tilemap.active_layer = 0
    editor.unsaved_changes = false
}

map_to_screen :: proc(map_pos: Vector2) -> Vector2 {
    screen_x := map_pos.x * f32(editor.tilemap.tile_size) * editor.camera_zoom + editor.camera_offset.x
    screen_y := map_pos.y * f32(editor.tilemap.tile_size) * editor.camera_zoom + editor.camera_offset.y
    return {screen_x, screen_y}
}

screen_to_map :: proc(screen_pos: Vector2) -> Vector2 {
    map_x := (screen_pos.x - editor.camera_offset.x) / (f32(editor.tilemap.tile_size) * editor.camera_zoom)
    map_y := (screen_pos.y - editor.camera_offset.y) / (f32(editor.tilemap.tile_size) * editor.camera_zoom)
    return {map_x, map_y}
}

get_tile_index :: proc(x, y: int) -> int {
    if x < 0 || x >= editor.tilemap.width || y < 0 || y >= editor.tilemap.height {
        return -1
    }
    return y * editor.tilemap.width + x
}

get_tile :: proc(x, y: int) -> ^Tile {
    idx := get_tile_index(x, y)
    if idx == -1 {
        return nil
    }
    return &editor.tilemap.tiles[idx]
}

set_tile :: proc(x, y: int, tile: Tile) {
    idx := get_tile_index(x, y)
    if idx == -1 {
        return
    }
    editor.tilemap.tiles[idx] = tile
    editor.unsaved_changes = true
}

update_editor :: proc(dt: f64) {
    if key_down(.MIDDLE_MOUSE) {
        mouse_delta_x := app_state.input_state.mouse_x - app_state.input_state.prev_mouse_x
        mouse_delta_y := app_state.input_state.mouse_y - app_state.input_state.prev_mouse_y
        editor.camera_offset.x += mouse_delta_x
        editor.camera_offset.y += mouse_delta_y
    }

    if app_state.input_state.wheel_delta_y != 0 {
        zoom_speed := 0.1
        old_zoom := editor.camera_zoom

        if app_state.input_state.wheel_delta_y > 0 {
            editor.camera_zoom *= 1.0 + auto_cast zoom_speed
        } else if app_state.input_state.wheel_delta_y < 0 {
            editor.camera_zoom /= 1.0 + auto_cast zoom_speed
        }

        editor.camera_zoom = clamp(editor.camera_zoom, 0.1, 5.0)

        mouse_pos := v2{app_state.input_state.mouse_x, app_state.input_state.mouse_y}
        mouse_map_pos := screen_to_map(mouse_pos)

        editor.camera_offset.x = mouse_pos.x - mouse_map_pos.x * f32(editor.tilemap.tile_size) * editor.camera_zoom
        editor.camera_offset.y = mouse_pos.y - mouse_map_pos.y * f32(editor.tilemap.tile_size) * editor.camera_zoom
    }

    mouse_pos := v2{app_state.input_state.mouse_x, app_state.input_state.mouse_y}
    map_pos := screen_to_map(mouse_pos)
    tile_x := int(map_pos.x)
    tile_y := int(map_pos.y)

    switch editor.current_mode {
        case .Place:
            if key_down(.LEFT_MOUSE) && !editor.property_panel_open {
                half_brush := editor.brush_size / 2
                for y in -half_brush..=half_brush {
                    for x in -half_brush..=half_brush {
                        new_tile := Tile{
                            type = editor.current_tile_type,
                            walkable = editor.current_tile_type != .Wall && editor.current_tile_type != .Obstacle,
                            metadata = Tile_Metadata{
                                int_values = make(map[string]int),
                                bool_values = make(map[string]bool),
                                string_values = make(map[string]string),
                            },
                        }

                        #partial switch editor.current_tile_type {
                            case .Floor: new_tile.img_id = .midground
                            case .Wall, .Obstacle: new_tile.img_id = .foreground
                            case .Enemy_Spawn, .Player_Spawn, .Exit: new_tile.img_id = .background
                            case: new_tile.img_id = .nil
                        }

                        set_tile(tile_x + x, tile_y + y, new_tile)
                    }
                }
            }

        case .Erase:
            if key_down(.LEFT_MOUSE) && !editor.property_panel_open {
                half_brush := editor.brush_size / 2
                for y in -half_brush..=half_brush {
                    for x in -half_brush..=half_brush {
                        empty_tile := Tile{
                            type = .Empty,
                            walkable = true,
                            metadata = Tile_Metadata{
                                int_values = make(map[string]int),
                                bool_values = make(map[string]bool),
                                string_values = make(map[string]string),
                            },
                        }
                        set_tile(tile_x + x, tile_y + y, empty_tile)
                    }
                }
            }

        case .Select:
            if key_just_pressed(.LEFT_MOUSE) && !editor.property_panel_open {
                editor.has_selection = true
                editor.selected_tile_x = tile_x
                editor.selected_tile_y = tile_y

                editor.drag_start_x = tile_x
                editor.drag_start_y = tile_y
                editor.is_dragging = true
            }

            if key_just_released(.LEFT_MOUSE) {
                editor.is_dragging = false
            }

            if editor.is_dragging {
                editor.selected_tile_x = tile_x
                editor.selected_tile_y = tile_y
            }

        case .Properties:
            if key_just_pressed(.LEFT_MOUSE) && !editor.property_panel_open {
                editor.has_selection = true
                editor.selected_tile_x = tile_x
                editor.selected_tile_y = tile_y
                editor.property_panel_open = true
            }
    }

    if key_just_pressed(.G) {
        editor.show_grid = !editor.show_grid
    }

    if key_just_pressed(.LEFT_BRACKET) {
        editor.brush_size = max(1, editor.brush_size - 1)
    }
    if key_just_pressed(.RIGHT_BRACKET) {
        editor.brush_size = min(10, editor.brush_size + 1)
    }

    if key_just_pressed(._1) {
        editor.current_mode = .Place
    }
    if key_just_pressed(._2) {
        editor.current_mode = .Select
    }
    if key_just_pressed(._3) {
        editor.current_mode = .Erase
    }
    if key_just_pressed(._4) {
        editor.current_mode = .Properties
    }

    if key_just_pressed(.F) {
        editor.current_tile_type = .Floor
    }
    if key_just_pressed(.W) {
        editor.current_tile_type = .Wall
    }
    if key_just_pressed(.O) {
        editor.current_tile_type = .Obstacle
    }
    if key_just_pressed(.P) {
        editor.current_tile_type = .Player_Spawn
    }
    if key_just_pressed(.E) {
        editor.current_tile_type = .Enemy_Spawn
    }
    if key_just_pressed(.X) {
        editor.current_tile_type = .Exit
    }

    ctrl_pressed := key_down(.LEFT_CONTROL) || key_down(.RIGHT_CONTROL)
    if ctrl_pressed && key_just_pressed(.S) {
        save_map("map.json")
    }
    if ctrl_pressed && key_just_pressed(.L) {
        load_map("map.json")
    }

    if ctrl_pressed && key_just_pressed(.N) {
        create_new_map(20, 15, 32)
    }
}

render_editor :: proc() {
    for y in 0..<editor.tilemap.height {
        for x in 0..<editor.tilemap.width {
            idx := get_tile_index(x, y)
            if idx == -1 {
                continue
            }

            tile := editor.tilemap.tiles[idx]

            if tile.type == .Empty {
                continue
            }

            tile_pos := map_to_screen({f32(x), f32(y)})
            tile_size := v2{f32(editor.tilemap.tile_size) * editor.camera_zoom, f32(editor.tilemap.tile_size) * editor.camera_zoom}

            tile_color := COLOR_WHITE
            #partial switch tile.type {
                case .Floor: tile_color = {0.7, 0.7, 0.7, 1.0}
                case .Wall: tile_color = {0.4, 0.4, 0.4, 1.0}
                case .Obstacle: tile_color = {0.6, 0.3, 0.3, 1.0}
                case .Item: tile_color = {0.9, 0.9, 0.2, 1.0}
                case .Enemy_Spawn: tile_color = {0.9, 0.2, 0.2, 1.0}
                case .Player_Spawn: tile_color = {0.2, 0.7, 0.9, 1.0}
                case .Exit: tile_color = {0.2, 0.9, 0.2, 1.0}
            }

            if tile.img_id != .nil {
                draw_rect_aabb(tile_pos, tile_size, col=tile_color, img_id=tile.img_id)
            } else {
                draw_rect_aabb(tile_pos, tile_size, col=tile_color)
            }

            #partial switch tile.type {
                case .Enemy_Spawn:
                    draw_text(tile_pos + tile_size * 0.5, "E", col=COLOR_BLACK, scale= 1.0 * auto_cast editor.camera_zoom, pivot=.center_center)
                case .Player_Spawn:
                    draw_text(tile_pos + tile_size * 0.5, "P", col=COLOR_BLACK, scale=1.0 * auto_cast editor.camera_zoom, pivot=.center_center)
                case .Exit:
                    draw_text(tile_pos + tile_size * 0.5, "X", col=COLOR_BLACK, scale=1.0 * auto_cast editor.camera_zoom, pivot=.center_center)
            }
        }
    }

    if editor.show_grid {
        for y in 0..=editor.tilemap.height {
            start_pos := map_to_screen({0, f32(y)})
            end_pos := map_to_screen({f32(editor.tilemap.width), f32(y)})
            draw_line(start_pos, end_pos, editor.grid_color)
        }

        for x in 0..=editor.tilemap.width {
            start_pos := map_to_screen({f32(x), 0})
            end_pos := map_to_screen({f32(x), f32(editor.tilemap.height)})
            draw_line(start_pos, end_pos, editor.grid_color)
        }
    }

    if editor.has_selection {
        selected_pos := map_to_screen({f32(editor.selected_tile_x), f32(editor.selected_tile_y)})
        selected_size := v2{f32(editor.tilemap.tile_size) * editor.camera_zoom, f32(editor.tilemap.tile_size) * editor.camera_zoom}
        draw_rect_outline(selected_pos, selected_size, {1.0, 1.0, 0.0, 1.0}, 2.0)
    }

    if editor.current_mode == .Place || editor.current_mode == .Erase {
        mouse_pos := v2{app_state.input_state.mouse_x, app_state.input_state.mouse_y}
        map_pos := screen_to_map(mouse_pos)
        tile_x := int(map_pos.x)
        tile_y := int(map_pos.y)

        half_brush := editor.brush_size / 2
        brush_start_x := tile_x - half_brush
        brush_start_y := tile_y - half_brush
        brush_width := editor.brush_size
        brush_height := editor.brush_size

        brush_screen_pos := map_to_screen({f32(brush_start_x), f32(brush_start_y)})
        brush_screen_size := v2{
            f32(brush_width) * f32(editor.tilemap.tile_size) * editor.camera_zoom,
            f32(brush_height) * f32(editor.tilemap.tile_size) * editor.camera_zoom,
        }

        brush_color := editor.current_mode == .Place ? Vector4{0.0, 1.0, 0.0, 0.3} : Vector4{1.0, 0.0, 0.0, 0.3}
        draw_rect_aabb(brush_screen_pos, brush_screen_size, col=brush_color)
    }

    ui_draw_editor_panel()

    if editor.property_panel_open {
        ui_draw_property_panel()
    }
}

ui_draw_editor_panel :: proc() {
    panel_width := 200
    panel_height := 400
    panel_x := 10
    panel_y := 10

    draw_rect_aabb({f32(panel_x), f32(panel_y)}, {f32(panel_width), f32(panel_height)}, col={0.2, 0.2, 0.2, 0.8})

    draw_text({f32(panel_x + 10), f32(panel_y + 10)}, "Tile Map Editor", col=COLOR_WHITE, scale=1.2)

    y_offset := 40

    draw_text({f32(panel_x + 10), f32(panel_y + y_offset)}, "Mode:", col=COLOR_WHITE)
    y_offset += 20

    mode_names := [Editor_Mode]string{
        .Place = "Place (1)",
        .Select = "Select (2)",
        .Erase = "Erase (3)",
        .Properties = "Properties (4)",
    }

    for mode, i in Editor_Mode {
        button_color := mode == editor.current_mode ? Vector4{0.4, 0.6, 0.8, 1.0} : Vector4{0.3, 0.3, 0.3, 1.0}
        if ui_button({f32(panel_x + 10), f32(panel_y + y_offset + i * 25)}, {f32(panel_width - 20), 20}, mode_names[mode], button_color) {
            editor.current_mode = mode
        }
    }

    y_offset += 110

    if editor.current_mode == .Place {
        draw_text({f32(panel_x + 10), f32(panel_y + y_offset)}, "Tile Type:", col=COLOR_WHITE)
        y_offset += 20

        tile_names := [Tile_Type]string{
            .Empty = "Empty",
            .Floor = "Floor (F)",
            .Wall = "Wall (W)",
            .Obstacle = "Obstacle (O)",
            .Item = "Item",
            .Enemy_Spawn = "Enemy Spawn (E)",
            .Player_Spawn = "Player Spawn (P)",
            .Exit = "Exit (X)",
        }

        for tile_type, i in Tile_Type {
            button_color := tile_type == editor.current_tile_type ? Vector4{0.4, 0.6, 0.8, 1.0} : Vector4{0.3, 0.3, 0.3, 1.0}
            if ui_button({f32(panel_x + 10), f32(panel_y + y_offset + i * 25)}, {f32(panel_width - 20), 20}, tile_names[tile_type], button_color) {
                editor.current_tile_type = tile_type
            }
        }
    }

    y_offset = 280

    if editor.current_mode == .Place || editor.current_mode == .Erase {
        draw_text({f32(panel_x + 10), f32(panel_y + y_offset)}, fmt.tprintf("Brush Size: %d", editor.brush_size), col=COLOR_WHITE)
        y_offset += 25

        if ui_button({f32(panel_x + 10), f32(panel_y + y_offset)}, {60, 20}, "Smaller [", {0.3, 0.3, 0.3, 1.0}) {
            editor.brush_size = max(1, editor.brush_size - 1)
        }

        if ui_button({f32(panel_x + 80), f32(panel_y + y_offset)}, {60, 20}, "Larger ]", {0.3, 0.3, 0.3, 1.0}) {
            editor.brush_size = min(10, editor.brush_size + 1)
        }

        y_offset += 30
    }

    draw_text({f32(panel_x + 10), f32(panel_y + y_offset)}, fmt.tprintf("Grid: %s (G)", editor.show_grid ? "On" : "Off"), col=COLOR_WHITE)
    y_offset += 25

    if ui_button({f32(panel_x + 10), f32(panel_y + y_offset)}, {85, 20}, "Save (Ctrl+S)", {0.3, 0.3, 0.3, 1.0}) {
        save_map("map.json")
    }

    if ui_button({f32(panel_x + 105), f32(panel_y + y_offset)}, {85, 20}, "Load (Ctrl+L)", {0.3, 0.3, 0.3, 1.0}) {
        load_map("map.json")
    }

    y_offset += 30

    if ui_button({f32(panel_x + 10), f32(panel_y + y_offset)}, {180, 20}, "New Map (Ctrl+N)", {0.3, 0.3, 0.3, 1.0}) {
        create_new_map(20, 15, 32)
    }
}

ui_draw_property_panel :: proc() {
    if !editor.has_selection {
        editor.property_panel_open = false
        return
    }

    tile := get_tile(editor.selected_tile_x, editor.selected_tile_y)
    if tile == nil {
        editor.property_panel_open = false
        return
    }

    panel_width := 250
    panel_height := 350
    panel_x := game_res_w - panel_width - 10
    panel_y := 10

    draw_rect_aabb({f32(panel_x), f32(panel_y)}, {f32(panel_width), f32(panel_height)}, col={0.2, 0.2, 0.2, 0.8})

    draw_text({f32(panel_x + 10), f32(panel_y + 10)}, "Tile Properties", col=COLOR_WHITE, scale=1.2)

    y_offset := 40

    draw_text(
        {f32(panel_x + 10), f32(panel_y + y_offset)},
        fmt.tprintf("Position: %d, %d", editor.selected_tile_x, editor.selected_tile_y),
        col=COLOR_WHITE
    )
    y_offset += 30

    draw_text({f32(panel_x + 10), f32(panel_y + y_offset)}, fmt.tprintf("Type: %v", tile.type), col=COLOR_WHITE)
    y_offset += 30

    walkable_text := fmt.tprintf("Walkable: %v", tile.walkable)
    if ui_button({f32(panel_x + 10), f32(panel_y + y_offset)}, {f32(panel_width - 20), 20}, walkable_text, tile.walkable ? Vector4{0.2, 0.7, 0.3, 1.0} : Vector4{0.7, 0.3, 0.2, 1.0}) {
        tile.walkable = !tile.walkable
        editor.unsaved_changes = true
    }
    y_offset += 30

    draw_text({f32(panel_x + 10), f32(panel_y + y_offset)}, "Metadata:", col=COLOR_WHITE)
    y_offset += 25

    for key, value in tile.metadata.int_values {
        draw_text(
            {f32(panel_x + 20), f32(panel_y + y_offset)},
            fmt.tprintf("%s: %d", key, value),
            col=COLOR_WHITE
        )
        y_offset += 20
    }

    for key, value in tile.metadata.bool_values {
        draw_text(
            {f32(panel_x + 20), f32(panel_y + y_offset)},
            fmt.tprintf("%s: %v", key, value),
            col=COLOR_WHITE
        )
        y_offset += 20
    }

    for key, value in tile.metadata.string_values {
        draw_text(
            {f32(panel_x + 20), f32(panel_y + y_offset)},
            fmt.tprintf("%s: %s", key, value),
            col=COLOR_WHITE
        )
        y_offset += 20
    }

    y_offset = max(y_offset, 200)

    if ui_button({f32(panel_x + 10), f32(panel_y + y_offset)}, {80, 20}, "Add Int", {0.3, 0.3, 0.3, 1.0}) {
        tile.metadata.int_values["custom_int"] = 0
        editor.unsaved_changes = true
    }

    if ui_button({f32(panel_x + 95), f32(panel_y + y_offset)}, {80, 20}, "Add Bool", {0.3, 0.3, 0.3, 1.0}) {
        tile.metadata.bool_values["custom_bool"] = false
        editor.unsaved_changes = true
    }

    if ui_button({f32(panel_x + 180), f32(panel_y + y_offset)}, {60, 20}, "Add Str", {0.3, 0.3, 0.3, 1.0}) {
        tile.metadata.string_values["custom_str"] = ""
        editor.unsaved_changes = true
    }

    y_offset += 30

    if ui_button({f32(panel_x + panel_width - 70), f32(panel_y + panel_height - 30)}, {60, 20}, "Close", {0.6, 0.2, 0.2, 1.0}) {
        editor.property_panel_open = false
    }
}

ui_button :: proc(pos: Vector2, size: Vector2, text: string, color: Vector4 = {0.3, 0.3, 0.3, 1.0}) -> bool {
    mouse_pos := v2{app_state.input_state.mouse_x, app_state.input_state.mouse_y}

    is_hover := mouse_pos.x >= pos.x && mouse_pos.x <= pos.x + size.x &&
                mouse_pos.y >= pos.y && mouse_pos.y <= pos.y + size.y

    button_color := is_hover ? Vector4{color.x + 0.1, color.y + 0.1, color.z + 0.1, color.w} : color
    draw_rect_aabb(pos, size, col=button_color)

    text_pos := pos + size * 0.5
    draw_text(text_pos, text, col=COLOR_WHITE, pivot=.center_center)

    return is_hover && key_just_pressed(.LEFT_MOUSE)
}

draw_line :: proc(start: Vector2, end: Vector2, color: Vector4 = COLOR_WHITE, thickness: f32 = 1.0) {
    dir := end - start
    length := linalg.length(dir)

    if length < 0.001 {
        return
    }

    normalized_dir := dir / length

    perp := v2{-normalized_dir.y, normalized_dir.x} * thickness * 0.5

    verts := [4]Vector2{
        start + perp,
        start - perp,
        end - perp,
        end + perp,
    }

    world_to_clip := draw_frame.coord_space.proj * draw_frame.coord_space.camera

    draw_quad_projected(
        world_to_clip,
        verts,
        {color, color, color, color},
        {{0,0}, {0,1}, {1,1}, {1,0}},
        {255, 255, 255, 255},
        {v4{0,0,0,0}, v4{0,0,0,0}, v4{0,0,0,0}, v4{0,0,0,0}}
    )
}

draw_rect_outline :: proc(pos: Vector2, size: Vector2, color: Vector4 = COLOR_WHITE, thickness: f32 = 1.0) {
    top_left := pos
    top_right := v2{pos.x + size.x, pos.y}
    bottom_left := v2{pos.x, pos.y + size.y}
    bottom_right := v2{pos.x + size.x, pos.y + size.y}

    draw_line(top_left, top_right, color, thickness)
    draw_line(top_right, bottom_right, color, thickness)
    draw_line(bottom_right, bottom_left, color, thickness)
    draw_line(bottom_left, top_left, color, thickness)
}

save_map :: proc(filename: string) {
    map_json := MapJson{
        width = editor.tilemap.width,
        height = editor.tilemap.height,
        tile_size = editor.tilemap.tile_size,
        tiles = make([dynamic]TileJson),
    }

    for y in 0..<editor.tilemap.height {
        for x in 0..<editor.tilemap.width {
            tile := get_tile(x, y)
            if tile == nil {
                continue
            }

            if tile.type != .Empty {
                tile_json := TileJson{
                    x = x,
                    y = y,
                    type = int(tile.type),
                    walkable = tile.walkable,
                    metadata_int = make([dynamic]MetadataEntryJson),
                    metadata_bool = make([dynamic]MetadataEntryJson),
                    metadata_string = make([dynamic]MetadataEntryJson),
                }

                for key, value in tile.metadata.int_values {
                    append(&tile_json.metadata_int, MetadataEntryJson{
                        key = key,
                        value = fmt.tprintf("%d", value),
                    })
                }

                for key, value in tile.metadata.bool_values {
                    append(&tile_json.metadata_bool, MetadataEntryJson{
                        key = key,
                        value = fmt.tprintf("%v", value),
                    })
                }

                for key, value in tile.metadata.string_values {
                    append(&tile_json.metadata_string, MetadataEntryJson{
                        key = key,
                        value = value,
                    })
                }

                append(&map_json.tiles, tile_json)
            }
        }
    }

    json_data, err := json.marshal(map_json)
    if err != nil {
        fmt.println("Error serializing map:", err)
        return
    }

    os.write_entire_file(filename, json_data)

    fmt.println("Map saved to", filename)
    editor.unsaved_changes = false
}

load_map :: proc(filename: string) {
    json_data, ok := os.read_entire_file(filename)
    if !ok {
        fmt.println("Error reading map file:", filename)
        return
    }

    map_json := MapJson{}
    err := json.unmarshal(json_data, &map_json)
    if err != nil {
        fmt.println("Error parsing map JSON:", err)
        return
    }

    create_new_map(map_json.width, map_json.height, map_json.tile_size)

    for tile_json in map_json.tiles {
        tile := Tile{
            type = Tile_Type(tile_json.type),
            walkable = tile_json.walkable,
            metadata = Tile_Metadata{
                int_values = make(map[string]int),
                bool_values = make(map[string]bool),
                string_values = make(map[string]string),
            },
        }

        for entry in tile_json.metadata_int {
            value, ok := strconv.parse_int(entry.value)
            if ok {
                tile.metadata.int_values[entry.key] = value
            }
        }

        for entry in tile_json.metadata_bool {
            if entry.value == "true" {
                tile.metadata.bool_values[entry.key] = true
            } else {
                tile.metadata.bool_values[entry.key] = false
            }
        }

        for entry in tile_json.metadata_string {
            tile.metadata.string_values[entry.key] = entry.value
        }

        #partial switch tile.type {
            case .Floor: tile.img_id = .midground
            case .Wall, .Obstacle: tile.img_id = .foreground
            case .Enemy_Spawn, .Player_Spawn, .Exit: tile.img_id = .background
            case: tile.img_id = .nil
        }

        set_tile(tile_json.x, tile_json.y, tile)
    }

    fmt.println("Map loaded from", filename)
    editor.unsaved_changes = false
}

MapJson :: struct {
    width, height, tile_size: int,
    tiles: [dynamic]TileJson,
}

TileJson :: struct {
    x, y, type: int,
    walkable: bool,
    metadata_int, metadata_bool, metadata_string: [dynamic]MetadataEntryJson,
}

MetadataEntryJson :: struct {
    key, value: string,
}