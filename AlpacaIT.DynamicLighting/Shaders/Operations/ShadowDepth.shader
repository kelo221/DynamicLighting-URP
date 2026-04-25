Shader "Hidden/Dynamic Lighting/ShadowDepth"
{
    Properties
    {
        _Color("Main Color", Color) = (1,1,1,1)
        _MainTex("Base (RGB)", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)
        _BaseMap("Base Map", 2D) = "white" {}
        _Cutoff("Alpha Cutoff", Range(0,1)) = 0.5
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        LOD 100

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            struct appdata
            {
                float4 vertex : POSITION;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float3 world : TEXCOORD1;
            };

            float dynamic_lighting_shadow_depth_light_radius;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = TransformObjectToHClip(v.vertex.xyz);
                o.world = TransformObjectToWorld(v.vertex.xyz);
                return o;
            }

            float2 frag (v2f i) : SV_Target
            {
                float dist = distance(_WorldSpaceCameraPos, i.world) / dynamic_lighting_shadow_depth_light_radius;
                return float2(dist, dist * dist);
            }

            ENDHLSL
        }

        Pass
        {
            Name "ShadowDepthAlpha"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv0 : TEXCOORD0;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float2 uv0 : TEXCOORD0;
                float3 world : TEXCOORD1;
                float2 uvBase : TEXCOORD2;
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            float4 _MainTex_ST;
            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            float4 _BaseMap_ST;
            float4 _Color;
            float4 _BaseColor;
            float _Cutoff;
            float dynamic_lighting_shadow_depth_light_radius;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = TransformObjectToHClip(v.vertex.xyz);
                o.world = TransformObjectToWorld(v.vertex.xyz);
                o.uv0 = TRANSFORM_TEX(v.uv0, _MainTex);
                o.uvBase = TRANSFORM_TEX(v.uv0, _BaseMap);
                return o;
            }

            float2 frag (v2f i) : SV_Target
            {
                float mainAlpha = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv0).a * _Color.a;
                float baseAlpha = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, i.uvBase).a * _BaseColor.a;
                clip(min(mainAlpha, baseAlpha) - _Cutoff);

                float dist = distance(_WorldSpaceCameraPos, i.world) / dynamic_lighting_shadow_depth_light_radius;
                return float2(dist, dist * dist);
            }

            ENDHLSL
        }
    }
    
    SubShader
    {
        Tags { "Queue"="Transparent" "IgnoreProjector"="True" "RenderType" = "Transparent" }
        LOD 100

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv0 : TEXCOORD0;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float2 uv0 : TEXCOORD0;
                float3 world : TEXCOORD1;
                float2 uvBase : TEXCOORD2;
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            float4 _MainTex_ST;
            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            float4 _BaseMap_ST;
            float4 _Color;
            float4 _BaseColor;
            float _Cutoff;
            float dynamic_lighting_shadow_depth_light_radius;
            
            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = TransformObjectToHClip(v.vertex.xyz);
                o.world = TransformObjectToWorld(v.vertex.xyz);
                o.uv0 = TRANSFORM_TEX(v.uv0, _MainTex);
                o.uvBase = TRANSFORM_TEX(v.uv0, _BaseMap);
                return o;
            }

            float2 frag (v2f i) : SV_Target
            {
                float mainAlpha = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv0).a * _Color.a;
                float baseAlpha = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, i.uvBase).a * _BaseColor.a;
                float alpha = min(mainAlpha, baseAlpha);
                if (alpha > _Cutoff)
                {
                    float dist = distance(_WorldSpaceCameraPos, i.world) / dynamic_lighting_shadow_depth_light_radius;
                    return float2(dist, dist * dist);
                }
                else
                {
                    discard;
                    return float2(0.0, 0.0); // hlsl compiler wants us to return something- never gets executed.
                }
            }

            ENDHLSL
        }
    }

    SubShader
    {
        Tags { "Queue"="Transparent" "IgnoreProjector"="True" "RenderType" = "TransparentCutout" }
        LOD 100

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv0 : TEXCOORD0;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float2 uv0 : TEXCOORD0;
                float3 world : TEXCOORD1;
                float2 uvBase : TEXCOORD2;
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            float4 _MainTex_ST;
            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            float4 _BaseMap_ST;
            float4 _Color;
            float4 _BaseColor;
            float _Cutoff;
            float dynamic_lighting_shadow_depth_light_radius;
            
            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = TransformObjectToHClip(v.vertex.xyz);
                o.world = TransformObjectToWorld(v.vertex.xyz);
                o.uv0 = TRANSFORM_TEX(v.uv0, _MainTex);
                o.uvBase = TRANSFORM_TEX(v.uv0, _BaseMap);
                return o;
            }

            float2 frag (v2f i) : SV_Target
            {
                float mainAlpha = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv0).a * _Color.a;
                float baseAlpha = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, i.uvBase).a * _BaseColor.a;
                float alpha = min(mainAlpha, baseAlpha);
                if (alpha > _Cutoff)
                {
                    float dist = distance(_WorldSpaceCameraPos, i.world) / dynamic_lighting_shadow_depth_light_radius;
                    return float2(dist, dist * dist);
                }
                else
                {
                    discard;
                    return float2(0.0, 0.0); // hlsl compiler wants us to return something- never gets executed.
                }
            }

            ENDHLSL
        }
    }
    Fallback "Diffuse"
}
