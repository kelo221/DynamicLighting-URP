Shader "Dynamic Lighting/URP/Metallic"
{
    // special thanks to https://learnopengl.com/PBR/Lighting

    Properties
    {
        _Color("Main Color", Color) = (1,1,1,1)
        _MainTex("Albedo", 2D) = "white" {}
        _Cutoff("Alpha Cutoff", Range(0,1)) = 0.5
        [NoScaleOffset] _MetallicGlossMap("Metallic", 2D) = "black" {}
        _Metallic("Metallic (Fallback)", Range(0,1)) = 0
        _GlossMapScale("Smoothness", Range(0,1)) = 1
        [NoScaleOffset][Normal] _BumpMap("Normal map", 2D) = "bump" {}
        _BumpScale("Normal scale", Float) = 1
        [NoScaleOffset] _OcclusionMap("Occlusion", 2D) = "white" {}
        _OcclusionStrength("Occlusion strength", Range(0,1)) = 0.75
        [HDR] _EmissionColor("Emission Color", Color) = (0,0,0)
        [NoScaleOffset] _EmissionMap("Emission (RGB)", 2D) = "white" {}

        [HideInInspector] _Mode ("Rendering Mode", Float) = 0.0
        [HideInInspector] _SrcBlend ("__src", Float) = 1.0
        [HideInInspector] _DstBlend ("__dst", Float) = 0.0
        [HideInInspector] _ZWrite ("__zw", Float) = 1.0
        [HideInInspector] _Cull("Culling Mode", Float) = 2.0
    }

    CustomEditor "AlpacaIT.DynamicLighting.Editor.MetallicShaderGUI"

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }
        LOD 100

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            Blend [_SrcBlend] [_DstBlend]
            ZWrite [_ZWrite]
            Cull [_Cull]

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            #pragma multi_compile_instancing
            #pragma multi_compile __ DYNAMIC_LIGHTING_SCENE_VIEW_MODE_LIGHTING
            #pragma shader_feature_local METALLIC_TEXTURE_UNASSIGNED
            #pragma shader_feature_local _EMISSION
            #pragma shader_feature_local _ _ALPHATEST_ON _ALPHAPREMULTIPLY_ON
            #pragma shader_feature_local _ DYNAMIC_LIGHTING_CULL_FRONT DYNAMIC_LIGHTING_CULL_OFF

            // Dynamic Lighting system keywords (critical for proper shadow sampling)
            #pragma multi_compile __ DYNAMIC_LIGHTING_QUALITY_LOW DYNAMIC_LIGHTING_QUALITY_HIGH DYNAMIC_LIGHTING_INTEGRATED_GRAPHICS
            #pragma multi_compile __ DYNAMIC_LIGHTING_LIT
            #pragma multi_compile __ DYNAMIC_LIGHTING_BVH
            #pragma multi_compile __ DYNAMIC_LIGHTING_BOUNCE
            #pragma multi_compile __ DYNAMIC_LIGHTING_DYNAMIC_GEOMETRY_DISTANCE_CUBES DYNAMIC_LIGHTING_DYNAMIC_GEOMETRY_ANGULAR

            // Unity Universal Render Pipeline (URP) Lighting Support
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _FORWARD_PLUS
            #pragma multi_compile_fragment _ _CLUSTER_LIGHT_LOOP
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _SCREEN_SPACE_OCCLUSION

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"
            #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/DynamicLighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv0 : TEXCOORD0;
                float2 uv1 : TEXCOORD1;
                float4 color : COLOR;
                float4 tangent : TANGENT;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float2 uv0 : TEXCOORD0;
                // Dynamic Lighting shadow UV - pixel coordinates for shadow bit sampling
                float2 uv1 : TEXCOORD1;
                float4 positionCS : SV_POSITION;
                float4 color : COLOR;
                float3 positionWS : TEXCOORD2;
                float3 normalWS : TEXCOORD3;
                float3 tspace0 : TEXCOORD4; // tangent.x, bitangent.x, normal.x
                float3 tspace1 : TEXCOORD5; // tangent.y, bitangent.y, normal.y
                float3 tspace2 : TEXCOORD6; // tangent.z, bitangent.z, normal.z
                float fogCoord : TEXCOORD7;
                float4 shadowCoord : TEXCOORD8;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            TEXTURE2D(_MainTex); SAMPLER(sampler_MainTex);
            TEXTURE2D(_MetallicGlossMap); SAMPLER(sampler_MetallicGlossMap);
            TEXTURE2D(_BumpMap); SAMPLER(sampler_BumpMap);
            TEXTURE2D(_OcclusionMap); SAMPLER(sampler_OcclusionMap);
            
            #ifdef _EMISSION
                TEXTURE2D(_EmissionMap); SAMPLER(sampler_EmissionMap);
            #endif

            // SRP Batcher: ALL material properties must be inside UnityPerMaterial CBUFFER
            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _Color;
                float _Cutoff;
                float _Metallic;
                float _GlossMapScale;
                float _BumpScale;
                float _OcclusionStrength;
                float4 _EmissionColor;
            CBUFFER_END

            // PBR Helper Functions are provided by Common.hlsl (included via DynamicLighting.hlsl)
            // Available: DistributionGGX, GeometrySchlickGGX, GeometrySmith, fresnelSchlick, fresnelSchlickRoughness

            // Box projection for reflection probes (URP doesn't provide this by default)
            float3 BoxProjectedCubemapDirection(float3 reflectionWS, float3 positionWS, float4 cubemapPositionWS, float4 boxMin, float4 boxMax)
            {
                // Based on Unity's built-in shader implementation
                if (cubemapPositionWS.w > 0.0)
                {
                    float3 boxMinMax = (reflectionWS > 0.0) ? boxMax.xyz : boxMin.xyz;
                    float3 rbMinMax = (boxMinMax - positionWS) / reflectionWS;
                    float fa = min(min(rbMinMax.x, rbMinMax.y), rbMinMax.z);
                    float3 worldPos = positionWS - cubemapPositionWS.xyz;
                    return worldPos + reflectionWS * fa;
                }
                return reflectionWS;
            }

            // ============================================================================
            // Vertex Shader
            // ============================================================================

            Varyings vert(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                output.positionWS = vertexInput.positionWS;
                output.positionCS = vertexInput.positionCS;

                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);
                output.normalWS = normalWS;
                output.uv0 = TRANSFORM_TEX(input.uv0, _MainTex);

                // Dynamic Lighting shadow UV - pixel coordinates for shadow bit sampling
                // The formula: (uv1 - offset) * scale converts UV1 to pixel space
                output.uv1 = (input.uv1 - dynamic_lighting_unity_LightmapST.zw) * dynamic_lighting_unity_LightmapST.xy;

                // Tangent space matrix for normal mapping
                float3 wTangent = TransformObjectToWorldDir(input.tangent.xyz);
                float tangentSign = input.tangent.w * GetOddNegativeScale();
                float3 wBitangent = cross(normalWS, wTangent) * tangentSign;
                output.tspace0 = float3(wTangent.x, wBitangent.x, normalWS.x);
                output.tspace1 = float3(wTangent.y, wBitangent.y, normalWS.y);
                output.tspace2 = float3(wTangent.z, wBitangent.z, normalWS.z);

                output.color = input.color;
                output.fogCoord = ComputeFogFactor(output.positionCS.z);
                
                output.color = input.color;
                output.fogCoord = ComputeFogFactor(output.positionCS.z);
                
                // Handles Screen Space Shadows and Cascades correctly via URP internal logic
                output.shadowCoord = TransformWorldToShadowCoord(vertexInput.positionWS);

                return output;
            }

            // ============================================================================
            // Fragment Shader
            // ============================================================================

            #define DYNLIT_FRAGMENT_LIGHT_OUT_PARAMETERS inout float4 albedo, inout float metallic, inout float roughness, inout float3 N, inout float3 V, inout float3 F0, inout float3 Lo
            #define DYNLIT_FRAGMENT_LIGHT_IN_PARAMETERS albedo, metallic, roughness, N, V, F0, Lo

#if DYNAMIC_LIGHTING_LIT

            // Helper function to process a single light, allowing 'return' to act as 'continue' for the loop
            void ProcessLight(DynamicLight light, Varyings i_original, DynamicTriangle dynamic_triangle, int bvhLightIndex, bool is_front_face, DYNLIT_FRAGMENT_LIGHT_OUT_PARAMETERS)
            {
                // Create a proxy struct matching what LightProcessor.hlsl expects
                struct v2f_proxy {
                    float3 world;
                    float2 uv1;
                };
                v2f_proxy i_proxy;
                i_proxy.world = i_original.positionWS;
                i_proxy.uv1 = i_original.uv1;

                #define i i_proxy
                #define GENERATE_NORMAL N

                // LightProcessor.hlsl declares: light_direction, light_distanceSqr, 
                // light_position_minus_world, NdotL, map, bounce, attenuation
                #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/Generators/LightProcessor.hlsl"

                // Calculate per-light radiance
                float3 H = normalize(V + light_direction);
#if defined(DYNAMIC_LIGHTING_BOUNCE) && !defined(DYNAMIC_LIGHTING_INTEGRATED_GRAPHICS)
                float3 radiance = (light.color * light.intensity * attenuation) + (light.bounceColor * light.intensity * attenuation * bounce);
#else
                float3 radiance = (light.color * light.intensity * attenuation);
#endif

                // Normal Distribution Function (GGX)
                float NDF = DistributionGGX(N, H, roughness);

                // Geometry function (Smith GGX)
                float G = GeometrySmith(N, V, light_direction, roughness);

                // Fresnel equation
                float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

                // kS: reflection/specular fraction, kD: refraction/diffuse fraction
                float3 kS = F;
                float3 kD = 1.0 - kS;
                kD *= 1.0 - metallic;

                // Cook-Torrance BRDF
                float3 numerator = NDF * G * F;
                float denominator = 4.0 * max(dot(N, V), 0.0) * NdotL + 0.0001;
                float3 specular = numerator / denominator;

                // Add to outgoing radiance Lo
#if defined(DYNAMIC_LIGHTING_BOUNCE) && !defined(DYNAMIC_LIGHTING_INTEGRATED_GRAPHICS)
                Lo += (kD * albedo.rgb / UNITY_PI + specular) * radiance * NdotL * map;
                Lo += (kD * albedo.rgb / UNITY_PI + specular) * radiance * bounce;
#else
                Lo += (kD * albedo.rgb / UNITY_PI + specular) * radiance * NdotL * map;
#endif

                #undef i
                #undef GENERATE_NORMAL
            }

            float4 frag(Varyings i, uint triangle_index : SV_PrimitiveID, bool is_front_face : SV_IsFrontFace) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);

                // Material parameters
                float4 albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv0) * _Color * i.color;

            #if METALLIC_TEXTURE_UNASSIGNED
                float metallic = _Metallic;
                float roughness = 1.0 - _GlossMapScale;
            #else
                float4 metallicmap = SAMPLE_TEXTURE2D(_MetallicGlossMap, sampler_MetallicGlossMap, i.uv0);
                float metallic = metallicmap.r;
                float roughness = 1.0 - metallicmap.a * _GlossMapScale;
            #endif
                float ao = SAMPLE_TEXTURE2D(_OcclusionMap, sampler_OcclusionMap, i.uv0).r;

                // Normal mapping
                float3 bumpmap = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, i.uv0), _BumpScale);
                float3 worldNormal;
                worldNormal.x = dot(i.tspace0, bumpmap);
                worldNormal.y = dot(i.tspace1, bumpmap);
                worldNormal.z = dot(i.tspace2, bumpmap);

                float3 N = normalize(worldNormal);
                // URP: Use GetCameraPositionWS() instead of _WorldSpaceCameraPos for proper URP compatibility
                float3 V = normalize(GetCameraPositionWS() - i.positionWS);

                // Calculate reflectance at normal incidence
                float3 F0 = lerp(float3(0.04, 0.04, 0.04), albedo.rgb, metallic);

                // Reflectance equation
                float3 Lo = float3(0.0, 0.0, 0.0);

                Varyings i_original = i;
                uint dynamic_light_count = dynamic_lights_count;
                DynamicTriangle dynamic_triangle;
                dynamic_triangle.initialize();

                #ifndef DYNAMIC_LIGHTING_DYNAMIC_GEOMETRY_DISABLED
                if (lightmap_resolution > 0)
                {
                    // Static geometry with baked lightmap
                    dynamic_triangle.load(triangle_index);

                    for (uint k = 0; k < dynamic_triangle.lightCount + realtime_lights_count; k++)
                    {
                        dynamic_triangle.set_active_light_index(k);
                        DynamicLight light = dynamic_lights[dynamic_triangle.get_dynamic_light_index()];
                        ProcessLight(light, i_original, dynamic_triangle, -1, is_front_face, DYNLIT_FRAGMENT_LIGHT_IN_PARAMETERS);
                    }
                }
                else
                {
                    // Dynamic geometry
                    for (uint k = 0; k < dynamic_lights_count + realtime_lights_count; k++)
                    {
                        DynamicLight light = dynamic_lights[k];
                        #if defined(DYNAMIC_LIGHTING_DYNAMIC_GEOMETRY_DISTANCE_CUBES) || defined(DYNAMIC_LIGHTING_DYNAMIC_GEOMETRY_ANGULAR)
                            ProcessLight(light, i_original, dynamic_triangle, (int)k, is_front_face, DYNLIT_FRAGMENT_LIGHT_IN_PARAMETERS);
                        #else
                            ProcessLight(light, i_original, dynamic_triangle, -1, is_front_face, DYNLIT_FRAGMENT_LIGHT_IN_PARAMETERS);
                        #endif
                    }
                }
                #else
                if (lightmap_resolution > 0)
                {
                    dynamic_triangle.load(triangle_index);

                    for (uint k = 0; k < dynamic_triangle.lightCount + realtime_lights_count; k++)
                    {
                        dynamic_triangle.set_active_light_index(k);
                        DynamicLight light = dynamic_lights[dynamic_triangle.get_dynamic_light_index()];
                        ProcessLight(light, i_original, dynamic_triangle, -1, is_front_face, DYNLIT_FRAGMENT_LIGHT_IN_PARAMETERS);
                    }
                }
                #endif


                
                // -------------------------------------------------------------------------
                // Unity Light Support (Main Light + Additional Lights)
                // -------------------------------------------------------------------------
                
                BRDFData brdfData;
                // Initialize BRDFData using the surface properties we already gathered.
                // Note: F0 (specular color) was calculated as lerp(0.04, albedo, metallic).
                // smoothness is 1.0 - roughness.
                InitializeBRDFData(albedo.rgb, metallic, F0, 1.0 - roughness, albedo.a, brdfData);

                // 1. Main Light
                Light mainLight = GetMainLight(i.shadowCoord, i.positionWS, half4(1,1,1,1));
                Lo += LightingPhysicallyBased(brdfData, mainLight, N, V);

                // 2. Additional Lights
                uint pixelLightCount = GetAdditionalLightsCount();

                // Forward+ Clustered Lighting Support
                InputData inputData = (InputData)0;
                inputData.positionWS = i.positionWS;
                inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(i.positionCS);

                LIGHT_LOOP_BEGIN(pixelLightCount)
                    Light light = GetAdditionalLight(lightIndex, i.positionWS, half4(1,1,1,1));
                    Lo += LightingPhysicallyBased(brdfData, light, N, V);
                LIGHT_LOOP_END

                // -------------------------------------------------------------------------

                // Clamp lighting to prevent FP16 overflow on NVIDIA/Vulkan
                Lo = min(Lo, float3(65000.0, 65000.0, 65000.0));

                // Ambient lighting (IBL)
                float3 F = fresnelSchlickRoughness(max(dot(N, V), 0.0), F0, roughness);
                float3 kS = F;
                float3 kD = 1.0 - kS;
                kD *= 1.0 - metallic;

                // Reflection
                float3 reflection = reflect(-V, worldNormal);

                // Sample reflection probe
                float3 refl0 = reflection;
                #ifdef UNITY_SPECCUBE_BOX_PROJECTION
                    refl0 = BoxProjectedCubemapDirection(refl0, i.positionWS, unity_SpecCube0_ProbePosition, unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
                #endif
                float3 skyColor = DecodeHDREnvironment(SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, refl0, roughness * 4.0), unity_SpecCube0_HDR);

                #ifdef UNITY_SPECCUBE_BLENDING
                    float blendLerp = unity_SpecCube0_BoxMin.w;
                    if (blendLerp < 0.99999)
                    {
                        float3 refl1 = reflection;
                        #ifdef UNITY_SPECCUBE_BOX_PROJECTION
                            refl1 = BoxProjectedCubemapDirection(refl1, i.positionWS, unity_SpecCube1_ProbePosition, unity_SpecCube1_BoxMin, unity_SpecCube1_BoxMax);
                        #endif
                        float3 skyColor1 = DecodeHDREnvironment(SAMPLE_TEXTURECUBE_LOD(unity_SpecCube1, samplerunity_SpecCube0, refl1, roughness * 4.0), unity_SpecCube1_HDR);
                        skyColor = lerp(skyColor1, skyColor, blendLerp);
                    }
                #endif

                float3 specular = skyColor * F;

                // Final lighting
                float3 ambient = kD * albedo.rgb * dynamic_ambient_color;
                float3 color = (ambient + Lo) * lerp(1.0, ao, _OcclusionStrength) + specular;

                #ifdef _ALPHATEST_ON
                    clip(albedo.a - _Cutoff);
                #endif

                #if defined(_EMISSION) && !defined(DYNAMIC_LIGHTING_SCENE_VIEW_MODE_LIGHTING)
                    color.rgb += SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, i.uv0).rgb * _EmissionColor.rgb;
                #endif

                color = MixFog(color, i.fogCoord);

                // Final clamp for framebuffer
                return float4(color, albedo.a);
            }

#else
            // Unlit fallback when DYNAMIC_LIGHTING_LIT is not enabled
            float4 frag(Varyings i) : SV_Target
            {
                float4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv0) * _Color * i.color;
                #ifdef _ALPHATEST_ON
                    clip(col.a - _Cutoff);
                #endif
                col.rgb = MixFog(col.rgb, i.fogCoord);
                return col;
            }
#endif
            ENDHLSL
        }

        // ShadowCaster pass for casting shadows
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull [_Cull]

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex ShadowPassVertex
            #pragma fragment ShadowPassFragment
            #pragma multi_compile_instancing
            #pragma multi_compile_shadowcaster
            #pragma shader_feature_local _ _ALPHATEST_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _Color;
                float _Cutoff;
                float _Metallic;
                float _GlossMapScale;
                float _BumpScale;
                float _OcclusionStrength;
                float4 _EmissionColor;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            float3 _LightDirection;
            float3 _LightPosition;

            float4 GetShadowPositionHClip(Attributes input)
            {
                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);

                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 lightDirectionWS = normalize(_LightPosition - positionWS);
                #else
                    float3 lightDirectionWS = _LightDirection;
                #endif

                float4 positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDirectionWS));

                #if UNITY_REVERSED_Z
                    positionCS.z = min(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    positionCS.z = max(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif

                return positionCS;
            }

            Varyings ShadowPassVertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                output.positionCS = GetShadowPositionHClip(input);
                output.uv = TRANSFORM_TEX(input.uv, _MainTex);
                return output;
            }

            half4 ShadowPassFragment(Varyings input) : SV_TARGET
            {
                UNITY_SETUP_INSTANCE_ID(input);
                #ifdef _ALPHATEST_ON
                    float alpha = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv).a * _Color.a;
                    clip(alpha - _Cutoff);
                #endif
                return 0;
            }
            ENDHLSL
        }

        // DepthOnly pass for depth prepass
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ColorMask R
            Cull [_Cull]

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex DepthOnlyVertex
            #pragma fragment DepthOnlyFragment
            #pragma multi_compile_instancing
            #pragma shader_feature_local _ _ALPHATEST_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _Color;
                float _Cutoff;
                float _Metallic;
                float _GlossMapScale;
                float _BumpScale;
                float _OcclusionStrength;
                float4 _EmissionColor;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            Varyings DepthOnlyVertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = TRANSFORM_TEX(input.uv, _MainTex);
                return output;
            }

            half4 DepthOnlyFragment(Varyings input) : SV_TARGET
            {
                UNITY_SETUP_INSTANCE_ID(input);
                #ifdef _ALPHATEST_ON
                    float alpha = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv).a * _Color.a;
                    clip(alpha - _Cutoff);
                #endif
                return input.positionCS.z;
            }
            ENDHLSL
        }
    }
    Fallback "Universal Render Pipeline/Lit"
}