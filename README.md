# Metsl Starter

A ready-to-run macOS Metal project based on `metsl-macOS`, with a circular player, a translucent field of view, and two portal bars. Crossing an opening with the player's center transfers the player and its view through the portal pair. Mapped clones and fragment clipping show the portal view. Full-body collision handling is not implemented. The window, keyboard controls, GPU setup, and shaders are wired together; sphere geometry is also available for experiments.

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

Click the scene to focus it. **W/A/S/D** moves the player and its view together: initially W up, A left, S down, D right. Crossing a portal rotates the movement controls with the player, so you can keep holding a key to continue through. The current portals reverse both movement axes; crossing back restores them. **Hold Q to turn left/counterclockwise or E to turn right/clockwise.** Holding both cancels rotation. Mouse movement and clicks no longer change the heading. Movement affects only x/y; depth and camera stay fixed. Releasing the keys or switching windows stops movement and rotation. Closing and reopening the window restores the configured scene.

The project uses SwiftUI, AppKit, MetalKit, Model I/O, and SIMD. There are no external packages or setup commands. It keeps the original macOS 14 minimum and Swift 5 language mode, uses the installed macOS SDK, and uses local ad hoc signing without an Apple development team.

## Start editing here

| Change | File |
| --- | --- |
| Object positions, sizes, colors, field of view, movement and rotation speeds, and canvas padding | `Sources/Scene/SceneConfiguration.swift` |
| Object IDs and the initial data for each scene object | `Sources/Scene/SceneObjectConfiguration.swift` |
| Position, scale, rotation angle, and model transform | `Sources/Scene/ObjectPlacement.swift` |
| Portal frames, opening widths, movement crossings, and placement mapping | `Sources/Scene/Portal.swift` |
| Mesh, placement, color, and viewport-extension flag for one rendered object | `Sources/Rendering/RenderObject.swift` |
| Vertex transforms, portal intersection tests, and fragment visibility | `Sources/Shaders/Shaders.metal` |
| Scene updates, pipeline selection, uniforms, and drawing | `Sources/Rendering/Renderer.swift` |
| Swift data shared with both shader stages | `Sources/Rendering/ShaderUniforms.swift` |
| Shared 2D vertex layout and GPU buffer creation | `Sources/Rendering/Meshes/Mesh2D.swift` |
| Unit square vertices and triangle indices | `Sources/Rendering/Meshes/SquareMesh.swift` |
| Solid circle vertices and triangle indices | `Sources/Rendering/Meshes/CircleMesh.swift` |
| Triangle vertices used by the cone | `Sources/Rendering/Meshes/TriangleMesh.swift` |
| Optional sphere geometry and mesh detail | `Sources/Rendering/Meshes/SphereMesh.swift` |
| Camera state and movement | `Sources/Scene/Camera.swift` |
| Matrix math, canvas coordinates, and vision extent that covers the viewport | `Sources/Scene/Transforms.swift` |
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

The `.cone` uses the flat triangle mesh. `TriangleMesh.make` flips its vertices 180 degrees once around the center of their bounds, `(0, 0.5)`, before creating the GPU buffer. This preserves the local footprint (`x = -0.5...0.5`, `y = 0...1`) while exchanging the tip and flat end. The resulting tip is at `(0, 0)` and the flat-edge midpoint is at `(0, 1)`. Q/E turns the cone around its tip; WASD moves the cone and circle together.

`visionFieldOfView` is `2 * atan(0.62)`, about 63.6 degrees. `visionScale` gives the triangle a unit forward reach and preserves that opening angle. For objects with `extendsVisionToViewport`, the renderer temporarily extends both x/y scales together until the far edge passes the window boundary. This includes the padding and works when the eye is offscreen; resizing does not modify the stored placement. Ordinary triangles retain their configured size.

The original blue vision uses alpha `0.12`; the green clone uses `portalVisionColor` with alpha `0.16`. `playerColor` is a lighter opaque blue, and `cloneColor` is opaque green. Vision stays at depth `0.5` behind the solid circles and portal bars.

With the camera at rest, `(0, 0)` is the center of an invisible square canvas, positive x goes right, and positive y goes up. Its edges are at `-1...1` on both axes. For the unit square mesh, scale `(1, 1, 1)` spans half the canvas width and height; `(0.5, 0.5, 1)` spans one quarter. Different x/y scales make rectangles. Object coordinates and proportions stay the same when the window changes shape.

`SceneConfiguration.canvasPadding` sets the minimum space around the canvas, currently **100 macOS points on every side**. Points keep the visual spacing consistent on Retina displays (100 points corresponds to 200 backing pixels at 2x). The starting content size is **900 × 900 points**: the original 700-point canvas plus padding. macOS may restore an existing window's size; resize it or open a new window to use the new dimensions.

The canvas side is `max(min(windowWidth, windowHeight) - 2 * padding, 0)`. It stays centered and square: a 900 × 1100 view has a 700 × 700 canvas with 100 points at left/right and 200 at top/bottom. Smaller windows scale the whole layout down uniformly. If there is no room after padding, the canvas collapses instead of flipping or dividing by zero. The canvas is a coordinate reference, not a clipping mask; objects intentionally placed beyond its edges can enter the surrounding space.

Keep `position.z = 0` and `scale.z = 1` for a simple flat layout. Depth does not change apparent size. For overlapping layers, smaller z values are closer; use values from 0 up to, but excluding, 1 with the current depth test. See [Apple's coordinate and viewport documentation](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Render-Ctx/Render-Ctx.html).

`SceneConfiguration` supplies the initial RGBA colors, with separate values for the bars, player, vision, and clones. Visible fragments return their object's color; portal shaders discard fragments outside the selected visibility rule. The renderer owns the live `RenderObject` values after setup.

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

Every `draw(in:)` call runs `updateInput → updateScene(deltaTime:) → encodeFrame`. `updateScene` calls `movePlayer`, `rotatePlayer`, and `updatePortalClones` in that order. Movement updates the circle and cone together and maps their full placements if the player's center crosses a portal. Q/E then adds its rotation to the cone's resulting angle, including after a teleport, and the default clones follow the updated placements. The heading stays fixed when neither traversal nor rotation changes it. `encodeFrame` selects the pipeline and supplies the uniforms for each draw. The initial triangle flip is already stored in its mesh vertices.

## Clone an object

The default `Renderer` initializer creates `.circleClone` and `.coneClone` once during setup. Each frame, `updatePortalClones` maps their source placements from `.bottomBar` into `.topBar`. WASD and Q/E input affect the originals; the mapped clones follow automatically. Their green colors are independent of the originals. The default clone placements are overwritten by this update, so use a custom ID for a copy you want to position independently.

`cloneObject` copies the source's current placement, color, and viewport-extension flag while sharing its GPU mesh. It returns `false` without changing the scene if the source is missing or the new ID is already in use. To create another copy, call this once during setup or in response to an action:

```swift
cloneObject(.circle, newID: .custom("anotherCircle"))
```

Use the clone's ID to edit it later, including from `updateScene()`:

```swift
updateObject(.custom("anotherCircle")) { clone in
    clone.placement.position.x = 0.5
    clone.placement.angle = .pi / 4
}
```

Each clone has its own placement and color; changing them does not change the original. The shared mesh means edits to its underlying vertex buffers would affect both. The explicit `Renderer(view:library:sceneObjects:)` initializer builds exactly the supplied scene, without adding the default clones.

## Portal mapping, traversal, and visibility

`PortalFrame` in `Sources/Scene/Portal.swift` contains a rigid local-to-world frame, its inverse, and the opening's half-width. A bar's position and angle define its frame; its x scale determines the opening width. Visual thickness does not scale the coordinate frame. `PortalPair` maps placements using the current row-vector transform:

```text
transfer = inverse(entranceFrame) * exitFrame
mappedPosition = originalPosition * transfer
```

Positions use homogeneous `w = 1`; directions use `w = 0` so translation cannot change the heading. `mappedPlacement` maps both position and heading while preserving scale. Traversal maps the proposed placement after this frame's movement, preserving any distance traveled past the opening. Clone updates map their original object's current placement instead of accumulating changes to the clone. The matrix convention stays `inverse(entranceFrame) * exitFrame`; there is no extra half-turn or hardcoded `.pi` rotation.

`PortalFrame.crossingFraction(from:to:)` tests the movement segment in portal-local coordinates. It accepts crossings from either side of `y = 0` within the opening width, including movement that ends exactly on the plane. Parallel motion and movement starting on the plane do not count. `PortalPair.firstCrossing` checks both bars and selects the earliest hit, reversing the directed pair when entering through `.topBar`. Missing or zero-width portals disable traversal.

`movePlayer` makes that crossing decision once using the circle's center, with the cone as a fallback when the circle is absent. It applies the same directed mapping to both proposed placements. Their sizes stay unchanged, and each object's original z is restored because z controls rendering layers in this flat scene. `exitClearanceOffset` adds one shared, tiny offset only when the mapped center is within `0.00001` units of the exit plane. It places the center on the side of the mapped motion to prevent rounding from producing another crossing; it does not add a cooldown or change ordinary movement past the opening.

The shader's `intersectsPortal` checks whether the segment from an object's center to a fragment crosses a finite opening. `intersectsEitherPortal` combines the two opening tests. Original `.circle` and `.cone` fragments disappear when that result is true; `.circleClone` and `.coneClone` fragments appear when it is true. Other IDs use the ordinary color pipeline. Opening half-widths come from the bars' current x scales; missing or zero-width openings are disabled rather than replaced with an opening at the origin.

The current equal-width bars face 180 degrees apart, making this particular transfer its own inverse. That lets the single mapped clone serve either opening in this arrangement. Traversal selects either directed pair, but general two-way cloned views with independently rotated portals still need separate mappings. Recursive portal views are not implemented. Circle ray clipping remains experimental; center-based traversal does not test whether the whole body fits through an opening or collides with its edges. At most one crossing is processed per movement update.

## WASD movement

`KeyboardMetalView.movementDirection` converts the held keys into a 2D input vector: W `(0, 1)`, A `(-1, 0)`, S `(0, -1)`, D `(1, 0)`. Opposite keys cancel. The view supplies zero when its window is inactive or it is not the first responder, and clears held keys when focus is lost. `Renderer.updateInput(from:)` copies that input once per frame; native input does not need to know about portals.

`Renderer.movePlayer(deltaTime:)` rotates that input by `movementControlAngle` to compute the frame's world-space XY `displacement`, finds one `crossedPair` from the player's center movement, and obtains its shared `exitOffset`. Inside the update for each of `.circle` and `.cone`, the placement changes like this:

```swift
var placement = object.placement
placement.position += displacement
if let crossedPair {
    placement = crossedPair.mappedPlacement(placement)
    placement.position += exitOffset
    placement.position.z = object.placement.position.z
}
object.placement = placement
```

`objectMovementSpeed` is `0.85` canvas units per second and is editable in `SceneConfiguration`. `deltaTime` is the elapsed time between frames, so speed is consistent across frame rates; the 0.1-second cap prevents a large jump after a pause. Normalizing the direction keeps diagonal movement at the same speed. A shared crossing decision keeps the circle and cone together, and their rendering depths remain unchanged. Movement continues when the mouse leaves the view.

`movementControlAngle` starts at zero. After a crossing, `movePlayer` updates it once, outside the object loop:

```swift
movementControlAngle = Transforms.mappedAngle(movementControlAngle, through: crossedPair.transferMatrix)
```

`Transforms.mappedAngle` maps a heading vector with `w = 0`, then recovers its angle with `atan2`. The same helper maps object headings, so controls and the player use the same portal rotation without inheriting translation. The next frame's input follows the mapped exit motion. With the current 180-degree pair, W becomes down, S up, A right, and D left. Arbitrary portal angles also work; going back through the paired exit applies the inverse rotation and restores the previous controls. The orientation persists after key release or focus loss, and resets when a new renderer is created. Q/E changes only the cone's heading, not these movement axes.

## Q/E rotation

`KeyboardMetalView.rotationDirection` is `1` while Q is held, `-1` while E is held, and `0` when neither or both are held. It uses the same focus checks and held-key cleanup as WASD. `Renderer.updateInput(from:)` reads this value once per frame.

After movement, `Renderer.rotatePlayer(deltaTime:)` adds a small angle to the cone:

```swift
let step = min(max(deltaTime, 0), 0.1)
let angleChange = rotationDirection * SceneConfiguration.objectRotationSpeed * step
updateObject(.cone) { object in
    object.placement.angle += angleChange
}
```

`SceneConfiguration.objectRotationSpeed` is `.pi` radians per second, or 180 degrees per second. Positive angles turn counterclockwise, so Q turns left and E turns right. Rotation uses elapsed time rather than keyboard repeat, giving smooth turning while a key is held. The angle stays in `ObjectPlacement`; its computed model matrix applies that rotation without changing position or scale. Mouse position is independent of this rotation.

## Mouse position

`KeyboardMetalView` tracks the cursor while the window is active, including movement while dragging. It stores the latest location in `private(set) var mousePosition: CGPoint?`. AppKit supplies a window-coordinate location; `convert(event.locationInWindow, from: nil)` turns that into this view's coordinates in macOS points.

Use the coordinate value that matches your work:

| Value | Coordinate system |
| --- | --- |
| `inputView.mousePosition` | Native view coordinates, measured in points. |
| `inputView.mouseCanvasPosition` | Centered square canvas coordinates: center `(0, 0)`, right edge x = 1, top edge y = 1. |
| `Renderer.mousePosition` | Scene coordinates, with camera movement accounted for; compare these with `ObjectPlacement.position.x/y`. |

In `Renderer`, `mousePosition` is refreshed every frame for future scene interactions. Pointer movement, dragging, clicking, resizing, and focus restoration update the tracked coordinates without changing the cone's angle.

`private(set)` lets other code read the stored state while the owning type controls updates. The optional `?` means there may be no position: the view clears it when the cursor exits or the window loses focus or detaches. Canvas conversion also returns nil if padding leaves no usable canvas. The tracked position remains available independently of keyboard movement and rotation.

For a 900 × 900 view with 100-point padding, the canvas side is 700. Subtract the view center `(450, 450)` from the mouse location, then divide by 350: the center becomes `(0, 0)` and the canvas's top-right corner becomes `(1, 1)`. The input view accounts for AppKit's y-axis orientation, while `Transforms.canvasPosition` performs the inverse of the render transform. Positions in the surrounding padding can exceed -1...1, matching the canvas's unclipped behavior. Using points rather than drawable pixels keeps the result consistent on Retina displays.

The tracking area follows the visible view bounds, and resizing or reactivating the window refreshes a stationary cursor's location. See [Apple's tracking-area guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html).

## Rendering setup

- `MetalView` owns a coordinator that retains the renderer while `MTKView` holds its weak delegate.
- The 60 fps loop supports smooth held-key object movement using elapsed time, normalized diagonals, and clamped debugger pauses. The camera is stationary; the `Camera` movement helper remains available for experiments.
- The mesh and render/depth states are created once. Each frame encodes the draw, presents the drawable, and commits the command buffer.
- Three pipelines share `object_vertex`: `object_fragment` supplies ordinary color, `portal_fragment` clips originals, and `portal_clone_fragment` clips mapped copies. The renderer selects a pipeline for every object; selecting one does not permanently attach a shader to its mesh.
- Squares, circles, and the cone triangle share `Mesh2D`'s vertex format: one `float2` position at attribute 0, in buffer 0, with an 8-byte stride. The pipeline uses this shared descriptor; each draw supplies its object's own vertex and index buffers. Different shapes and vertex counts can share a pipeline because their data layout matches.
- All active mesh types draw indexed triangles. The optional sphere uses a different layout (position, normal, UV, 32-byte stride); adding it to this renderer requires adapting its layout or using a matching pipeline.
- Depth uses `.depth32Float`, clears to 1, and compares with `.less`. Opaque objects draw first and write depth. Translucent objects draw back to front with depth writes disabled, so the vision does not hide solid player or portal markers in front of it. Straight-alpha blending combines source color with the existing background; shader alpha alone would not enable transparency.
- The canvas transform scales only x/y to fit a centered, padded square. Depth and homogeneous w stay unchanged: there is no perspective or depth-dependent shrinking.
- Matrix conventions match `metsl`: **row vectors, +Z forward**. Each object's model matrix is `scale * rotation * translation`, so resizing and rotating preserve its positioned local origin. The shader uses `position * model * view * canvas`.
- The canvas matrix is calculated once per frame using the view's point size, so moving between Retina and non-Retina displays preserves padding. A separate perspective helper remains available for experiments; the renderer does not call it.
- Mesh attributes use buffer 0. Uniforms use buffer 1 in both shader stages. Besides model/view/canvas matrices and color, they carry `worldToEntrance`/`eyeInEntrance`, `worldToExit`/`eyeInExit`, `resolution`, and `portalHalfWidths`. Eyes and interpolated fragment positions are compared in the same portal-local frame. `resolution` is the full drawable size in pixels, including Retina scaling. Keep `ShaderUniforms.swift` and the Metal struct's field order/types synchronized.
- Xcode compiles `Shaders.metal` as a source into `default.metallib`; the renderer loads it with `makeDefaultLibrary()`.

## Verify

```sh
./Scripts/check.sh
```

This builds the Debug app and runs the actual renderer on the GPU with Metal API validation enabled. Checks cover named-object lookup and updates, duplicate ID rejection, WASD and Q/E key state and focus cleanup, synchronized XY movement and timing, held-key rotation and cancellation, heading preservation during mouse input, scale/rotation/translation order, placement changes, square canvas fitting and padding, mouse-coordinate conversion and event callbacks, unchanged depth, camera math, Swift/Metal uniform layout, circle and triangle geometry, translated and rotated triangle rendering, alpha blending and depth ordering, mixed square/circle rendering, portal mapping and aperture tests, center crossings and mapped movement/headings, held movement through portals and restored controls on return, viewport-reaching vision, empty/tiny scenes, stable resting frames, square/wide/tall drawable sizes, and 2x Retina rendering. Render checks use fixed placements so you can freely edit the scene layout. Build products stay in `MetslStarter-build` under your macOS temporary directory. This avoids signing problems caused by File Provider metadata on synced Desktop/Documents folders. Override the location with `BUILD_DIR` if desired. Running from Xcode uses its normal DerivedData location.

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
