# Metsl Starter

A ready-to-run macOS Metal project based on `metsl-macOS`, with independently positioned and scaled blue squares and a solid circle on a dark background. The window, camera controls, GPU setup, and shaders are already wired together; sphere geometry is also available for experiments.

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

Click the scene to focus it. **A/D** moves the camera left/right. **W/S** changes camera depth; in the flat scene this can clip objects rather than zooming them. Closing and reopening the window resets the camera.

The project uses SwiftUI, AppKit, MetalKit, Model I/O, and SIMD. There are no external packages or setup commands. It keeps the original macOS 14 minimum and Swift 5 language mode, uses the installed macOS SDK, and uses local ad hoc signing without an Apple development team.

## Start editing here

| Change | File |
| --- | --- |
| Square/circle positions and scales, circle detail, canvas padding, scene colors | `Sources/Scene/SceneConfiguration.swift` |
| Object IDs and the initial data for each scene object | `Sources/Scene/SceneObjectConfiguration.swift` |
| Position/scale data and model transform | `Sources/Scene/ObjectPlacement.swift` |
| Mesh, placement, and color for one rendered object | `Sources/Rendering/RenderObject.swift` |
| Vertex transforms or fragment color | `Sources/Shaders/Shaders.metal` |
| Render pipeline and drawing | `Sources/Rendering/Renderer.swift` |
| Shared 2D vertex layout and GPU buffer creation | `Sources/Rendering/Meshes/Mesh2D.swift` |
| Unit square vertices and triangle indices | `Sources/Rendering/Meshes/SquareMesh.swift` |
| Solid circle vertices and triangle indices | `Sources/Rendering/Meshes/CircleMesh.swift` |
| Optional sphere geometry and mesh detail | `Sources/Rendering/Meshes/SphereMesh.swift` |
| Camera state and movement | `Sources/Scene/Camera.swift` |
| Scale, translation, and square canvas fitting | `Sources/Scene/Transforms.swift` |
| Keyboard and mouse events/state | `Sources/Input/KeyboardMetalView.swift` |
| View setup, draw rate, renderer lifetime | `Sources/Views/MetalView.swift` |
| Window title and initial size | `Sources/App/MetslStarterApp.swift` |

Edit `SceneConfiguration.objects` to arrange the scene. Every entry creates one object; its ID, shape, position, scale, and color stay together:

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

Add or remove entries to change the object count. Use the named IDs `.bottomBar`, `.topBar`, and `.circle` for the existing objects. For new objects, add a case to `SceneObjectID` or use a unique `.custom("name")`. IDs identify individual objects, independently of their shape or array order; duplicate IDs cause a setup error. The renderer shares one mesh across all objects of the same shape, and changing one entry's scale does not affect the others. Placement defaults are position `(0, 0, 0)` and scale `(1, 1, 1)`.

Edit the `.circle` entry to set the solid circle's initial position and scale; `circleScale` is currently `0.1`. This object follows the cursor during scene updates. The circle mesh has radius 1, so scale `(1, 1, 1)` fills the canvas diameter and `(0.5, 0.5, 1)` makes it half as wide. Different x/y scales make an ellipse. `circleSegments` controls edge smoothness (64 by default). The mesh includes a center vertex and a ring of rim vertices; every adjacent pair on the rim forms a triangle with the center, including the closing pair. This fills the circle without a hole or an open seam.

With the camera at rest, `(0, 0)` is the center of an invisible square canvas, positive x goes right, and positive y goes up. Its edges are at `-1...1` on both axes. For the unit square mesh, scale `(1, 1, 1)` spans half the canvas width and height; `(0.5, 0.5, 1)` spans one quarter. Different x/y scales make rectangles. Object coordinates and proportions stay the same when the window changes shape.

`SceneConfiguration.canvasPadding` sets the minimum space around the canvas, currently **100 macOS points on every side**. Points keep the visual spacing consistent on Retina displays (100 points corresponds to 200 backing pixels at 2x). The starting content size is **900 × 900 points**: the original 700-point canvas plus padding. macOS may restore an existing window's size; resize it or open a new window to use the new dimensions.

The canvas side is `max(min(windowWidth, windowHeight) - 2 * padding, 0)`. It stays centered and square: a 900 × 1100 view has a 700 × 700 canvas with 100 points at left/right and 200 at top/bottom. Smaller windows scale the whole layout down uniformly. If there is no room after padding, the canvas collapses instead of flipping or dividing by zero. The canvas is a coordinate reference, not a clipping mask; objects intentionally placed beyond its edges can enter the surrounding space.

Keep `position.z = 0` and `scale.z = 1` for a simple flat layout. Depth does not change apparent size. For overlapping layers, smaller z values are closer; use values from 0 up to, but excluding, 1 with the current depth test. See [Apple's coordinate and viewport documentation](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Render-Ctx/Render-Ctx.html).

`SceneConfiguration.objectColor` supplies the initial RGBA color for each object. The fragment shader returns each object's color directly. Configuration supplies the starting values; the renderer owns the live `RenderObject` values after setup.

## Access an object during a frame

Use its ID in `Renderer.updateScene()` to change position, size, or color:

```swift
updateObject(.topBar) { object in
    object.placement.position.x = 0.4
    object.placement.scale.x = 0.6
}
```

`updateObject` finds the ID, gives your closure an editable value with `inout`, and saves the result back into the scene. The closure can also read other objects by ID. It returns `false` if the ID is absent. Use `object(withID: .topBar)` to read its current state; that returns an optional copy because `RenderObject` is a struct. Editing that copy on its own will not change the scene. Each object's model matrix is computed from its current placement.

Every `draw(in:)` call runs `updateInput → updateScene → encodeFrame`. Put behavior in `updateScene()`; `encodeFrame` draws the resulting state. The existing example moves only `.circle` to the mouse, preserving its scale and z position. When there is no mouse position, the circle stays where it was. Remove that update block if you want to control the circle another way.

## Mouse position

`KeyboardMetalView` tracks the cursor while the window is active, including movement while dragging. It stores the latest location in `private(set) var mousePosition: CGPoint?`. AppKit supplies a window-coordinate location; `convert(event.locationInWindow, from: nil)` turns that into this view's coordinates in macOS points.

Use the coordinate value that matches your work:

| Value | Coordinate system |
| --- | --- |
| `inputView.mousePosition` | Native view coordinates, measured in points. |
| `inputView.mouseCanvasPosition` | Centered square canvas coordinates: center `(0, 0)`, right edge x = 1, top edge y = 1. |
| `Renderer.mousePosition` | Scene coordinates, with camera movement accounted for; compare these with `ObjectPlacement.position.x/y`. |

In `Renderer`, the `mousePosition` variable is refreshed in `updateInput(from:deltaTime:)` every frame. `updateScene()` reads it to move the circle:

```swift
guard let mousePosition else { return }
updateObject(.circle) { object in
    object.placement.position.x = mousePosition.x
    object.placement.position.y = mousePosition.y
}
```

`private(set)` lets other code read the stored state while the owning type controls updates. The optional `?` means there may be no position: the view clears it when the cursor exits or the window loses focus or detaches. Canvas conversion also returns nil if padding leaves no usable canvas. Input tracking records state; `updateScene()` applies it to objects.

For a 900 × 900 view with 100-point padding, the canvas side is 700. Subtract the view center `(450, 450)` from the mouse location, then divide by 350: the center becomes `(0, 0)` and the canvas's top-right corner becomes `(1, 1)`. The input view accounts for AppKit's y-axis orientation, while `Transforms.canvasPosition` performs the inverse of the render transform. Positions in the surrounding padding can exceed -1...1, matching the canvas's unclipped behavior. Using points rather than drawable pixels keeps the result consistent on Retina displays.

The tracking area follows the visible view bounds, and resizing or reactivating the window refreshes a stationary cursor's location. See [Apple's tracking-area guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html).

## Rendering setup

- `MetalView` owns a coordinator that retains the renderer while `MTKView` holds its weak delegate.
- The 60 fps loop supports smooth held-key movement. Camera movement uses elapsed time, normalizes diagonals, and clamps long debugger pauses.
- The mesh and render/depth states are created once. Each frame encodes the draw, presents the drawable, and commits the command buffer.
- Squares and circles share `Mesh2D`'s vertex format: one `float2` position at attribute 0, in buffer 0, with an 8-byte stride. The pipeline uses this shared descriptor; each draw supplies its object's own vertex and index buffers. Different shapes and vertex counts can share a pipeline because their data layout matches.
- Both active mesh types draw indexed triangles. The optional sphere uses a different layout (position, normal, UV, 32-byte stride); adding it to this renderer requires adapting its layout or using a matching pipeline.
- Depth uses `.depth32Float`, clears to 1, and compares with `.less`.
- The canvas transform scales only x/y to fit a centered, padded square. Depth and homogeneous w stay unchanged: there is no perspective or depth-dependent shrinking.
- Matrix conventions match `metsl`: **row vectors, +Z forward**. Each object's model matrix is `scale * translation`, so resizing does not move its center. The shader uses `position * model * view * canvas`.
- The canvas matrix is calculated once per frame using the view's point size, so moving between Retina and non-Retina displays preserves padding. A separate perspective helper remains available for experiments; the renderer does not call it.
- Mesh attributes use buffer 0. Uniforms use buffer 1 in both shader stages. Keep `ShaderUniforms.swift` and the Metal struct's field order/types synchronized.
- Xcode compiles `Shaders.metal` as a source into `default.metallib`; the renderer loads it with `makeDefaultLibrary()`.

## Verify

```sh
./Scripts/check.sh
```

This builds the Debug app and runs the actual renderer on the GPU with Metal API validation enabled. Checks cover named-object lookup and updates, duplicate ID rejection, circle mouse-follow, scale/translation order, placement changes, square canvas fitting and padding, mouse-coordinate conversion and event callbacks, unchanged depth, camera movement, Swift/Metal uniform layout, circle geometry, mixed square/circle rendering, empty/tiny scenes, stable resting frames, square/wide/tall drawable sizes, and 2x Retina rendering. Render checks use fixed placements so you can freely edit the scene layout. Build products stay in `MetslStarter-build` under your macOS temporary directory. This avoids signing problems caused by File Provider metadata on synced Desktop/Documents folders. Override the location with `BUILD_DIR` if desired. Running from Xcode uses its normal DerivedData location.

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
