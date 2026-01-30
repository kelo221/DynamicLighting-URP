Shader "Dynamic Lighting/URP/Diffuse"
{
    Properties
    {
        _Color("Main Color", Color) = (1,1,1,1)
        _MainTex("Base (RGB)", 2D) = "white" {}
        _Cutoff("Alpha Cutoff", Range(0,1)) = 0.5
        [HDR] _EmissionColor("Emission Color", Color) = (0,0,0)
        [NoScaleOffset] _EmissionMap("Emission (RGB)", 2D) = "white" {}

        [HideInInspector] _Mode ("Rendering Mode", Float) = 0.0
        [HideInInspector] _SrcBlend ("__src", Float) = 1.0
        [HideInInspector] _DstBlend ("__dst", Float) = 0.0
        [HideInInspector] _ZWrite ("__zw", Float) = 1.0
        [HideInInspector] _Cull("Culling Mode", Float) = 2.0
    }

    CustomEditor "AlpacaIT.DynamicLighting.Editor.DefaultShaderGUI"

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
            #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/DynamicLighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
                float2 uv1 : TEXCOORD1;
                float4 color : COLOR;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float2 uv : TEXCOORD0;
                // Dynamic Lighting shadow UV - pixel coordinates for shadow bit sampling
                float2 uv1 : TEXCOORD1;
                float4 positionCS : SV_POSITION;
                float4 color : COLOR;
                float3 positionWS : TEXCOORD2;
                float3 normalWS : TEXCOORD3;
                float fogCoord : TEXCOORD4;
                float4 shadowCoord : TEXCOORD5;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            
            #ifdef _EMISSION
                TEXTURE2D(_EmissionMap);
                SAMPLER(sampler_EmissionMap);
            #endif

            // SRP Batcher: ALL material properties must be inside UnityPerMaterial CBUFFER
            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _Color;
                float4 _EmissionColor;
                float _Cutoff;
            CBUFFER_END

            Varyings vert(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                output.positionWS = vertexInput.positionWS;
                output.positionCS = vertexInput.positionCS;
                
                output.normalWS = TransformObjectToWorldNormal(input.normalOS);
                output.uv = TRANSFORM_TEX(input.uv, _MainTex);
                
                // Dynamic Lighting shadow UV - pixel coordinates for shadow bit sampling
                // The formula: (uv1 - offset) * scale converts UV1 to pixel space
                // This matches the BIRP implementation exactly
                output.uv1 = (input.uv1 - dynamic_lighting_unity_LightmapST.zw) * dynamic_lighting_unity_LightmapST.xy;

                output.color = input.color;
                output.fogCoord = ComputeFogFactor(output.positionCS.z);
                
                output.color = input.color;
                output.fogCoord = ComputeFogFactor(output.positionCS.z);
                
                // Handles Screen Space Shadows and Cascades correctly via URP internal logic
                output.shadowCoord = TransformWorldToShadowCoord(vertexInput.positionWS);

                return output;
            }
            
            #define DYNLIT_FRAGMENT_LIGHT_OUT_PARAMETERS inout float3 light_final
            #define DYNLIT_FRAGMENT_LIGHT_IN_PARAMETERS light_final

#if DYNAMIC_LIGHTING_LIT

            // Helper function to process a single light, allowing 'return' to act as 'continue' for the loop
            void ProcessLight(DynamicLight light, Varyings i_original, DynamicTriangle dynamic_triangle, int bvhLightIndex, bool is_front_face, inout float3 light_final)
            {
                // Create a proxy struct matching what LightProcessor.hlsl expects
                // LightProcessor uses: i.world (world position), i.uv1 (shadow pixel coords)
                struct v2f_proxy {
                    float3 world;
                    float2 uv1;
                };
                v2f_proxy i_proxy;
                i_proxy.world = i_original.positionWS;
                i_proxy.uv1 = i_original.uv1;  // Dynamic lighting UV (pixel coords for shadow sampling)
                
                #define i i_proxy
                #define GENERATE_NORMAL i_original.normalWS

                // LightProcessor.hlsl declares and uses: light_direction, light_distanceSqr, 
                // light_position_minus_world, NdotL, map, bounce, attenuation
                #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/Generators/LightProcessor.hlsl"

                #if defined(DYNAMIC_LIGHTING_BOUNCE) && !defined(DYNAMIC_LIGHTING_INTEGRATED_GRAPHICS)
                    light_final += (light.color * attenuation * NdotL * map) + (light.bounceColor * attenuation * bounce);
                #else
                    light_final += (light.color * attenuation * NdotL * map);
                #endif

                #undef i
                #undef GENERATE_NORMAL
            }

            float4 frag(Varyings i, uint triangle_index : SV_PrimitiveID, bool is_front_face : SV_IsFrontFace) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                
                float3 light_final = dynamic_ambient_color;
                
                Varyings i_original = i;
                
                uint dynamic_light_count = dynamic_lights_count;
                DynamicTriangle dynamic_triangle;
                dynamic_triangle.initialize();

                #ifndef DYNAMIC_LIGHTING_DYNAMIC_GEOMETRY_DISABLED
                if (lightmap_resolution > 0)
                {
                    // Static geometry with baked lightmap - use triangle acceleration structure
                    dynamic_triangle.load(triangle_index);
                    
                    // Iterate over every dynamic light affecting this triangle
                    for (uint k = 0; k < dynamic_triangle.lightCount + realtime_lights_count; k++)
                    {
                        dynamic_triangle.set_active_light_index(k);
                        DynamicLight light = dynamic_lights[dynamic_triangle.get_dynamic_light_index()];
                        ProcessLight(light, i_original, dynamic_triangle, -1, is_front_face, light_final);
                    }
                }
                else
                {
                    // Dynamic geometry - iterate over all lights
                    for (uint k = 0; k < dynamic_lights_count + realtime_lights_count; k++)
                    {
                        DynamicLight light = dynamic_lights[k];
                        #if defined(DYNAMIC_LIGHTING_DYNAMIC_GEOMETRY_DISTANCE_CUBES) || defined(DYNAMIC_LIGHTING_DYNAMIC_GEOMETRY_ANGULAR)
                            ProcessLight(light, i_original, dynamic_triangle, (int)k, is_front_face, light_final);
                        #else
                            ProcessLight(light, i_original, dynamic_triangle, -1, is_front_face, light_final);
                        #endif
                    }
                }
                #else
                // Dynamic geometry disabled - only process static geometry
                if (lightmap_resolution > 0)
                {
                    dynamic_triangle.load(triangle_index);
                    
                    for (uint k = 0; k < dynamic_triangle.lightCount + realtime_lights_count; k++)
                    {
                        dynamic_triangle.set_active_light_index(k);
                        DynamicLight light = dynamic_lights[dynamic_triangle.get_dynamic_light_index()];
                        ProcessLight(light, i_original, dynamic_triangle, -1, is_front_face, light_final);
                    }
                }
                #endif

                // Clamp lighting to prevent FP16 overflow on NVIDIA/Vulkan (max 65504).
                // This prevents overexposure artifacts on Linux NVIDIA drivers.
                light_final = min(light_final, float3(65000.0, 65000.0, 65000.0));

                // -------------------------------------------------------------------------
                // Unity Light Support (Main Light + Additional Lights)
                // -------------------------------------------------------------------------
                
                // 1. Main Light
                Light mainLight = GetMainLight(i_original.shadowCoord, i_original.positionWS, half4(1,1,1,1));
                float3 mainLightColor = mainLight.color * mainLight.distanceAttenuation * mainLight.shadowAttenuation * saturate(dot(i_original.normalWS, mainLight.direction));
                light_final += mainLightColor;

                // 2. Additional Lights
                uint pixelLightCount = GetAdditionalLightsCount();

                // Forward+ Clustered Lighting Support
                InputData inputData = (InputData)0;
                inputData.positionWS = i_original.positionWS;
                inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(i_original.positionCS);

                LIGHT_LOOP_BEGIN(pixelLightCount)
                    Light light = GetAdditionalLight(lightIndex, i_original.positionWS, half4(1,1,1,1));
                    float3 lightColor = light.color * light.distanceAttenuation * light.shadowAttenuation * saturate(dot(i_original.normalWS, light.direction));
                    light_final += lightColor;
                LIGHT_LOOP_END

                // -------------------------------------------------------------------------

                #ifdef DYNAMIC_LIGHTING_SCENE_VIEW_MODE_LIGHTING
                    // Scene view lighting mode - show lighting only (white albedo)
                    float4 col = float4(1, 1, 1, SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i_original.uv).a) * float4(1, 1, 1, _Color.a) * float4(light_final, 1) * float4(1, 1, 1, i_original.color.a);
                #else
                    // Normal rendering: albedo * color * lighting * vertex color
                    float4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i_original.uv) * _Color * float4(light_final, 1) * i_original.color;
                #endif
                
                #ifdef _ALPHATEST_ON
                    clip(col.a - _Cutoff);
                #endif

                #if defined(_EMISSION) && !defined(DYNAMIC_LIGHTING_SCENE_VIEW_MODE_LIGHTING)
                    col.rgb += SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, i_original.uv).rgb * _EmissionColor.rgb;
                #endif

                col.rgb = MixFog(col.rgb, i_original.fogCoord);
                
                // Final clamp: ensure output doesn't exceed valid range for framebuffer.
                // Critical for NVIDIA/Vulkan which is strict about overflow values.
                return float4(col.rgb, col.a);
            }

#else
            // Unlit fallback when DYNAMIC_LIGHTING_LIT is not enabled
            float4 frag(Varyings i) : SV_Target
            {
                float4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv) * _Color * i.color;
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
                float4 _EmissionColor;
                float _Cutoff;
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
                float4 _EmissionColor;
                float _Cutoff;
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
