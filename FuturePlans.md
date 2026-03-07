# Future Plans

## Plan: URP/Vulkan-Enabled Improvements for Dynamic Lighting

The fork's move from BIRP to URP+Vulkan removes several concrete constraints that limited the original library. Below is a prioritized set of improvements, each annotated with **why BIRP prevented it** and **what URP/Vulkan unlocks**.

**Steps**

### 1. Increase Shadow Cubemap Budget Beyond 16

The hard limit at DynamicLightManager.ShadowCamera.cs (`shadowCameraCubemapBudget = 16`) exists because of DX11 error `0x80070057` at ~300. Vulkan has no equivalent TextureCubeArray size restriction — the spec limit is `maxImageArrayLayers` (typically 2048+). Make this configurable (e.g. 32–64 default on Vulkan, keep 16 on DX11 fallback) by querying `SystemInfo.graphicsDeviceType` at init. Also add **distance-based priority sorting** in `ShadowCameraProcessLight` at DynamicLightManager.ShadowCamera.cs — currently first-visible-wins with no priority, so a far-away light can steal a slot from a close one.

> **BIRP reason**: DX11 was the primary target; the CubeArray limit was a real DX11 API constraint. No need to sort when 16 was already generous.

### 2. Multi-Bit Shadow Maps (Soft Penumbra at Source)

Replace 1bpp `BitArray2` shadows with 2–4bpp partial occlusion. The **entire infrastructure already exists** in the bounce texture system:
- C# packing in DynamicTrianglesBuilder.cs — parameterized N-bpp compression with dithering
- HLSL unpacking in DynamicLighting.hlsl — generic shift-and-mask with configurable `bounceBpp`/`bounceMask`
- Software bilinear filtering in DynamicLighting.hlsl

Implementation: fire N jittered rays per texel per light in DynamicLightingTracer.cs, accumulate hit counts, quantize to N bits, store using the existing N-bpp packing path instead of `BitArray2.ToUInt32Array()`. The shader would use `bounce_sample`-style unpacking instead of `& (1 << index % 32)` at DynamicLighting.hlsl. Skip the sqrt/square gamma step since shadow data is linear.

Trade-off: N× more raycasts during bake (2bpp = ~4 rays, 4bpp = ~16 rays per texel per light). The data size per light grows N× but the buffer has no enforced cap. Offer as a quality slider alongside the existing `lightmapResolution`.

> **BIRP reason**: The 1bpp scheme packs 32 lights into a single `uint` per texel — an elegant trick when StructuredBuffer access was unreliable on some BIRP platforms (Metal, GLES). Multi-bit shadows break this "one uint = 32 channels" scheme, requiring a separate data path. With URP+Vulkan guaranteeing reliable StructuredBuffer access, this is no longer a risk.

### 3. Moment Shadow Maps (MSM) to Replace VSM

The current VSM at LightProcessor.hlsl suffers from light bleeding through thin geometry because `ReduceLightBleeding` at Common.hlsl is a simple `linstep` rescale. Moment Shadow Maps store 4 moments (depth, depth², depth³, depth⁴) and reconstruct a tighter distribution.

Changes:
- ShadowDepth.shader: Output `float4(dist, dist², dist³, dist⁴)` instead of `float2(dist, dist²)`
- Shadow cubemap format: `RGBAFloat` instead of `RGFloat` at DynamicLightManager.ShadowCamera.cs
- GaussianBlur.shader: Update to operate on 4 channels (currently reads `.rgb`)
- Replace Chebyshev inequality with Hamburger 4-moment reconstruction in `LightProcessor.hlsl`

> **BIRP reason**: `RGBAFloat` cubemap arrays were expensive and unreliable on DX11 with the 300-cubemap soft limit already in play — doubling channel count halves the effective budget. With Vulkan's relaxed array limits and guaranteed float texture support, RGBA cubemap arrays are practical. Also, the ShadowDepth shader still uses `CGPROGRAM` — converting to `HLSLPROGRAM` for URP compatibility is advisable anyway.

### 4. Compute Shader for Shadow Cubemap Blur

The current per-face Gaussian blur does 12× `Graphics.Blit` per light per frame at DynamicLightManager.ShadowCamera.cs. Each Blit is a full pipeline submission. Replace with a compute shader dispatch:
- One dispatch per cubemap: 6 faces × 2 passes in a single `CommandBuffer` (or a single compute pass using `groupshared` memory for the separable blur)
- Eliminates 12 render state switches per light per frame
- The existing 3-tap kernel at GaussianBlur.shader is tiny — compute overhead is dominated by dispatch submission, which gets amortized
- URP Render Graph allows `AddComputePass` to participate in frame resource scheduling

> **BIRP reason**: Compute shaders existed in BIRP but integrating compute output into the rendering pipeline required manual `CommandBuffer` insertion points (`CameraEvent`). The `Graphics.Blit` pattern was simpler and universally compatible. URP's Render Graph provides explicit compute pass scheduling with automatic resource barriers.

### 5. Increase Distance Cube Resolution

The hardcoded `64×64×6` at DynamicLightingTracer.DistanceCubes.cs and the matching shader constant `64 * 64 * 3` at DynamicLighting.hlsl can be increased to 128×128 or 256×256. Memory impact:
- 64³: ~48KB/light (current)
- 128³: ~192KB/light (4×)
- 256³: ~768KB/light (16×)

Make it configurable. The trilinear filter in `sample_distance_cube_trilinear` does 8 samples at coarse `gridScale = 0.25` — higher resolution enables tighter grid scale for better dynamic geometry shadows without extra samples. Update both `distanceCubesResolution` in C# and the hardcoded multiply in the shader (ideally pass as a shader constant).

> **BIRP reason**: StructuredBuffer size limits were tighter on some DX11 implementations, and the distance cube data for all lights is in a single global buffer. With 100 lights at 64³: ~4.8MB. At 256³: ~76.8MB. BIRP's conservative memory model made the smaller default safer. Vulkan buffer size limits are effectively VRAM-bound only.

### 6. GPU Compute Raytracing for Bake Acceleration

The bake bottleneck is `RaycastCommand` dispatching in Jobs.cs — CPU physics raycasts at 65536 per batch. Replace with a compute shader that:
- Reads triangle/UV data from a StructuredBuffer
- Performs ray-scene intersection on GPU (custom BVH or acceleration structure)
- Writes results to an `RWStructuredBuffer<uint>` using atomic OR (same as the current bit packing)

This is the highest-effort improvement but also the highest-impact for bake time. A simpler intermediate step: use `RaycastCommand` with `maxHits > 1` (available via `QueryParameters` since Unity 2022.2, already conditionally compiled at DynamicLightingTracer.cs) to support multi-bit shadow generation without a full GPU port.

> **BIRP reason**: Compute shaders writing to `RWStructuredBuffer` with atomic operations had platform quirks in BIRP (Metal lacked atomics on StructuredBuffers pre-2020). The `RaycastCommand` approach was the most portable. With Vulkan guaranteeing compute + atomics, a GPU raycaster is viable.

### 7. Vulkan Buffer Binding Fix

DirectX12.cs only applies the dummy buffer fallback for DX12 (`SystemInfo.graphicsDeviceType != GraphicsDeviceType.Direct3D12`). Vulkan has the **same strict binding requirement** — all declared `StructuredBuffer`s must be bound. Extend the guard to include `GraphicsDeviceType.Vulkan`. This is a correctness fix that prevents crashes on Vulkan when a mesh hasn't had its per-object `dynamic_triangles` buffer set yet.

> **BIRP reason**: The original library targeted DX11 which is lenient about unbound buffers. The DX12 fix was added reactively. Vulkan was never a target.

### 8. ShadowDepth.shader: CGPROGRAM → HLSLPROGRAM

The shadow depth shader at ShadowDepth.shader still uses `CGPROGRAM`/`ENDCG` with `UnityObjectToClipPos` (BIRP-style). While this works through `CameraPipeline`'s replacement shader wrapper, converting to `HLSLPROGRAM` with URP includes:
- Enables SRP Batcher compatibility for the depth pass
- Removes dependency on `UnityCG.cginc` (deprecated in URP)
- Required anyway if adopting MSM (step 3) since the 4-channel output needs consistent precision handling with the Vulkan epsilon guards already present in the `.hlsl` files

> **BIRP reason**: It was `.cginc`-native. The URP `CameraPipeline` wrapper makes it work, but it's technical debt.

### 9. Exposed Quality/Budget Configuration

Several hardcoded constants should be promoted to `ScriptableObject`-based configuration or inspector-exposed fields:
- `shadowCameraCubemapBudget` (16) at DynamicLightManager.ShadowCamera.cs
- `shadowCameraResolution` (512) at DynamicLightManager.ShadowCamera.cs
- `distanceCubesResolution` (64) at DynamicLightingTracer.DistanceCubes.cs
- `photonCameraResolution` (1024) at DynamicLightingTracer.PhotonCamera.cs
- Shadow quality tier per-light (1bpp vs multi-bit)
- Max lights per triangle cap (256 at DynamicLighting.hlsl)

> **BIRP reason**: Hardcoded constants were safer when targeting a wide range of DX9–DX11 hardware. URP+Vulkan targets a narrower, more capable hardware set.

**Verification**

- Cubemap budget increase: Render a scene with >16 realtime shadow lights on Vulkan; confirm all render without DX error
- Multi-bit shadows: Compare 1bpp vs 4bpp shadow edges on a scene with clear shadow boundaries — measure aliasing reduction via screenshot comparison
- MSM: Render thin geometry between a light and receiver — compare light bleeding vs current VSM
- Compute blur: Profile frame time of shadow cubemap rendering before/after replacement
- Distance cubes: Compare dynamic geometry shadow quality at 64 vs 128 vs 256 resolution
- Buffer binding fix: Test on Vulkan with uninitialized mesh objects — confirm no crash
- Run existing quality tiers (Integrated/Low/Medium/High) to verify no regressions

**Decisions**

- Multi-bit shadows reuse the existing bounce packing infrastructure rather than a new format — the code is already battle-tested and the shader unpacker is parameterized
- MSM preferred over ESM — ESM has overflow issues with large depth ranges; MSM is numerically stable with 4 moments
- Compute blur before GPU raytracing — much lower effort with immediate per-frame savings
- Vulkan buffer fix is a correctness issue, not an optimization — should ship first


## Plan: URP/Vulkan-Enabled Improvements for Dynamic Lighting

The fork's move from BIRP to URP+Vulkan removes several concrete constraints that limited the original library. Below is a prioritized set of improvements, each annotated with **why BIRP prevented it** and **what URP/Vulkan unlocks**.

**Steps**

### 1. Increase Shadow Cubemap Budget Beyond 16

The hard limit at DynamicLightManager.ShadowCamera.cs (`shadowCameraCubemapBudget = 16`) exists because of DX11 error `0x80070057` at ~300. Vulkan has no equivalent TextureCubeArray size restriction — the spec limit is `maxImageArrayLayers` (typically 2048+). Make this configurable (e.g. 32–64 default on Vulkan, keep 16 on DX11 fallback) by querying `SystemInfo.graphicsDeviceType` at init. Also add **distance-based priority sorting** in `ShadowCameraProcessLight` at DynamicLightManager.ShadowCamera.cs — currently first-visible-wins with no priority, so a far-away light can steal a slot from a close one.

> **BIRP reason**: DX11 was the primary target; the CubeArray limit was a real DX11 API constraint. No need to sort when 16 was already generous.

### 2. Multi-Bit Shadow Maps (Soft Penumbra at Source)

Replace 1bpp `BitArray2` shadows with 2–4bpp partial occlusion. The **entire infrastructure already exists** in the bounce texture system:
- C# packing in DynamicTrianglesBuilder.cs — parameterized N-bpp compression with dithering
- HLSL unpacking in DynamicLighting.hlsl — generic shift-and-mask with configurable `bounceBpp`/`bounceMask`
- Software bilinear filtering in DynamicLighting.hlsl

Implementation: fire N jittered rays per texel per light in DynamicLightingTracer.cs, accumulate hit counts, quantize to N bits, store using the existing N-bpp packing path instead of `BitArray2.ToUInt32Array()`. The shader would use `bounce_sample`-style unpacking instead of `& (1 << index % 32)` at DynamicLighting.hlsl. Skip the sqrt/square gamma step since shadow data is linear.

Trade-off: N× more raycasts during bake (2bpp = ~4 rays, 4bpp = ~16 rays per texel per light). The data size per light grows N× but the buffer has no enforced cap. Offer as a quality slider alongside the existing `lightmapResolution`.

> **BIRP reason**: The 1bpp scheme packs 32 lights into a single `uint` per texel — an elegant trick when StructuredBuffer access was unreliable on some BIRP platforms (Metal, GLES). Multi-bit shadows break this "one uint = 32 channels" scheme, requiring a separate data path. With URP+Vulkan guaranteeing reliable StructuredBuffer access, this is no longer a risk.

### 3. Moment Shadow Maps (MSM) to Replace VSM

The current VSM at LightProcessor.hlsl suffers from light bleeding through thin geometry because `ReduceLightBleeding` at Common.hlsl is a simple `linstep` rescale. Moment Shadow Maps store 4 moments (depth, depth², depth³, depth⁴) and reconstruct a tighter distribution.

Changes:
- ShadowDepth.shader: Output `float4(dist, dist², dist³, dist⁴)` instead of `float2(dist, dist²)`
- Shadow cubemap format: `RGBAFloat` instead of `RGFloat` at DynamicLightManager.ShadowCamera.cs
- GaussianBlur.shader: Update to operate on 4 channels (currently reads `.rgb`)
- Replace Chebyshev inequality with Hamburger 4-moment reconstruction in `LightProcessor.hlsl`

> **BIRP reason**: `RGBAFloat` cubemap arrays were expensive and unreliable on DX11 with the 300-cubemap soft limit already in play — doubling channel count halves the effective budget. With Vulkan's relaxed array limits and guaranteed float texture support, RGBA cubemap arrays are practical. Also, the ShadowDepth shader still uses `CGPROGRAM` — converting to `HLSLPROGRAM` for URP compatibility is advisable anyway.

### 4. Compute Shader for Shadow Cubemap Blur

The current per-face Gaussian blur does 12× `Graphics.Blit` per light per frame at DynamicLightManager.ShadowCamera.cs. Each Blit is a full pipeline submission. Replace with a compute shader dispatch:
- One dispatch per cubemap: 6 faces × 2 passes in a single `CommandBuffer` (or a single compute pass using `groupshared` memory for the separable blur)
- Eliminates 12 render state switches per light per frame
- The existing 3-tap kernel at GaussianBlur.shader is tiny — compute overhead is dominated by dispatch submission, which gets amortized
- URP Render Graph allows `AddComputePass` to participate in frame resource scheduling

> **BIRP reason**: Compute shaders existed in BIRP but integrating compute output into the rendering pipeline required manual `CommandBuffer` insertion points (`CameraEvent`). The `Graphics.Blit` pattern was simpler and universally compatible. URP's Render Graph provides explicit compute pass scheduling with automatic resource barriers.

### 5. Increase Distance Cube Resolution

The hardcoded `64×64×6` at DynamicLightingTracer.DistanceCubes.cs and the matching shader constant `64 * 64 * 3` at DynamicLighting.hlsl can be increased to 128×128 or 256×256. Memory impact:
- 64³: ~48KB/light (current)
- 128³: ~192KB/light (4×)
- 256³: ~768KB/light (16×)

Make it configurable. The trilinear filter in `sample_distance_cube_trilinear` does 8 samples at coarse `gridScale = 0.25` — higher resolution enables tighter grid scale for better dynamic geometry shadows without extra samples. Update both `distanceCubesResolution` in C# and the hardcoded multiply in the shader (ideally pass as a shader constant).

> **BIRP reason**: StructuredBuffer size limits were tighter on some DX11 implementations, and the distance cube data for all lights is in a single global buffer. With 100 lights at 64³: ~4.8MB. At 256³: ~76.8MB. BIRP's conservative memory model made the smaller default safer. Vulkan buffer size limits are effectively VRAM-bound only.

### 6. GPU Compute Raytracing for Bake Acceleration

The bake bottleneck is `RaycastCommand` dispatching in Jobs.cs — CPU physics raycasts at 65536 per batch. Replace with a compute shader that:
- Reads triangle/UV data from a StructuredBuffer
- Performs ray-scene intersection on GPU (custom BVH or acceleration structure)
- Writes results to an `RWStructuredBuffer<uint>` using atomic OR (same as the current bit packing)

This is the highest-effort improvement but also the highest-impact for bake time. A simpler intermediate step: use `RaycastCommand` with `maxHits > 1` (available via `QueryParameters` since Unity 2022.2, already conditionally compiled at DynamicLightingTracer.cs) to support multi-bit shadow generation without a full GPU port.

> **BIRP reason**: Compute shaders writing to `RWStructuredBuffer` with atomic operations had platform quirks in BIRP (Metal lacked atomics on StructuredBuffers pre-2020). The `RaycastCommand` approach was the most portable. With Vulkan guaranteeing compute + atomics, a GPU raycaster is viable.

### 7. Vulkan Buffer Binding Fix

DirectX12.cs only applies the dummy buffer fallback for DX12 (`SystemInfo.graphicsDeviceType != GraphicsDeviceType.Direct3D12`). Vulkan has the **same strict binding requirement** — all declared `StructuredBuffer`s must be bound. Extend the guard to include `GraphicsDeviceType.Vulkan`. This is a correctness fix that prevents crashes on Vulkan when a mesh hasn't had its per-object `dynamic_triangles` buffer set yet.

> **BIRP reason**: The original library targeted DX11 which is lenient about unbound buffers. The DX12 fix was added reactively. Vulkan was never a target.

### 8. ShadowDepth.shader: CGPROGRAM → HLSLPROGRAM

The shadow depth shader at ShadowDepth.shader still uses `CGPROGRAM`/`ENDCG` with `UnityObjectToClipPos` (BIRP-style). While this works through `CameraPipeline`'s replacement shader wrapper, converting to `HLSLPROGRAM` with URP includes:
- Enables SRP Batcher compatibility for the depth pass
- Removes dependency on `UnityCG.cginc` (deprecated in URP)
- Required anyway if adopting MSM (step 3) since the 4-channel output needs consistent precision handling with the Vulkan epsilon guards already present in the `.hlsl` files

> **BIRP reason**: It was `.cginc`-native. The URP `CameraPipeline` wrapper makes it work, but it's technical debt.

### 9. Exposed Quality/Budget Configuration

Several hardcoded constants should be promoted to `ScriptableObject`-based configuration or inspector-exposed fields:
- `shadowCameraCubemapBudget` (16) at DynamicLightManager.ShadowCamera.cs
- `shadowCameraResolution` (512) at DynamicLightManager.ShadowCamera.cs
- `distanceCubesResolution` (64) at DynamicLightingTracer.DistanceCubes.cs
- `photonCameraResolution` (1024) at DynamicLightingTracer.PhotonCamera.cs
- Shadow quality tier per-light (1bpp vs multi-bit)
- Max lights per triangle cap (256 at DynamicLighting.hlsl)

> **BIRP reason**: Hardcoded constants were safer when targeting a wide range of DX9–DX11 hardware. URP+Vulkan targets a narrower, more capable hardware set.

**Verification**

- Cubemap budget increase: Render a scene with >16 realtime shadow lights on Vulkan; confirm all render without DX error
- Multi-bit shadows: Compare 1bpp vs 4bpp shadow edges on a scene with clear shadow boundaries — measure aliasing reduction via screenshot comparison
- MSM: Render thin geometry between a light and receiver — compare light bleeding vs current VSM
- Compute blur: Profile frame time of shadow cubemap rendering before/after replacement
- Distance cubes: Compare dynamic geometry shadow quality at 64 vs 128 vs 256 resolution
- Buffer binding fix: Test on Vulkan with uninitialized mesh objects — confirm no crash
- Run existing quality tiers (Integrated/Low/Medium/High) to verify no regressions

**Decisions**

- Multi-bit shadows reuse the existing bounce packing infrastructure rather than a new format — the code is already battle-tested and the shader unpacker is parameterized
- MSM preferred over ESM — ESM has overflow issues with large depth ranges; MSM is numerically stable with 4 moments
- Compute blur before GPU raytracing — much lower effort with immediate per-frame savings
- Vulkan buffer fix is a correctness issue, not an optimization — should ship first


## Work Required vs Visual Improvement

| # | Improvement | Effort | Visual Impact | Runtime Cost | VRAM Cost | Bake Cost |
|---|-------------|--------|---------------|--------------|-----------|-----------|
| 7 | Vulkan Buffer Binding Fix | ⬛ Trivial (~1hr) | None (correctness) | None | None | None |
| 8 | ShadowDepth CGPROGRAM → HLSLPROGRAM | ⬛⬛ Low (~1 day) | None (tech debt) | None | None | None |
| 9 | Exposed Quality/Budget Configuration | ⬛⬛ Low (~1–2 days) | None (enabler) | None | None | None |
| 1 | Increase Shadow Cubemap Budget | ⬛⬛Read , lines 1 to 150 Low (~2 days) | Medium — more lights cast realtime shadows | Scales with budget (more cubemap renders) | +~6MB per 16 extra cubemaps @ 512² RGFloat | None |
| 5 | Increase Distance Cube Resolution | ⬛⬛ Low (~1–2 days) | Medium — sharper dynamic geometry shadows | Negligible (same sample count) | ×4 at 128², ×16 at 256² per light | Slight increase (higher-res photon capture) |
| 4 | Compute Shader Cubemap Blur | ⬛⬛⬛ Medium (~3–5 days) | None (same blur) | **Saves** ~0.1–0.5ms/frame per shadow light | None | None |
| 2 | Multi-Bit Shadow Maps | ⬛⬛⬛⬛ High (~1–2 weeks) | **High** — smooth penumbra, eliminates jagged shadow edges | Slightly higher (N-bpp unpack vs 1-bit mask) | ×2–4 shadow data per light | ×4–16 longer bake (N rays per texel) |
| 3 | Moment Shadow Maps (MSM) | ⬛⬛⬛⬛ High (~1–2 weeks) | **High** — eliminates VSM light bleeding on thin geometry | Slightly higher (4-moment reconstruction) | ×2 cubemap VRAM (RGBA vs RG) | None |
| 6 | GPU Compute Raytracing | ⬛⬛⬛⬛⬛ Very High (~4–8 weeks) | None at runtime (bake-only) | None | None | **10–100× faster bakes** |

### Reading the Table

- **Effort**: Rough implementation time for a developer familiar with the codebase
- **Visual Impact**: What the end user sees in the final rendered frame
- **Runtime Cost**: Per-frame GPU/CPU cost change (positive = costs more, negative = saves time)
- **VRAM Cost**: Additional GPU memory at runtime
- **Bake Cost**: Change in lightmap bake duration

---

## Dependency Graph

```
[7] Vulkan Buffer Fix ──────────────────────────────────────────┐
                                                                 │
[8] ShadowDepth → HLSLPROGRAM ──┐                               │ (all items assume
                                 ├──► [3] Moment Shadow Maps     │  Vulkan fix is in)
[9] Exposed Configuration ──────┤                                │
                                 ├──► [1] Cubemap Budget ◄───────┘
                                 └──► [5] Distance Cube Res
                                 
[2] Multi-Bit Shadows ─────────────► [6] GPU Compute Raytrace
      (standalone)                     (standalone, but multi-bit
                                        benefits most from faster bake)

[4] Compute Cubemap Blur
      (standalone, pairs well with [3])
```

**Key dependencies:**
- **Step 8 is a prerequisite for Step 3** — MSM requires the ShadowDepth shader to output 4 channels with proper HLSL precision guards
- **Step 9 enables Steps 1 and 5** — exposing the constants is needed before making them configurable
- **Step 7 is a prerequisite for everything** — Vulkan correctness must come first
- **Steps 2, 4, and 6 are independent** — can proceed in any order
- **Step 6 amplifies Step 2** — multi-bit shadows multiply bake time; GPU raycasting offsets that cost

---

## Suggested Implementation Phases

### Phase 0 — Foundations (no visual change, enables everything)
1. **[7]** Vulkan buffer binding fix
2. **[8]** ShadowDepth.shader CGPROGRAM → HLSLPROGRAM
3. **[9]** Expose hardcoded constants as configuration

### Phase 1 — Quick Wins (low effort, immediate benefit)
4. **[1]** Increase shadow cubemap budget + priority sorting
5. **[5]** Increase distance cube resolution (configurable)

### Phase 2 — Visual Quality (high effort, high visual payoff)
6. **[2]** Multi-bit shadow maps (soft penumbra)
7. **[3]** Moment shadow maps (eliminate light bleeding)

### Phase 3 — Performance (high effort, bake/runtime speedup)
8. **[4]** Compute shader cubemap blur
9. **[6]** GPU compute raytracing

---

## VRAM Budget Estimates (100 lights, 500 triangles scene)

| Resource | Current | After All Improvements |
|----------|---------|----------------------|
| Shadow cubemaps (16 × 512² × RGFloat) | ~32 MB | ~128 MB (64 × 512² × RGBAFloat with MSM) |
| Distance cubes (100 lights × 64²×6 × f16) | ~4.8 MB | ~19.2 MB (100 × 128²×6 × f16) |
| Dynamic triangles buffer (1bpp shadows) | ~varies | ×2–4 with multi-bit shadows |
| BVH + light data | ~<1 MB | ~<1 MB (unchanged) |
| **Total estimate** | ~40–60 MB | ~160–220 MB |

> Note: These are rough upper bounds. Actual usage depends on scene complexity, light count, and chosen quality settings. Making budgets configurable (Phase 0) lets users tune for their target hardware.

---

## Known Technical Debt & Gotchas

| Issue | Location | Notes |
|-------|----------|-------|
| Rounding error in trilinear filter | DynamicLighting.hlsl L504, DynamicLighting.cginc L485 | `fixme` comment — `0.49805` magic number |
| Volumetric cone angle guesswork | DynamicLightManager.PostProcessing.cs L107, L113 | `fixme` — heuristic, not physically derived |
| Unoptimized `TryGetShadowBit` | DynamicLightingTracer.cs L1146 | `todo: optimize this` — bounds check on every access |
| Wasteful bounce dilation loop | DynamicLightingTracer.cs L1226 | `todo: optimize this (very wasteful iterations)` |
| Bounce texture memcpy | DynamicLightingTracer.cs L1190 | `todo: surely there's a clever memory copy function` |
| Redundant UV step calculations | TriangleUvToFull3dStep.cs L176 | `todo: can optimize` — shared terms between two calls |
| Metallic texture unassigned look | ForwardAddMetallic.cginc L100 | `todo: not working right (looks very dull)` — BIRP only |
| DX12 hack not applied on Vulkan | DirectX12.cs L47 | Guard only checks DX12, not Vulkan |
| GaussianBlur uses `UnityCG.cginc` | GaussianBlur.shader | BIRP include — same tech debt as ShadowDepth |
| No light priority sorting | ShadowCamera.cs L188 | First-visible-wins, no distance/importance weighting |

---

## Potential Future Explorations (Beyond Current Scope)

| Idea | Feasibility | Why It Might Matter |
|------|-------------|---------------------|
| **Temporal shadow caching** — reuse cubemap faces that haven't changed between frames | Medium | Most lights are static; re-rendering all 6 faces per light per frame is wasteful |
| **Clustered light assignment** — replace BVH with a 3D cluster grid for dynamic geometry | Medium | Standard technique in URP/HDRP; may scale better than BVH for high light counts |
| **Async compute overlap** — run shadow cubemap rendering on async compute queue | Medium–Hard | Vulkan exposes multiple queues; shadow rendering could overlap with main pass |
| **Sparse distance cubes** — only allocate high-res faces for directions that face geometry | Hard | Would cut VRAM by ~40–60% for lights near walls/corners |
| **Half-res volumetrics** — render volumetric fog at half resolution and bilateral upsample | Low | Standard optimization; the post-processing pass is already full-screen |
| **Shadow atlas instead of cubemap array** — pack all shadow faces into a 2D atlas | Medium | Avoids cubemap array size limits entirely; used by HDRP |
| **Raytraced shadows via Unity's RT API** — for hardware with RT cores | Hard | Would replace CPU raycasts entirely with DXR/VkRay; requires RT-capable GPU |
| **Probe-based bounce lighting** — SH probes instead of per-texel bounce data | High | Would dramatically reduce bounce data size; trades spatial precision for compression |
