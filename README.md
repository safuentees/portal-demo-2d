# Metsl Starter

A ready-to-run macOS Metal project based on `metsl-macOS`, with a circular player, a translucent triangular field of view, and two blue bars representing future portal locations. The bars are visual markers only: there is no portal transfer, visibility, or collision behavior. The window, keyboard controls, GPU setup, and shaders are wired together; sphere geometry is also available for experiments.

## Version and repository

Current release: **v1.0.0** (app version 1.0.0, build 1). See `CHANGELOG.md` for release notes.

Clone the private repository while signed in with GitHub CLI:

```sh
gh repo clone safuentees/metsl-starter
cd metsl-starter
open MetslStarter.xcodeproj
```

Get future updates with `git pull --ff-only`. To use this exact starting point, run `git switch --detach v1.0.0`; create a branch with `git switch -c my-experiment` before making changes.

## Run

1. Open `MetslStarter.xcodeproj`.
2. Select the **MetslStarter** scheme and **My Mac**.
3. Press **Command-R**.

Click the scene to focus it. **W/A/S/D** moves the player and its view together: W up, A left, S down, D right. **Move the mouse or click to choose where to look.** The heading stays fixed while walking with a stationary mouse, so moving past the cursor no longer turns the player around. Mouse input very close to the player leaves the heading alone. Movement affects only x/y; depth and camera stay fixed. Releasing the keys or switching windows stops movement. Closing and reopening the window restores the configured scene.

The project uses SwiftUI, AppKit, MetalKit, Model I/O, and SIMD. There are no external packages or setup commands. It keeps the original macOS 14 minimum and Swift 5 language mode, uses the installed macOS SDK, and uses local ad hoc signing without an Apple development team.

## Start editing here

| Change | File |
| --- | --- |
| Object positions, sizes, colors, movement speed, and look dead zone; circle detail and canvas padding | `Sources/Scene/SceneConfiguration.swift` |
| Object IDs and the initial data for each scene object | `Sources/Scene/SceneObjectConfiguration.swift` |
| Position, scale, rotation angle, and model transform | `Sources/Scene/ObjectPlacement.swift` |
| Mesh, placement, and color for one rendered object | `Sources/Rendering/RenderObject.swift` |
| Vertex transforms or fragment color | `Sources/Shaders/Shaders.metal` |
| Render pipeline and drawing | `Sources/Rendering/Renderer.swift` |
| Shared 2D vertex layout and GPU buffer creation | `Sources/Rendering/Meshes/Mesh2D.swift` |
| Unit square vertices and triangle indices | `Sources/Rendering/Meshes/SquareMesh.swift` |
| Solid circle vertices and triangle indices | `Sources/Rendering/Meshes/CircleMesh.swift` |
| Triangle vertices used by the cone | `Sources/Rendering/Meshes/TriangleMesh.swift` |
| Optional sphere geometry and mesh detail | `Sources/Rendering/Meshes/SphereMesh.swift` |
| Camera state and movement | `Sources/Scene/Camera.swift` |
| Scale, rotation, translation, and square canvas fitting | `Sources/Scene/Transforms.swift` |
| Keyboard and mouse events/state | `Sources/Input/KeyboardMetalView.swift` |
| View setup, draw rate, renderer lifetime | `Sources/Views/MetalView.swift` |
| Window title and initial size | `Sources/App/MetslStarterApp.swift` |

Edit `SceneConfiguration.objects` to arrange the scene. Every entry creates one object; its ID, shape, placement, and color stay together:

```swift
SceneObjectConfiguration(
    id: .custom("rightPanel"),
    geometry: .square,
    placement: ObjectPlacement(
        position: SIMD3(0.45, 0, 0),
        scale: SIMD3(0.6, 0.3, 1)
    ),
    color: objectColor
)
```

Add or remove entries to change the object count. Use the named IDs `.bottomBar`, `.topBar`, `.circle`, and `.cone` for the existing objects. For new objects, add a case to `SceneObjectID` or use a unique `.custom("name")`. IDs identify individual objects, independently of their shape or array order; duplicate IDs cause a setup error. The renderer shares one mesh across all objects of the same shape, and changing one entry's placement does not affect the others. Placement defaults are position `(0, 0, 0)`, scale `(1, 1, 1)`, and angle `0` radians.

Edit the `.circle` entry to set the player's position and scale; `circleScale` is currently `0.05`, giving a 35-point diameter on the initial 700-point canvas. The circle mesh has radius 1, so scale `(1, 1, 1)` fills the canvas diameter and `(0.5, 0.5, 1)` makes it half as wide. Different x/y scales make an ellipse. `circleSegments` controls edge smoothness (64 by default). The mesh includes a center vertex and a ring of rim vertices; every adjacent pair on the rim forms a triangle with the center, including the closing pair. This fills the circle without a hole or an open seam.

The `.cone` uses the flat triangle mesh. `TriangleMesh.make` flips its vertices 180 degrees once around the center of their bounds, `(0, 0.5)`, before creating the GPU buffer. This preserves the local footprint (`x = -0.5...0.5`, `y = 0...1`) while exchanging the tip and flat end. The resulting tip is at `(0, 0)` and the flat-edge midpoint is at `(0, 1)`. Mouse aiming turns that flat end toward the cursor; WASD moves the cone and circle together.

`visionScale` is `(0.62, 0.50, 1)`: approximately 175 points of reach and a 64-degree field on the initial canvas. `visionColor` has alpha `0.18`; `playerColor` is a lighter opaque blue. The vision sits at depth `0.5` behind the solid player and thinner portal markers. These are rendering choices only, with no portal behavior.

With the camera at rest, `(0, 0)` is the center of an invisible square canvas, positive x goes right, and positive y goes up. Its edges are at `-1...1` on both axes. For the unit square mesh, scale `(1, 1, 1)` spans half the canvas width and height; `(0.5, 0.5, 1)` spans one quarter. Different x/y scales make rectangles. Object coordinates and proportions stay the same when the window changes shape.

`SceneConfiguration.canvasPadding` sets the minimum space around the canvas, currently **100 macOS points on every side**. Points keep the visual spacing consistent on Retina displays (100 points corresponds to 200 backing pixels at 2x). The starting content size is **900 × 900 points**: the original 700-point canvas plus padding. macOS may restore an existing window's size; resize it or open a new window to use the new dimensions.

The canvas side is `max(min(windowWidth, windowHeight) - 2 * padding, 0)`. It stays centered and square: a 900 × 1100 view has a 700 × 700 canvas with 100 points at left/right and 200 at top/bottom. Smaller windows scale the whole layout down uniformly. If there is no room after padding, the canvas collapses instead of flipping or dividing by zero. The canvas is a coordinate reference, not a clipping mask; objects intentionally placed beyond its edges can enter the surrounding space.

Keep `position.z = 0` and `scale.z = 1` for a simple flat layout. Depth does not change apparent size. For overlapping layers, smaller z values are closer; use values from 0 up to, but excluding, 1 with the current depth test. See [Apple's coordinate and viewport documentation](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Render-Ctx/Render-Ctx.html).

`SceneConfiguration.objectColor` supplies the initial RGBA color for each object. The fragment shader returns each object's color directly. Configuration supplies the starting values; the renderer owns the live `RenderObject` values after setup.

## Access an object during a frame

Use its ID in `Renderer.updateScene()` to change position, size, angle, or color:

```swift
updateObject(.topBar) { object in
    object.placement.position.x = 0.4
    object.placement.scale.x = 0.6
    object.placement.angle = .pi / 4 // 45 degrees counterclockwise.
}
```

`updateObject` finds the ID, gives your closure an editable value with `inout`, and saves the result back into the scene. The closure can also read other objects by ID. It returns `false` if the ID is absent. Use `object(withID: .topBar)` to read its current state; that returns an optional copy because `RenderObject` is a struct. Editing that copy on its own will not change the scene. Each object's model matrix is computed from its current placement.

`ObjectPlacement` stores an angle in radians. `Transforms.rotation(angle)` builds the matrix, and `ObjectPlacement.modelMatrix` combines `scale * rotation * translation`. Set `placement.angle` to change orientation; the computed `RenderObject.modelMatrix` remains read-only. Positive angles rotate counterclockwise around the local origin. Scale and rotation happen before translation, so rotating an object keeps its pivot at `placement.position`.

Every `draw(in:)` call runs `updateInput → updateScene(deltaTime:) → encodeFrame`. Put behavior in `updateScene`; `encodeFrame` draws the resulting state. The scene first translates the cone and circle from keyboard input, then applies any new mouse aiming request from the new position. Without a new request, the current heading is preserved. The initial half-turn is already stored in the mesh vertices, so it needs no extra per-frame angle.

## Clone an object

The default `Renderer` initializer creates `.circleClone` and `.coneClone` once during setup. They copy `.circle` and `.cone`, then move together by `SceneConfiguration.cloneOffset`, currently `(0.65, 0, 0)`, so both copies are visible beside the originals. WASD and mouse input still affect the originals; the clones stay independent. Portal mapping and automatic following are not implemented.

`cloneObject` copies the source's current placement and color while sharing its GPU mesh. It returns `false` without changing the scene if the source is missing or the new ID is already in use. To create another copy, call this once during setup or in response to an action:

```swift
cloneObject(.circle, newID: .custom("anotherCircle"))
```

Use the clone's ID to edit it later, including from `updateScene()`:

```swift
updateObject(.circleClone) { clone in
    clone.placement.position.x = 0.5
    clone.placement.angle = .pi / 4
}
```

Each clone has its own placement and color; changing them does not change the original. The shared mesh means edits to its underlying vertex buffers would affect both. The explicit `Renderer(view:library:sceneObjects:)` initializer builds exactly the supplied scene, without adding the default clones.

## WASD movement

`KeyboardMetalView.movementDirection` converts the held keys into a 2D vector: W `(0, 1)`, A `(-1, 0)`, S `(0, -1)`, D `(1, 0)`. Opposite keys cancel. The view supplies zero when its window is inactive or it is not the first responder, and clears held keys when focus is lost. `Renderer.updateInput(from:)` copies that direction once per frame.

In `Renderer.updateScene(deltaTime:)`, the movement block is:

```swift
if simd_length_squared(movementDirection) > 0 {
    let step = min(max(deltaTime, 0), 0.1)
    let offset = simd_normalize(movementDirection) * SceneConfiguration.objectMovementSpeed * step
    for id: SceneObjectID in [.cone, .circle] {
        updateObject(id) { object in
            object.placement.position.x += offset.x
            object.placement.position.y += offset.y
        }
    }
}
```

`objectMovementSpeed` is `0.85` canvas units per second and is editable in `SceneConfiguration`. `deltaTime` is the elapsed time between frames, so speed is consistent across frame rates; the 0.1-second cap prevents a large jump after a pause. Normalizing the direction keeps diagonal movement at the same speed. Applying the same offset to both IDs preserves their spacing, and only assigning x/y leaves z unchanged. Movement uses the scene axes regardless of the cone's rotation and continues when the mouse leaves the view.

## Mouse position

`KeyboardMetalView` tracks the cursor while the window is active, including movement while dragging. It stores the latest location in `private(set) var mousePosition: CGPoint?`. AppKit supplies a window-coordinate location; `convert(event.locationInWindow, from: nil)` turns that into this view's coordinates in macOS points.

Use the coordinate value that matches your work:

| Value | Coordinate system |
| --- | --- |
| `inputView.mousePosition` | Native view coordinates, measured in points. |
| `inputView.mouseCanvasPosition` | Centered square canvas coordinates: center `(0, 0)`, right edge x = 1, top edge y = 1. |
| `Renderer.mousePosition` | Scene coordinates, with camera movement accounted for; compare these with `ObjectPlacement.position.x/y`. |

In `Renderer`, `mousePosition` is refreshed every frame for general scene use. A separate `aimRevision` counter in `KeyboardMetalView` changes only for actual pointer movement/dragging or an explicit click, with the target stored in `aimCanvasPosition`. `updateInput(from:)` captures one valid `pendingAimPosition` for each new revision. After keyboard movement, `updateScene(deltaTime:)` consumes that request:

```swift
guard let aimPosition = pendingAimPosition else { return }
pendingAimPosition = nil
updateObject(.cone) { object in
    let position = object.placement.position
    let direction = aimPosition - SIMD2(position.x, position.y)
    let deadZone = SceneConfiguration.lookDeadZoneRadius
    guard simd_length_squared(direction) > deadZone * deadZone else { return }
    object.placement.angle = atan2(direction.y, direction.x) - .pi / 2
}
```

Subtracting the object's position makes the direction correct even after moving the cone. `atan2` measures from +X; subtracting `pi / 2` aligns the mesh's flat end, which faces local +Y, with the cursor direction. The one-time flip belongs in the mesh builder because it defines the shape's initial orientation; `updateScene(deltaTime:)` handles keyboard movement and mouse aiming. Normalization is unnecessary for calculating this angle. Each new aiming request assigns an absolute angle rather than accumulating rotation.

The look dead-zone radius is `0.07` canvas units (24.5 points on the initial canvas). Requests inside it are discarded immediately, so an old near-player pointer position cannot start turning the view after later keyboard movement. Mouse entry, resizing, and focus restoration refresh the stored position without requesting a turn. These transitions also invalidate old aim targets, even if no frame ran while the pointer or focus was gone. After walking, moving or clicking the mouse chooses a heading toward its current location; pointer capture and relative mouse steering are not used.

`private(set)` lets other code read the stored state while the owning type controls updates. The optional `?` means there may be no position: the view clears it when the cursor exits or the window loses focus or detaches. Canvas conversion also returns nil if padding leaves no usable canvas. Input tracking records state; `updateScene()` applies it to objects.

For a 900 × 900 view with 100-point padding, the canvas side is 700. Subtract the view center `(450, 450)` from the mouse location, then divide by 350: the center becomes `(0, 0)` and the canvas's top-right corner becomes `(1, 1)`. The input view accounts for AppKit's y-axis orientation, while `Transforms.canvasPosition` performs the inverse of the render transform. Positions in the surrounding padding can exceed -1...1, matching the canvas's unclipped behavior. Using points rather than drawable pixels keeps the result consistent on Retina displays.

The tracking area follows the visible view bounds, and resizing or reactivating the window refreshes a stationary cursor's location. See [Apple's tracking-area guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html).

## Rendering setup

- `MetalView` owns a coordinator that retains the renderer while `MTKView` holds its weak delegate.
- The 60 fps loop supports smooth held-key object movement using elapsed time, normalized diagonals, and clamped debugger pauses. The camera is stationary; the `Camera` movement helper remains available for experiments.
- The mesh and render/depth states are created once. Each frame encodes the draw, presents the drawable, and commits the command buffer.
- Squares, circles, and the cone triangle share `Mesh2D`'s vertex format: one `float2` position at attribute 0, in buffer 0, with an 8-byte stride. The pipeline uses this shared descriptor; each draw supplies its object's own vertex and index buffers. Different shapes and vertex counts can share a pipeline because their data layout matches.
- All active mesh types draw indexed triangles. The optional sphere uses a different layout (position, normal, UV, 32-byte stride); adding it to this renderer requires adapting its layout or using a matching pipeline.
- Depth uses `.depth32Float`, clears to 1, and compares with `.less`. Opaque objects draw first and write depth. Translucent objects draw back to front with depth writes disabled, so the vision does not hide solid player or portal markers in front of it. Straight-alpha blending combines source color with the existing background; shader alpha alone would not enable transparency.
- The canvas transform scales only x/y to fit a centered, padded square. Depth and homogeneous w stay unchanged: there is no perspective or depth-dependent shrinking.
- Matrix conventions match `metsl`: **row vectors, +Z forward**. Each object's model matrix is `scale * rotation * translation`, so resizing and rotating preserve its positioned local origin. The shader uses `position * model * view * canvas`.
- The canvas matrix is calculated once per frame using the view's point size, so moving between Retina and non-Retina displays preserves padding. A separate perspective helper remains available for experiments; the renderer does not call it.
- Mesh attributes use buffer 0. Uniforms use buffer 1 in both shader stages. Keep `ShaderUniforms.swift` and the Metal struct's field order/types synchronized.
- Xcode compiles `Shaders.metal` as a source into `default.metallib`; the renderer loads it with `makeDefaultLibrary()`.

## Verify

```sh
./Scripts/check.sh
```

This builds the Debug app and runs the actual renderer on the GPU with Metal API validation enabled. Checks cover named-object lookup and updates, duplicate ID rejection, WASD key state and focus cleanup, synchronized XY movement and timing, heading preservation without fresh mouse input, look dead-zone consumption, scale/rotation/translation order, placement changes, square canvas fitting and padding, mouse-coordinate conversion and event callbacks, unchanged depth, camera math, Swift/Metal uniform layout, circle and triangle geometry, translated and rotated triangle rendering, alpha blending and depth ordering, mixed square/circle rendering, empty/tiny scenes, stable resting frames, square/wide/tall drawable sizes, and 2x Retina rendering. Render checks use fixed placements so you can freely edit the scene layout. Build products stay in `MetslStarter-build` under your macOS temporary directory. This avoids signing problems caused by File Provider metadata on synced Desktop/Documents folders. Override the location with `BUILD_DIR` if desired. Running from Xcode uses its normal DerivedData location.

To build Release:

```sh
xcodebuild -project MetslStarter.xcodeproj -scheme MetslStarter \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" build
```

## Apple documentation

Checked against the current Apple docs on September 15, 2026; built using Xcode 27.0.

- [MTKView and drawing modes](https://developer.apple.com/documentation/metalkit/mtkview/)
- [SwiftUI view coordinator](https://developer.apple.com/documentation/swiftui/nsviewrepresentable/makecoordinator%28%29)
- [SwiftUI view cleanup](https://developer.apple.com/documentation/swiftui/nsviewrepresentable/dismantlensview%28_%3Acoordinator%3A%29)
- [Model I/O sphere generation](https://developer.apple.com/documentation/modelio/mdlmesh/init%28spherewithextent%3Asegments%3Ainwardnormals%3Ageometrytype%3Aallocator%3A%29)
- [Compiled Metal shader libraries](https://developer.apple.com/documentation/metal/metal-libraries)
- [Per-draw inline uniform data](https://developer.apple.com/documentation/metal/mtlrendercommandencoder/setvertexbytes%28_%3Alength%3Aindex%3A%29)
- [Depth testing](https://developer.apple.com/documentation/metal/calculating-primitive-visibility-using-depth-testing)
