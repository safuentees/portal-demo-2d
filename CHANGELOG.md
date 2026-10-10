# Changelog

## Unreleased

- Rewrite the README with clear Xcode setup, controls, a crossing walkthrough, three captured Metal scene images, and current implementation limits.
- Preserve detailed implementation notes in `Docs/RenderingGuide.md` and correct stale descriptions of triangle geometry and cone parameter handling.

## 1.0.0 — 2026-09-15

Initial reusable macOS Metal starter, based on metsl-macOS.

- One stationary, solid-color sphere with configurable scene settings.
- SwiftUI window and MetalKit renderer, with WASD camera controls, depth testing, and resize handling.
- Separate app, view, input, scene, rendering, and shader folders.
- Shared Xcode scheme, compiled Metal shaders, and local ad hoc signing.
- GPU smoke checks for rendering, aspect ratio, color, camera math, and uniform layout.
- macOS 14 minimum; verified with Xcode 27.0 in Debug and Release.
