#+private file
package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:slice"
import rand "core:math/rand"
import rl "vendor:raylib"

// MARK: Consts

SPACING :: 1.0
COLOR_WEIGHTS :: rl.WHITE
COLOR_ACTIVATION :: rl.ORANGE
COLOR_GRAD :: rl.GREEN

// MARK: Globals

g_camera3d: rl.Camera3D
g_cam_angle: f32 = 0
g_img_input: MnistRecord
g_flags: Flags
g_thresholds: Thresholds
g_net: Net

// MARK: Structs

@private
Flags :: struct {
    cam_rotate: bool,
    draw_connections: bool,
    draw_cubes: bool,
    draw_cube_lines: bool,
    draw_node_activations: bool,
    draw_weight_cloud: bool,
    load_test_imgs: bool
}

@private
Thresholds :: struct {
    weight_cloud: f32,
    activations: f32,
    connections: f32
}

LayerViz :: struct {
    index: int,
    weights, grads, contribs: [][]f32,
    z_offset: f32,
    rows, columns, depth: int,
    grid_color: rl.Color,
}

Cube :: struct {
    pos: rl.Vector3,
    color: rl.Color,
    layer_index: int,
}

Line :: struct {
    start: rl.Vector3,
    end: rl.Vector3,
    color: rl.Color,
}

Cuboid :: struct {
    pos: rl.Vector3,
    size: rl.Vector3,
    color: rl.Color,
    is_activated: bool
}

Shape :: union {
    Cube,
    Line,
    Cuboid
}

SceneObject :: struct {
    shape: Shape,
    dist_to_cam: f32,
}

// MARK: Public

@private
viz_init :: proc() -> (err: bool) {
    // Raylib init
    rl.InitWindow(WINDOW_W, WINDOW_H, "NN")
    rl.SetWindowState(rl.ConfigFlags{.WINDOW_RESIZABLE})
    rl.SetTargetFPS(FPS)

    // Do not mem init the loaded net
    net_load(&g_net) or_return

    // Cam setup
    reset_cam()

    // Flag defaults
    g_flags.cam_rotate = true
    g_flags.draw_connections = true
    g_flags.draw_cubes = true
    g_flags.draw_cube_lines = true
    g_flags.load_test_imgs = true

    // Threshold defaults
    g_thresholds.activations = 25
    g_thresholds.connections = 25
    g_thresholds.weight_cloud = 50

    return false
}

@private
viz_deinit :: proc() {
    net_free(&g_net)
    rl.CloseWindow()
}

@private
is_viz_terminate :: proc() -> bool {
    return rl.WindowShouldClose()
}

@private
viz_update :: proc(test_img: ^MnistRecord) {

    // Update Viz components
    handle_keyboard_input()
    if g_flags.cam_rotate {
        g_cam_angle += CAM_REVOLUTION_SPEED * rl.GetFrameTime()
        g_camera3d.position.x = math.cos(g_cam_angle) * CAM_REVOLUTION_RADIUS
        g_camera3d.position.z = math.sin(g_cam_angle) * CAM_REVOLUTION_RADIUS
    } else {
        rl.UpdateCamera(&g_camera3d, .FREE)
    }
    if g_flags.load_test_imgs {
        g_img_input.pixels = test_img.pixels
    }

    // Init data for viz draw
    grad_net := Net{}
    contrib_net := Net{}
    net_init_mem(&grad_net, true)
    net_init_mem(&contrib_net, true)

    // Inference, calc grads and activations
    // TODO, don't run this every frame, run it only when necessary
    _, activations := net_backward(&g_net, &g_img_input, &grad_net, &contrib_net)
    preds := activations[len(activations) - 1][:]
    prediction_idx := get_prediction_index(preds)

    // Prepare data for viz
    for &layer in grad_net.layers {
        for &weights in layer.w {
            normalize_values(weights)
        }
    }

    // Draw
    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(rl.GetColor(BG_COLOR_DARK_BLUE))
    draw_3d(&activations, &grad_net, &contrib_net, prediction_idx)
    draw_2d(prediction_idx, preds)
}

reset_cam :: proc() {
    g_camera3d.position = {0, 30, 0}
    g_camera3d.target = {}
    g_camera3d.up = {0, 1, 0}
    g_camera3d.fovy = 75
    g_camera3d.projection = rl.CameraProjection.PERSPECTIVE
    g_cam_angle = 0
}

// MARK: Draw Root

draw_2d :: proc(pred_idx: int, preds: []f32) {
    PADDING :: 30
    GRAPH_HEIGHT :: 100

    pred_accuracy := preds[pred_idx]
    input_grid_width := i32(MNIST_IMG_SIZE * 8)
    input_grid_start_y := int(rl.GetRenderHeight() - input_grid_width - PADDING)

    show_gui(&g_flags, &g_thresholds, reset_cam)
    draw_bar_graph(preds, PADDING, i32(input_grid_start_y) - GRAPH_HEIGHT, input_grid_width + PADDING, GRAPH_HEIGHT)
    draw_2d_image_input_grid(PADDING, input_grid_start_y)
    rl.DrawFPS(rl.GetRenderWidth() - 100, PADDING)
}

draw_3d :: proc(activations: ^[][]f32, grads, contribs: ^Net, prediction_idx: int) {
    rl.BeginMode3D(g_camera3d)
    defer rl.EndMode3D()

    // Shapes for the draw calls
    shapes := make([dynamic]Shape, context.temp_allocator)
    objs := make([dynamic]SceneObject, context.temp_allocator)

    // Init drawable objects
    collect_3d_shapes(&shapes, grads, contribs, activations, prediction_idx)

    // Calc distance from cam to object
    for shape in shapes {
        shape_pos: rl.Vector3
        scale_factor: f32 = 1
        switch s in shape {
            case Cube:
                shape_pos = s.pos
                // This helps draw the cube over the line when rendering
                scale_factor = 2.5
            case Cuboid:
                shape_pos = s.pos
                scale_factor = 1.5
            case Line:
                // Mid-point of the line
                shape_pos = (s.start + s.end)/2
        }

        // Create scene objects based on thier distance to the camera
        append(&objs, SceneObject {
            shape = shape,
            dist_to_cam = calc_vec3_dist_squared(shape_pos, g_camera3d.position) * scale_factor
        })
    }

    // Sort objects so that things farther from the camera are drawn first
    // This helps fix the alpha blending issues,
    slice.sort_by_cmp(objs[:], compare_scene_objects)

    // Render objects, depth sorted
    for obj in objs {
        switch shape in obj.shape {
            case Cube:
                if g_flags.draw_cubes {
                    rl.DrawCube(shape.pos, SPACING, SPACING, SPACING, shape.color)
                }
            case Line:
                rl.DrawLine3D(shape.start, shape.end, shape.color)
            case Cuboid:
                rl.DrawCubeWiresV(shape.pos, shape.size, shape.color)
                if g_flags.draw_cubes && shape.is_activated {
                    block_color := rl.ColorAlpha(rl.WHITE, 0.5)
                    rl.DrawCubeV(shape.pos, shape.size, block_color)
                }
        }
    }
}

// MARK: !! 3D !!

collect_3d_shapes :: proc(shapes: ^[dynamic]Shape, grads, contribs: ^Net, activations: ^[][]f32, prediction_idx: int) {
    z_offset: f32 = -40.0

    // Input layer
    // TODO: adjust z offset based on number of layers and layer lengths?
    collect_layer_shapes(&LayerViz {
        index = 0,
        weights = { g_img_input.pixels[:] },
        grads = { g_img_input.pixels[:] },
        contribs = { g_img_input.pixels[:] },
        grid_color = rl.ColorAlpha(rl.SKYBLUE, 0.3),
        rows = MNIST_IMG_SIZE,
        columns = MNIST_IMG_SIZE,
        depth = 1,
        z_offset = z_offset
    }, shapes, {})

    num_inputs := MNIST_IMG_SIZE
    for i in 0..<len(g_net.layers) {
        z_offset += 10
        weights := g_net.layers[i].w
        grads := grads.layers[i].w
        contrib := contribs.layers[i].w
        activation := activations[i + 1]
        num_nodes := len(weights)
        grid_color := rl.WHITE

        // 1st hidden layer needs a depth viz
        if i == 0 {
            collect_layer_shapes(&LayerViz {
                index = i + 1,
                weights = weights,
                grads = grads,
                contribs = contrib,
                grid_color = rl.ColorAlpha(rl.GRAY, 0.05),
                rows = MNIST_IMG_SIZE,
                columns = MNIST_IMG_SIZE,
                depth = num_nodes,
                z_offset = z_offset
            }, shapes, activation)
            z_offset += f32(num_nodes)
            num_inputs = num_nodes
            continue
        }

        // Other hidden layers are single depth
        // Number of rows = number of nodes
        // Number of columns = number of inputs
        collect_layer_shapes(&LayerViz {
            index = i + 1,
            weights = weights,
            grads = grads,
            contribs = contrib,
            grid_color = rl.ColorAlpha(grid_color, 0.1),
            rows = num_nodes,
            columns = num_inputs,
            depth = 1,
            z_offset = z_offset,
        }, shapes, activation)

        // Number of inputs to the next layer equals 
        // Number of nodes in the current layer
        num_inputs = num_nodes
    }

    // Connection lines
    collect_layer_connection_lines(shapes, prediction_idx)
    // Output Layer
    collect_output_layer_shapes(shapes, prediction_idx)
}

collect_layer_shapes :: proc(layer: ^LayerViz, shapes: ^[dynamic]Shape, activation: []f32) {
    z_offset := layer.z_offset
    half_col := f32(layer.columns) / 2.0
    half_row := f32(layer.rows) / 2.0
    viz_depth := f32(layer.depth + 1)

    // A layer has weight cubes, weight cube lines, activations lines and connection lines
    collect_layer_weight_cubes(layer, shapes)
    collect_layer_cube_lines(layer, shapes)
    collect_node_activation_lines(layer, shapes, activation)
    // Connection lines can be initialized after all the cubes have been drawn
}

collect_layer_cube_lines :: proc(layer: ^LayerViz, shapes: ^[dynamic]Shape) {
    z_offset := layer.z_offset
    half_col := f32(layer.columns) / 2.0
    half_row := f32(layer.rows) / 2.0
    viz_depth := f32(layer.depth + 1)

    if !g_flags.draw_cube_lines {
        return
    }

    // Depth lines
    for i := -half_col; i <= half_col; i += SPACING {
        for j := -half_row; j <= half_row; j += SPACING {
            append(shapes, Line { 
                start={ i, j, z_offset }, 
                end={ i, j, (SPACING * f32(layer.depth)) + z_offset },
                color=layer.grid_color
            })
        }
    }
    // Horizontal lines
    for i := -half_row; i <= half_row; i += SPACING {
        for j := f32(0); j < viz_depth; j += SPACING {
            append(shapes, Line { 
                start={ -half_col, i, j + z_offset }, 
                end={ half_col, i, j + z_offset },
                color=layer.grid_color
            })
        }
    }
    // Vertical lines
    for i := -half_col; i <= half_col; i += SPACING {
        for j := f32(0); j < viz_depth; j += SPACING {
            append(shapes, Line { 
                start={ i, half_row, j + z_offset }, 
                end={ i, -half_row, j + z_offset },
                color=layer.grid_color
            })
        }
    }
}

collect_node_activation_lines :: proc(layer: ^LayerViz, shapes: ^[dynamic]Shape, activation: []f32) {
    z_offset := layer.z_offset
    half_col := f32(layer.columns) / 2.0
    half_row := f32(layer.rows) / 2.0

    if !g_flags.draw_node_activations {
        return
    }

    // Show activated node
    grid_color := rl.ColorAlpha(rl.WHITE, 0.3)
    if layer.index == 1 {
        for value, i in activation {
            if value > 0 {
                z := (SPACING * f32(layer.depth)) + z_offset - SPACING/2 - f32(i)
                append(shapes, Cuboid {
                    pos = {0, 0, z},
                    size = {half_row * 2, half_col * 2, 1},
                    color = grid_color
                })
            }
        }
    } else {
        z := z_offset + SPACING/2
        for value, i in activation {
            if value > 0 {
                y := SPACING - 0.5 + f32(i) - half_row
                append(shapes, Cuboid {
                    pos = {0, y, z},
                    size = {f32(layer.columns), 1, 1},
                    color = grid_color
                })
            }
        }
    }
}

collect_layer_connection_lines :: proc(shapes: ^[dynamic]Shape, prediction_idx: int) {
    if !g_flags.draw_connections {
        return
    }

    // TODO build this map instead of the cubes array
    cubes_map := make(map[int][dynamic]Cube, allocator = context.temp_allocator)

    for shape in shapes {
        if cube, ok := shape.(Cube); ok {
            if ok := cube.layer_index in cubes_map; !ok {
                cubes_map[cube.layer_index] = make([dynamic]Cube, context.temp_allocator)
            }
            if cube.color.r == COLOR_ACTIVATION.r && 
                cube.color.g == COLOR_ACTIVATION.g && 
                cube.color.b == COLOR_ACTIVATION.b {
                append(&cubes_map[cube.layer_index], cube)
            }
        }
    }

    lines_threshold := 255 - map_threshold_value(g_thresholds.connections, 0, 255)
    // Connection lines for the hidden layers
    for layer_index, layer_cubes in cubes_map {
        if layer_index + 1 not_in cubes_map {
            continue
        }

        next_layer_cubes := cubes_map[layer_index + 1]
        for cube in layer_cubes {
            for next_cube in next_layer_cubes {
                line := Line {
                    start = cube.pos,
                    end = next_cube.pos,
                    color = rl.ColorAlpha(rl.GRAY, 0.1),
                }

                threshold := lines_threshold if layer_index != 1 else lines_threshold - 50
                if cube.color.a > u8(threshold) {
                    append(shapes, line)
                }
            }
        }
    }

    // Connection between last hidden layer to the output layer
    // TODO output layer positions are hardcoded/repeated
    horizontal_spacing: f32 = 6.0
    start_x := - (f32((MNIST_NUM_LABELS - 1)) * horizontal_spacing) / 2
    ret := rl.Vector3{f32(start_x + f32(prediction_idx) * horizontal_spacing), 0, 40}
    if cubes, ok := cubes_map[len(cubes_map) - 1]; ok {
        for cube in cubes {
            line := Line {
                start = cube.pos,
                end = ret,
                color = rl.ColorAlpha(rl.WHITE, 0.1),
            }
            append(shapes, line)
        }
    }
}

collect_layer_weight_cubes :: proc(layer: ^LayerViz, shapes: ^[dynamic]Shape) {
    half_col := f32(layer.columns) / 2.0
    half_row := f32(layer.rows) / 2.0

    // depth 1: each row is a node, column is an input weight
    // depth n: each depth is a node, row*column are input weights
    // depth n scheme is used for the input layer and the 1st hidden layer
    is_depth_scheme := layer.index == 0 || layer.index == 1
    is_final_layer := layer.index == len(g_net.layers) + 1

    get_indices :: proc(is_depth_scheme: bool, d, x, y, rows: int) -> (row_idx, index: int) {
        if is_depth_scheme {
            return d, y * rows + x
        }
        return y, x
    }

    get_cube_pos :: proc(x, y: int, half_col, half_row: f32, z_offset: f32, depth: int = 0) -> rl.Vector3 {
        return rl.Vector3 {
            f32(x) - half_col + SPACING/2,
            half_row - f32(y) - SPACING/2,
            z_offset + SPACING/2 + f32(depth),
        }
    }

    // thresholds
    weight_cloud_threshold := 1.0 - map_threshold_value(g_thresholds.weight_cloud, 0.6, 0.9)
    activation_threshold := 1.0 - map_threshold_value(g_thresholds.activations, 0.7, 1.0)

    for d := 0; d < layer.depth; d += 1 {
        for i := 0; i < layer.columns; i += 1 {
            for j := 0; j < layer.rows; j += 1 {
                row_idx, index := get_indices(is_depth_scheme, d, i, j, layer.rows)
                weight := layer.weights[row_idx][index]
                grad := layer.grads[row_idx][index]
                contrib := layer.contribs[row_idx][index]
                cube_pos := get_cube_pos(i, j, half_col, half_row, layer.z_offset, d)
                color := rl.ColorAlpha(COLOR_WEIGHTS, weight)

                // Input layer
                if layer.index == 0 && weight > 0 {
                    hidden_layer_pos := get_cube_pos(i, j, half_col, half_row, layer.z_offset, 13)
                    append(shapes, Cube { pos=cube_pos, color=color, layer_index=0 })
                    // TODO put this in the draw connections proc
                    if g_flags.draw_connections {
                        append(shapes, Line { start=cube_pos, end=hidden_layer_pos, color=rl.ColorAlpha(rl.GRAY, 0.3) })
                    }
                    continue
                }

                // 1st hidden layer
                if layer.index == 1 {
                    if grad > 0.0 && contrib > activation_threshold - 0.1 {
                        append(shapes, Cube { 
                            pos=cube_pos, color=rl.ColorAlpha(COLOR_ACTIVATION, contrib + 0.1), layer_index=1 
                        })
                        // continue
                    }
                    if grad > 0.0 && weight > 0.1 {
                        color := rl.ColorAlpha(COLOR_GRAD, grad + 0.2)
                        append(shapes, Cube { pos=cube_pos, color=color, layer_index=1 })
                        // continue
                    } 
                    if weight > weight_cloud_threshold && g_flags.draw_weight_cloud {
                        color := rl.ColorAlpha(COLOR_WEIGHTS, weight)
                        append(shapes, Cube { pos=cube_pos, color=color, layer_index=1 })
                    }
                    continue
                }

                if contrib > activation_threshold {
                    color := rl.ColorAlpha(COLOR_ACTIVATION, contrib - 0.5)
                    append(shapes, Cube { pos=cube_pos, color=color, layer_index=layer.index })
                    continue
                }
                if grad > 0.0 {
                    color := rl.ColorAlpha(COLOR_GRAD, grad + 0.2)
                    append(shapes, Cube { pos=cube_pos, color=color, layer_index=layer.index })
                    continue
                }
                if weight > weight_cloud_threshold && g_flags.draw_weight_cloud {
                    color := rl.ColorAlpha(COLOR_WEIGHTS, weight)
                    append(shapes, Cube { pos=cube_pos, color=color, layer_index=layer.index })
                }
            }
        }
    }
}

collect_output_layer_shapes :: proc(shapes: ^[dynamic]Shape, prediction_idx: int) {
    horizontal_spacing: f32 = 6.0
    start_x := -f32(MNIST_NUM_LABELS - 1) * horizontal_spacing / 2

    for i in 0..<MNIST_NUM_LABELS {
        x := start_x + f32(i) * horizontal_spacing
        is_activated := i == prediction_idx && g_flags.draw_cubes
        should_draw := g_flags.draw_cube_lines || is_activated

        if should_draw {
            append(shapes, Cuboid {
                pos = {x, 0, 40},
                size = {3, 5, 1},
                color = rl.BEIGE,
                is_activated = is_activated,
            })
        }
    }
}

// MARK: !! 2D !!

draw_2d_image_input_grid :: proc(x_offset: int, y_offset: int) {
    LINES_COLOR :: rl.GRAY
    BLOCK_COLOR :: rl.WHITE
    BRUSH_SIZE :: 2
    BLOCK_SIZE :: 8
    GRID_SIZE :: MNIST_IMG_SIZE
    DRAW_PIXEL_VAL :: 1.0

    // Filled tiles
    for i in 0..<GRID_SIZE {
        for j in 0..<GRID_SIZE {
            pos := (j * GRID_SIZE) + i
            if g_img_input.pixels[pos] > 0 {
                x := (i * BLOCK_SIZE) + x_offset
                y := (j * BLOCK_SIZE) + y_offset
                color := rl.ColorAlpha(BLOCK_COLOR, g_img_input.pixels[pos])
                rl.DrawRectangle(i32(x), i32(y), BLOCK_SIZE, BLOCK_SIZE, color)
            }
        }
    }

    // Empty grid
    for i in 0..=MNIST_IMG_SIZE {
        x := (i * BLOCK_SIZE) + x_offset
        y := y_offset
        rl.DrawLine(i32(x), i32(y), i32(x), i32(y + (GRID_SIZE * BLOCK_SIZE)), LINES_COLOR)
    }
    for j in 0..=MNIST_IMG_SIZE {
        y := (j * BLOCK_SIZE) + y_offset
        x := x_offset
        rl.DrawLine(i32(x), i32(y), i32(x + (GRID_SIZE * BLOCK_SIZE)), i32(y), LINES_COLOR)
    }

    // Handle mouse events
    if rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.RIGHT) {
        mouse_pos := rl.GetMousePosition()
        grid_val := true if rl.IsMouseButtonDown(.LEFT) else false
        grid_x := int((mouse_pos.x - f32(x_offset)) / f32(BLOCK_SIZE))
        grid_y := int((mouse_pos.y - f32(y_offset)) / f32(BLOCK_SIZE))
        
        // Gradients
        // Increase the brush size for gradients
        // TODO this code could be made simpler
        GRADIENT_BRUSH_SIZE :: BRUSH_SIZE + 1
        CENTER_VAL :: DRAW_PIXEL_VAL
        INNER_VAL :: DRAW_PIXEL_VAL * 0.85
        OUTER_VAL :: DRAW_PIXEL_VAL * 0.15
        
        for dy in -GRADIENT_BRUSH_SIZE/2..<GRADIENT_BRUSH_SIZE/2 {
            for dx in -GRADIENT_BRUSH_SIZE/2..<GRADIENT_BRUSH_SIZE/2 {
                brush_x := grid_x + dx
                brush_y := grid_y + dy
                if brush_x >= 0 && brush_x < GRID_SIZE && brush_y >= 0 && brush_y < GRID_SIZE {
                    pos := (brush_y * GRID_SIZE) + brush_x
                    
                    // Calculate the distance from the center of the brush
                    distance := math.sqrt(f32(dx*dx + dy*dy))
                    
                    pixel_value: f32
                    if distance < 1 {
                        pixel_value = CENTER_VAL
                    } else if distance < 2 {
                        pixel_value = INNER_VAL
                    } else if distance < 3 {
                        pixel_value = OUTER_VAL
                    }
                    
                    if grid_val {
                        g_img_input.pixels[pos] = max(g_img_input.pixels[pos], pixel_value)
                    } else {
                        g_img_input.pixels[pos] = 0.0
                    }
                }
            }
        }
    }
}

draw_bar_graph :: proc(values: []f32, x_offset, y_offset, graph_width, graph_height: i32) {
    assert(len(values) == 10, "Expected 10 values in the array")

    // Leave some space on the sides
    bar_width: i32 = 20
    spacing: i32 = 1
    max_height := graph_height - 50 

    for i := 0; i < len(values); i += 1 {
        height := i32(values[i] * f32(max_height))
        x := x_offset + i32(spacing + i32(i) * (bar_width + spacing))
        y := y_offset + graph_height - height - 30

        rl.DrawRectangle(x, y, bar_width, height, rl.WHITE)

        // Draw the value on top of each bar
        value_text := rl.TextFormat("%d", i32(values[i] * 100))
        text_width := rl.MeasureText(value_text, 20)
        rl.DrawText(value_text, x + bar_width/2 - text_width/2, y - 25, 20, rl.WHITE)

        // Draw the index below the bar
        index_text := rl.TextFormat("%d", i)
        index_text_width := rl.MeasureText(index_text, 20)
        rl.DrawText(index_text, x + bar_width/2 - index_text_width/2, y_offset + graph_height - 25, 20, rl.WHITE)
    }
}

// MARK: Inputs

handle_keyboard_input :: proc() {
    if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
        g_flags.cam_rotate = !g_flags.cam_rotate
    }
    if rl.IsKeyPressed(rl.KeyboardKey.TAB) {
        g_flags.draw_connections = !g_flags.draw_connections
    }
    if rl.IsKeyPressed(rl.KeyboardKey.R) {
        g_img_input = {}
    }
}

// MARK: Utils

normalize_values :: proc(values: []f32) {
    sum_val: f32 = 0
    for i in values {
        sum_val += i
    }

    for &i in values {
        i = i / sum_val
    }
}

calc_vec3_dist_squared :: proc(a, b: rl.Vector3) -> f32 {
    dx := a.x - b.x
    dy := a.y - b.y
    dz := a.z - b.z

    return dx*dx + dy*dy + dz*dz
}

// Maps a value from the range [0.0, 100.0] to the new range [x, y]
map_threshold_value :: proc(value, x, y: f32) -> f32 {
    return x + ((value / 100.0) * (y - x))
}

compare_scene_objects :: proc(a, b: SceneObject) -> slice.Ordering {
    if a.dist_to_cam > b.dist_to_cam do return .Less
    if a.dist_to_cam < b.dist_to_cam do return .Greater
    return .Equal
}
