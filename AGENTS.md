# Project instructions

## Commit before making changes

- Always checkpoint the current project in Git before starting edits for a new task. This includes code, configuration, and documentation edits.
- Read-only inspection and the verification needed to prepare the checkpoint may run first.
- If the working tree is dirty, review the existing changes and commit the intended project work before implementing anything new. Preserve the user's edits; never reset or discard them to make the checkpoint easier.
- If the working tree is already clean, the current HEAD is the checkpoint. Do not create an empty commit.
- Stage files by explicit path. Never use `git add .`, `git add -A`, or `--no-verify`.
- Use Conventional Commit subjects. Keep separate work in separate commits, and record verification in the commit body.
- Commit completed work after its checks pass, unless the user explicitly requests uncommitted changes. Do not push unless requested.

## Verification

- Run `./Scripts/check.sh` before committing code changes. It builds the macOS app and exercises the renderer on the GPU with Metal API validation.
- Use `git diff --check` to check the current patch for whitespace errors.
- Xcode and Metal may require execution outside the tool sandbox to access the installed toolchain. Keep build products in the temporary directory selected by the script.
- Add focused checks when changing geometry, transforms, input, or Swift/Metal uniform layout. Color-only changes can use the existing checks.

## Organization and rendering conventions

- `Sources/Scene/SceneConfiguration.swift` owns editable positions, scales, colors, canvas padding, and circle detail.
- `Sources/Scene/ObjectPlacement.swift` groups position and scale; `Transforms.swift` owns coordinate and matrix math.
- `Sources/Input/KeyboardMetalView.swift` owns native input events and input state. Rendering reads that state; mesh builders do not handle input.
- `Sources/Rendering/Meshes/Mesh2D.swift` defines the shared packed `float2` layout. Individual mesh files define their own vertices and triangle indices.
- Keep the scene flat, with no perspective, unless the user requests otherwise. Use row vectors and `position * model * view * canvas`.
- Canvas coordinates run from -1 to 1 across a centered square. Padding and window dimensions use macOS points; drawable textures use pixels. Account for Retina scaling.
- Keep `ShaderUniforms.swift` and the Metal uniform struct in sync.
- Keep changes within the requested scope and preserve the user's current scene layout.
