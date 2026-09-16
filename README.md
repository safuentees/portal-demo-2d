# Metsl Starter

A ready-to-run macOS Metal project based on `metsl-macOS`: one stationary blue sphere on the same pale background, with the window, camera controls, GPU setup, and shaders already wired together.

## Version and repository

Current release: **v1.0.0** (app version 1.0.0, build 1). See `CHANGELOG.md` for release notes.

Clone the private repository while signed in with GitHub CLI:

```sh
gh repo clone safuentees/portal-demo-2d
cd metsl-starter
open MetslStarter.xcodeproj
```

Get future updates with `git pull --ff-only`. To use this exact starting point, run `git switch --detach v1.0.0`; create a branch with `git switch -c my-experiment` before making changes.

## Run

1. Open `MetslStarter.xcodeproj`.
2. Select the **MetslStarter** scheme and **My Mac**.
3. Press **Command-R**.

Click the scene to focus it. **W/S** moves the camera forward/backward; **A/D** moves left/right. Closing and reopening the window resets the camera.

The project uses SwiftUI, AppKit, MetalKit, Model I/O, and SIMD. There are no external packages or setup commands. It keeps the original macOS 14 minimum and Swift 5 language mode, uses the installed macOS SDK, and uses local ad hoc signing without an Apple development team.

## Start editing here

| Change | File |
| --- | --- |
| Sphere color, position, mesh detail, background, camera speed | `Sources/Scene/SceneConfiguration.swift` |
| Vertex transforms or fragment color | `Sources/Shaders/Shaders.metal` |
| Render pipeline and drawing | `Sources/Rendering/Renderer.swift` |
| Sphere geometry and vertex layout | `Sources/Rendering/SphereMesh.swift` |
| Camera state and movement | `Sources/Scene/Camera.swift` |
| Projection and translation math | `Sources/Scene/Transforms.swift` |
| Keyboard handling | `Sources/Input/KeyboardMetalView.swift` |
| View setup, draw rate, renderer lifetime | `Sources/Views/MetalView.swift` |
| Window title and initial size | `Sources/App/MetslStarterApp.swift` |

The color is a single RGBA value:

```swift
static let sphereColor = SIMD4<Float>(0.20, 0.45, 0.90, 1.0)
```

The fragment shader returns that value directly. The mesh is three-dimensional; its unlit, uniformly colored surface has a flat circular appearance. Normals and UVs are already present in the mesh for future experiments.

## Rendering setup

- `MetalView` owns a coordinator that retains the renderer while `MTKView` holds its weak delegate.
- The 60 fps loop supports smooth held-key movement. Camera movement uses elapsed time, normalizes diagonals, and clamps long debugger pauses.
- The mesh and render/depth states are created once. Each frame encodes the draw, presents the drawable, and commits the command buffer.
- Depth uses `.depth32Float`, clears to 1, and compares with `.less`.
- Projection uses the drawable's current aspect ratio so resizing does not stretch the sphere.
- Matrix conventions match `metsl`: **row vectors, +Z forward**, and `position * model * view * projection`. Near/far map to Metal depth 0/1.
- Mesh attributes use buffer 0. Uniforms use buffer 1 in both shader stages. Keep `ShaderUniforms.swift` and the Metal struct's field order/types synchronized.
- Xcode compiles `Shaders.metal` as a source into `default.metallib`; the renderer loads it with `makeDefaultLibrary()`.

## Verify

```sh
./Scripts/check.sh
```

This builds the Debug app and runs the actual renderer on the GPU with Metal API validation enabled. Checks cover projection depth, camera movement, Swift/Metal uniform layout, the flat sphere color, a stationary resting frame, and square/wide/tall drawable sizes. The checks are for this starter scene; update their expectations when intentionally changing the scene. Build products stay in `MetslStarter-build` under your macOS temporary directory. This avoids signing problems caused by File Provider metadata on synced Desktop/Documents folders. Override the location with `BUILD_DIR` if desired. Running from Xcode uses its normal DerivedData location.

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
