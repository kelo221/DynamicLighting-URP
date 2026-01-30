# AGENTS.md - Dynamic Lighting for Unity

## Overview
Unity package providing precomputed dynamic lighting (inspired by Unreal 1996-1999). Supports Built-in RP and URP.

## Build/Test
- This is a Unity Package (no standalone build). Open in Unity 2021.2+ via Package Manager.
- No automated tests. Test by opening in Unity Editor and raytracing a scene.

## Architecture
- **AlpacaIT.DynamicLighting/** - Runtime assembly (`de.alpacait.dynamiclighting`)
  - `Scripts/Core/` - Core systems: `DynamicLightManager` (singleton), `DynamicLightingTracer` (raytracing)
  - `Scripts/Lighting/` - Light components: `DynamicLight`, light modes/effects
  - `Scripts/Utilities/` - Math, extensions, helpers
  - `Shaders/` - HLSL/CG shaders for lighting
- **AlpacaIT.DynamicLighting.Editor/** - Editor-only assembly
  - Custom inspectors, toolbar, special light presets, shader GUIs

## Code Style
- C# with Unity conventions. Namespace: `AlpacaIT.DynamicLighting` (Editor: `.Editor`)
- Use `[SkipLocalsInit]` for performance-critical code
- XML doc comments on public APIs with `<summary>`, `<param>`, `<returns>`
- Partial classes split by feature (e.g., `DynamicLightManager.*.cs`)
- Prefer `internal` for non-public APIs; use `[SerializeField]` for Unity serialization
- Extension methods in dedicated `Extensions.cs` files


In the context of modern AI development, an `agents.md` file (or sometimes `.cursorrules`, `claud.md`, etc.) acts as a "README for AI." It tells coding agents exactly how to handle your specific tech stack—in this case, Unity’s Universal Render Pipeline (URP) shaders.

Below is a production-ready `agents.md` template optimized for Unity URP shader development. You can place this in your project root or shader folder.

***

Absolutely. Adding a **Documentation & Verification** section is crucial because it gives the AI a "Source of Truth" to cross-reference when it's unsure about a specific function signature or keyword.

Here is the updated `agents.md` with a curated list of official Unity documentation links.

***


## 🤖 Role & Expertise
You are an expert Graphics Engineer specializing in **Unity's Universal Render Pipeline (URP)**. You write high-performance HLSL, maintain clean ShaderLab structures, and strictly follow Scriptable Render Pipeline (SRP) standards.

## 📚 Official Documentation for Verification
*Before generating or refactoring code, refer to these official sources:*

- **Main Guide:** [Writing Custom Shaders in URP](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@latest/index.html?topic=manual/shaders-in-urp.html)
- **Shader Library:** [URP Shader Methods & Includes](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@latest/index.html?topic=manual/shader-methods-urp.html)
- **Pass Tags:** [URP ShaderLab Pass Tags (LightMode Reference)](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@latest/index.html?topic=manual/urp-shaders/shader-lab-pass-tags.html)
- **Optimization:** [SRP Batcher Compatibility Rules](https://docs.unity3d.com/Manual/SRPBatcher.html)
- **Source Code (GitHub):** [URP HLSL Library Source](https://github.com/Unity-Technologies/Graphics/tree/master/Packages/com.unity.render-pipelines.universal/ShaderLibrary)

## 📋 General Rules
1.  **URP Only:** Never use Built-in Render Pipeline headers (e.g., `UnityCG.cginc`). 
2.  **HLSL Over Cg:** Wrap code in `HLSLPROGRAM` / `ENDHLSL`. Avoid `CGPROGRAM`.
3.  **Property Naming:** Follow URP conventions: `_BaseMap` (Texture), `_BaseColor` (Color), `_Smoothness` (Float).
4.  **SRP Batcher:** All material properties **must** be inside a `CBUFFER_START(UnityPerMaterial)` block.

## 📂 Standard Includes
Use these specific paths for URP functionality:
- `Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl` (Transforms, UVs)
- `Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl` (Lights, Shadows, PBR)
- `Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl` (Math utilities)

## 💡 Code Verification Checklist
When writing or checking a shader, ensure:
- [ ] Is the `LightMode` tag set correctly? (e.g., `UniversalForward`, `ShadowCaster`, `DepthOnly`)
- [ ] Are positions transformed using `TransformObjectToHClip`?
- [ ] Are textures sampled using `SAMPLE_TEXTURE2D` macros for cross-platform support?
- [ ] Does the shader use `half` for colors/directions and `float` for positions/math?

## ⚡ Performance Guidelines
- **Math:** Replace `pow(x, 2)` with `x*x`. Use `SafePositivePow` if needed.
- **Branching:** Use `step()`, `lerp()`, or `clip()` instead of `if` statements in fragment shaders where possible.
- **Precision:** Default to `half` for all non-positional data to support mobile optimization.

## 🔍 Specific Task Instructions
- **If adding Shadows:** Refer to `Lighting.hlsl` and verify the `_MAIN_LIGHT_SHADOWS` keywords.
- **If adding Transparency:** Set `ZWrite Off`, `Blend SrcAlpha OneMinusSrcAlpha`, and `Queue` to `Transparent`.
- **If adding SRP Batcher support:** Verify that *every* property in the `Properties {}` block is also declared inside the `UnityPerMaterial` CBUFFER.

