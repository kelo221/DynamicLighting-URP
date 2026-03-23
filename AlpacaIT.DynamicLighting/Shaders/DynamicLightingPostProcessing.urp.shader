Shader "Hidden/DynamicLightingPostProcessing.URP"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            Name "DynamicLightingVolumetrics"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/DynamicLighting.hlsl"

            float _DL_DebugViewMode;

            // macros to name the recycled variables.
            #define light_volumetricRadius radiusSqr
            #define light_volumetricThickness gpFloat1
            #define light_volumetricScale float3(light.gpFloat2, light.gpFloat3, light.shimmerScale)
            #define light_volumetricSpotAngle light.gpFloat2
            #define volumetric_type_sphere 1
            #define volumetric_type_box 2
            #define volumetric_type_cone_y 3
            #define volumetric_type_cone_z 4

            float4 frag(Varyings input) : SV_Target
            {
                float2 uv = input.texcoord;
                
                // Sample depth - URP provides this via DeclareDepthTexture.hlsl
                float depth = SampleSceneDepth(uv);
                
                // Handle different graphics APIs (convert to linear 0-1 range for calculation)
                #if !UNITY_REVERSED_Z
                    depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, depth);
                #endif
                
                // Use the same UV for world position reconstruction
                float3 worldspace = ComputeWorldSpacePosition(uv, depth, UNITY_MATRIX_I_VP);
                // _BlitTexture is defined by Blit.hlsl
                float4 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv);
                
                // iterate over every volumetric light in the scene (pre-filtered on the CPU):
                float4 fog_final = float4(0.0, 0.0, 0.0, 0.0);
                float fog_final_t = 0.0;
                
                // Aggregate debug values across all volumetric lights, not just the first one.
                float debug_min_dist01 = 1.0;
                float debug_nearest_type01 = 0.0;
                float debug_any_closest_point_in_sphere = 0.0;
                float debug_max_raw_t = 0.0;
                float debug_max_camera_to_world = 0.0;
                float debug_any_intersection = 0.0;
                float2 debug_first_light_screen_uv = float2(-10.0, -10.0);
                float debug_first_light_in_front = 0.0;
                
                for (uint k = 0; k < dynamic_lights_count; k++)
                {
                    // get the current volumetric light from memory.
                    DynamicLight light = dynamic_lights[k];
                    
                    float4 fog_color = float4(light.color, 1.0);
                    float3 fog_center = light.position;
                    float fog_radius = light.light_volumetricRadius;
                    uint volumetric_type = light.channel;

                    if (k == 0)
                    {
                        float4 lightClip = mul(UNITY_MATRIX_VP, float4(fog_center, 1.0));
                        if (lightClip.w > 0.0001)
                        {
                            debug_first_light_in_front = 1.0;
                            debug_first_light_screen_uv = lightClip.xy / lightClip.w * 0.5 + 0.5;
                        }
                    }
                    float dist01 = saturate(distance(worldspace, fog_center) / max(fog_radius, 0.0001));
                    if (dist01 < debug_min_dist01)
                    {
                        debug_min_dist01 = dist01;
                        debug_nearest_type01 = saturate((float)volumetric_type / 4.0);
                    }

                    float t = 0.0;
                    float intersected = 0.0;

                    if (volumetric_type == volumetric_type_sphere)
                    {
                            float3 ray = worldspace - _WorldSpaceCameraPos;
                        float rayLength = length(ray);

                        if (rayLength > 0.0001)
                        {
                            float3 rayDir = ray / rayLength;
                            float3 oc = _WorldSpaceCameraPos - fog_center;
                            float b = dot(oc, rayDir);
                            float c = dot(oc, oc) - (fog_radius * fog_radius);
                            float h = b * b - c;

                            if (h >= 0.0)
                            {
                                float sqrtH = sqrt(h);
                                float tEnter = max(0.0, -b - sqrtH);
                                float tExit = min(rayLength, -b + sqrtH);
                                float insideLength = tExit - tEnter;
                                debug_any_closest_point_in_sphere = 1.0;

                                if (insideLength > 0.0)
                                {
                                    intersected = 1.0;
                                    // Normalize by diameter so a full center pass approaches 1.
                                    t = saturate(insideLength / max(fog_radius * 2.0, 0.0001));
                                }
                            }
                        }
                    }
                    else if (volumetric_type == volumetric_type_box)
                    {
                        // define box bounds (min and max corners).
                        float3 boxMin = light.position - light.light_volumetricRadius * light_volumetricScale;
                        float3 boxMax = light.position + light.light_volumetricRadius * light_volumetricScale;

                        // compute the ray direction (from camera to the current fragment).
                        float3 rayDir = normalize(worldspace - _WorldSpaceCameraPos);

                        // get the distance to the current fragment in world space.
                        // tMax is limited by the maximum depth (geometry).
                        float tMin, tMax;
                        float maxDepth = length(worldspace - _WorldSpaceCameraPos);
                        if (ray_box_intersection(_WorldSpaceCameraPos, rayDir, boxMin, boxMax, tMin, tMax, maxDepth))
                        {
                            intersected = 1.0;
                        }

                        // compute the length of the ray segment inside the box.
                        float ray_length_in_box = tMax - tMin;
                                
                        // calculate the fog intensity based on the distance traveled inside the box.
                        t = ray_length_in_box / length(boxMax - boxMin); // normalize by box size.
                    }
                    else if (volumetric_type == volumetric_type_cone_y || volumetric_type == volumetric_type_cone_z)
                    {
                        // compute the ray direction (from camera to the current fragment).
                        float3 rayDir = normalize(worldspace - _WorldSpaceCameraPos);

                        // get the distance to the current fragment in world space.
                        float tMin, tMax;
                        float maxDepth = length(worldspace - _WorldSpaceCameraPos);

                        // Perform ray-cone intersection test
                        if (ray_cone_intersection(_WorldSpaceCameraPos, rayDir, light.position, light.forward, light_volumetricSpotAngle, light.light_volumetricRadius, tMin, tMax, maxDepth))
                        {
                            intersected = 1.0;
                            // compute the length of the ray segment inside the cone.
                            float ray_length_in_cone = tMax - tMin;

                            // calculate the fog intensity based on the distance traveled inside the cone.
                            t = ray_length_in_cone / light.light_volumetricRadius;
                        }
                    }

                    // apply smoothstep for a gradual fog transition near the edges.
                    t = smoothstep(0.0, 1.0, t);
                    debug_max_raw_t = max(debug_max_raw_t, t);
                    debug_any_intersection = max(debug_any_intersection, intersected);
                                
                    // apply the thickness to the fog that appears as a solid color.
                    t = saturate(t * light.light_volumetricThickness);
                        
                    // the distance from the camera to the world is used to make nearby geometry inside the fog visible.
                    float camera_distance_from_world = distance(_WorldSpaceCameraPos, worldspace) * light.volumetricVisibility;
                    debug_max_camera_to_world = max(debug_max_camera_to_world, camera_distance_from_world);
                        
                    // we only subtract from t so that naturally fading fog takes precedence.
                    t = min(t, camera_distance_from_world);
            
                    // let the user tweak the fog intensity with a multiplier.
                    t *= light.volumetricIntensity;
            
                    // remember the most opaque fog that we have encountered.
                    fog_final_t = max(fog_final_t, t);
            
                    // blend between the current color and the fog color.
                    fog_final = color_screen(fog_final, fog_color * t);
                }
                
                // DEBUG: Uncomment ONE of these lines to diagnose the issue:
                // return float4(debug_raw_t, debug_raw_t, debug_raw_t, 1);  // Test 15: Raw t from sphere
                // return float4(debug_closest_point_in_sphere, 0, 0, 1);  // Test 16: Closest point in sphere?
                // return float4(frac(_DL_WorldSpaceCameraPos * 0.1), 1);  // Test 17: Camera position (constant color)
                // return float4(distance(_DL_WorldSpaceCameraPos, debug_light_pos) * 0.1, 0, 0, 1);  // Test 18: Camera-to-light dist
                
                uint debugViewMode = (uint)round(_DL_DebugViewMode);
                if (debugViewMode == 1)
                {
                    return float4(depth, depth, depth, 1.0);
                }
                if (debugViewMode == 2)
                {
                    return float4(frac(abs(worldspace) * 0.05), 1.0);
                }
                if (debugViewMode == 3)
                {
                    float count01 = saturate(dynamic_lights_count / 8.0);
                    return float4(count01, 0.0, 0.0, 1.0);
                }
                if (debugViewMode == 4)
                {
                    return float4(debug_min_dist01, debug_min_dist01, debug_min_dist01, 1.0);
                }
                if (debugViewMode == 5)
                {
                    return float4(debug_any_intersection, debug_any_intersection, debug_any_intersection, 1.0);
                }
                if (debugViewMode == 6)
                {
                    return float4(debug_max_raw_t, debug_max_raw_t, debug_max_raw_t, 1.0);
                }
                if (debugViewMode == 7)
                {
                    return float4(fog_final_t, fog_final_t, fog_final_t, 1.0);
                }
                if (debugViewMode == 8)
                {
                    float vis01 = saturate(debug_max_camera_to_world);
                    return float4(vis01, vis01, vis01, 1.0);
                }
                if (debugViewMode == 9)
                {
                    return float4(fog_final.rgb, 1.0);
                }
                if (debugViewMode == 10)
                {
                    return float4(debug_nearest_type01, 0.0, 1.0 - debug_nearest_type01, 1.0);
                }
                if (debugViewMode == 11)
                {
                    float dotMask = 1.0 - saturate(distance(uv, debug_first_light_screen_uv) / 0.02);
                    return float4(dotMask, debug_first_light_in_front, 0.0, 1.0);
                }

                // special blend that allows for fully opaque fog.
                return lerp(color_screen(fog_final, color), fog_final, saturate(fog_final_t));
            }
            ENDHLSL
        }
    }
}

