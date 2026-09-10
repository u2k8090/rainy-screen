#include <metal_stdlib>
using namespace metal;
struct Uniforms {
    float2 size; float2 mouse; float2 previousMouse;
    float dt; float intensity; float time; float wipeRadius; float hasCapture; float wipe; float blowerClearStrength; float dropScale; float mist;
    float exclusionCount; float sweepStart; float sweepEnd; float sweepAxis; float chromaticAberration;
};
struct Drop { float2 position; float2 radius; float strength; float phase; float tilt; float kind; float2 endWidthRatio; };
struct Vertex { float4 position [[position]]; float2 uv; float strength; float phase; float kind; float2 radius; float2 widths; };
float hash21(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float noise(float2 p) {
    float2 i = floor(p),f = fract(p); f = f*f*(3-2*f);
    return mix(mix(hash21(i),hash21(i+float2(1,0)),f.x),mix(hash21(i+float2(0,1)),hash21(i+1),f.x),f.y);
}
float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        value += amplitude * noise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        amplitude *= 0.5;
    }
    return value;
}
vertex Vertex fullVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2,id & 2);
    return {float4(p*float2(2,-2)+float2(-1,1),0,1),p,1,0,0,float2(1),float2(0)};
}
vertex Vertex dropVertex(uint id [[vertex_id]],uint instance [[instance_id]],
                        constant Drop *drops [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
    float2 corners[] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,-1),float2(1,1),float2(-1,1)};
    Drop d = drops[instance];
    if(d.kind > 1.5) {
        float2 uv = corners[id];
        float2 p;
        if(d.kind > 2.5) {
            // Vertical wipe: the ridge runs along X and the collected water
            // extends downward toward the moving boundary.
            p = d.position+float2(uv.x*d.radius.x,(uv.y+1)*0.5*d.radius.y);
        } else {
            // Horizontal wipe: the ridge runs along Y and the collected water
            // extends rightward toward the moving boundary.
            p = d.position+float2((uv.x+1)*0.5*d.radius.x,uv.y*d.radius.y);
        }
        return {float4(p/u.size*float2(2,-2)+float2(-1,1),0,1),uv,d.strength,d.phase,d.kind,d.radius,float2(d.phase,d.tilt)};
    }
    float2 local = corners[id]*1.12*d.radius;
    float2 p = d.position + float2(local.x*cos(d.tilt)-local.y*sin(d.tilt),local.x*sin(d.tilt)+local.y*cos(d.tilt));
    return {float4(p/u.size*float2(2,-2)+float2(-1,1),0,1),corners[id]*1.12,d.strength,d.phase,d.kind,d.radius,float2(d.phase,d.endWidthRatio.x)};
}
fragment float4 dropFragment(Vertex in [[stage_in]]) {
    float2 p = in.uv;
    if(in.kind > 1.5) {
        float t;
        float across;
        float width;
        if(in.kind > 2.5) {
            // Vary the depth along the horizontal ridge, producing one
            // continuous band instead of independent vertical streaks.
            t = (p.x+1)*0.5;
            width = mix(in.widths.x,in.widths.y,t*t*(3-2*t));
            across = (p.y+1)*0.5*in.radius.y/max(0.001,width);
        } else {
            t = (p.y+1)*0.5;
            width = mix(in.widths.x,in.widths.y,t*t*(3-2*t));
            across = (p.x+1)*0.5*in.radius.x/max(0.001,width);
        }
        float cap = sqrt(max(0.0,4*across*(1-across)));
        // Integral of this cap is pi/4; depth and width reproduce the
        // cross-sectional area owned by the model, with no noise bands.
        return float4(cap*width*(0.12/0.785398),0,0,0);
    }
    if(in.kind > 1.3) {
        // Taper between shared endpoint widths instead of stepping the width
        // at each capsule. Endpoint caps keep neighboring samples connected.
        float2 q = p*in.radius;
        float halfLength = max(0.001,in.radius.y-in.radius.x);
        float along = clamp(q.y,-halfLength,halfLength);
        float t = (along+halfLength)/(2*halfLength);
        float width = in.radius.x*mix(in.widths.x,in.widths.y,t);
        float r = length(float2(q.x,q.y-along))/max(0.001,width);
        float cap = sqrt(max(0.0,1-r*r));
        float depth = width*in.strength;
        return float4(cap*depth,cap*min(1.0,depth*0.55),0,0);
    }
    if(in.kind > 0.5) {
        // Rounded continuous capsules. Max blending prevents overlapping trail samples from piling up.
        float2 q = p*in.radius;
        q.y = max(abs(q.y)-(in.radius.y-in.radius.x),0.0);
        float r = length(q)/in.radius.x;
        float cap = sqrt(max(0.0,1-r*r));
        // Through-flow trails use a lower, unsaturated flow gain so their
        // moisture-clearing effect follows the birth/fade envelope instead
        // of staying flat and then dropping to zero at the end.
        float flowGain = in.kind > 1.1 ? 0.55 : 5.0;
        return float4(cap*in.strength,cap*min(1.0,in.strength*flowGain),0,0);
    }
    // Spherical cap with a non-circular contact line; the lower edge is fuller than the upper edge.
    float angle = atan2(p.y,p.x);
    float contact = 1 + 0.045*sin(angle*3+in.phase) + 0.027*sin(angle*5-in.phase);
    p.x *= 1 - 0.08*p.y;
    float r2 = dot(p,p)/(contact*contact);
    float cap = pow(max(0.0,1-r2),0.62);
    return float4(cap*in.strength,0,0,0);
}
kernel void moisture(texture2d<float,access::read> old [[texture(0)]],
                     texture2d<float,access::write> next [[texture(1)]],
                     texture2d<float,access::sample> water [[texture(2)]],
                     constant Uniforms &u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=next.get_width() || gid.y>=next.get_height()) return;
    float2 uv = (float2(gid)+0.5)/float2(next.get_width(),next.get_height());
    float2 p = uv*u.size;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float wet = old.read(gid).r;
    float front = smoothstep(0.0,8.0,u.time);
    float patch = 0.55+0.65*noise(p*0.008)+0.15*noise(p*0.033);
    if(u.intensity <= 0.001) {
        // Keep the pane alive after rain stops and let condensation fade
        // naturally instead of clearing the glass in a single frame.
wet *= exp(-u.dt*0.16);
    } else {
        // Mist wets the pane at the heavy-rain rate while keeping its beads
        // small and mostly pinned to the glass.
float wetIntensity = u.mist > 0.5 ? 3.8 : u.intensity;
        wet = min(1.0,wet+u.dt*wetIntensity*0.011*front*patch);
    }
    // Running water sweeps condensation away; the cleared channel slowly fogs over again.
    float flow = water.sample(s,uv).g;
wet *= exp(-u.dt*flow*10);
    // Condensation is a coverage field, separate from the conserved CPU beads.
    float sweepCoordinate = u.sweepAxis > 0.5 ? p.y : p.x;
    if(u.sweepEnd > u.sweepStart && sweepCoordinate >= u.sweepStart && sweepCoordinate < u.sweepEnd) wet = 0;
    if(u.wipe > 0.5) {
        float2 d = u.mouse-u.previousMouse;
        float t = clamp(dot(p-u.previousMouse,d)/max(dot(d,d),0.001),0.0,1.0);
        float distance = length(p-u.previousMouse-t*d);
        wet *= smoothstep(u.wipeRadius*0.76,u.wipeRadius,distance);
    }
    if(u.blowerClearStrength > 0.0) {
        float distance = length(p-u.mouse);
        float coverage = 1.0-smoothstep(u.wipeRadius*0.72,u.wipeRadius,distance);
        wet *= exp(-u.dt*u.blowerClearStrength*4.0*coverage);
    }
    next.write(float4(wet,0,0,1),gid);
}
// The experimental film source duplicated bead volume. Keep this buffer empty
// while the contact-boundary model owns the water and its deposited trails.
kernel void hoseFlow(texture2d<float,access::sample> old [[texture(0)]],
                     texture2d<float,access::write> next [[texture(1)]],
                     texture2d<float,access::sample> water [[texture(2)]],
                     constant Uniforms &u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=next.get_width() || gid.y>=next.get_height()) return;
    next.write(float4(0),gid);
}
fragment float4 glassFragment(Vertex in [[stage_in]],texture2d<float> height [[texture(0)]],
                              texture2d<float> wetness [[texture(1)]],texture2d<float> desktop [[texture(2)]],
                              texture2d<float> softScene [[texture(3)]],texture2d<float> fogScene [[texture(4)]],texture2d<float> film [[texture(5)]],
                              constant Uniforms &u [[buffer(0)]],constant float4 *excluded [[buffer(1)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv = in.uv, p = uv*u.size, px = 1/u.size;
    // Allowlisted app windows are rendered as transparent holes in the rain
    // surface, so their real content remains crisp and visually in front.
    for (int i = 0; i < 16; i++) {
        if (float(i) >= u.exclusionCount) { break; }
        float4 rect = excluded[i];
        if (p.x >= rect.x && p.x <= rect.z && p.y >= rect.y && p.y <= rect.w) {
            return float4(0);
        }
    }
    float wet = wetness.sample(s,uv).r;
    float h = height.sample(s,uv).r;
    float trailFlow = height.sample(s,uv).g;
    float deluge = u.intensity >= 3.8
        ? (abs(u.intensity-3.8) < 0.01 ? 0.4 : smoothstep(3.8,5.6,u.intensity))
        : 0.0;
    float trailThickness = clamp(trailFlow,0.0,1.0)*deluge;
    float2 texel = 1.0/float2(height.get_width(),height.get_height());
    float2 stepPoints = texel*u.size;
    float2 gradient = float2(height.sample(s,uv+float2(texel.x,0)).r-height.sample(s,uv-float2(texel.x,0)).r,
                             height.sample(s,uv+float2(0,texel.y)).r-height.sample(s,uv-float2(0,texel.y)).r)/(2*stepPoints);
    float2 trailGradient = float2(height.sample(s,uv+float2(texel.x,0)).g-height.sample(s,uv-float2(texel.x,0)).g,
                                  height.sample(s,uv+float2(0,texel.y)).g-height.sample(s,uv-float2(0,texel.y)).g)/(2*stepPoints);
    // A moving bead leaves a thin rivulet. Its flow channel contributes to
    // the optical surface even after the bead itself has moved on.
    gradient += trailGradient*(0.72+deluge*0.45);
    // In a downpour the track is a thicker water lens, not only a brighter
    // line. Increase its optical depth so refraction and edge separation have
    // enough surface to read against the desktop.
    h += trailFlow*(0.58+deluge*0.42);
    // Thousands of sub-pixel condensation beads, analytically shaded without CPU particles.
    float2 microPoint = p/u.dropScale;
    float2 cell = floor(microPoint/9.5), local = fract(microPoint/9.5)*9.5;
    float seed = hash21(cell);
    float2 center = float2(2.5,2.5)+float2(hash21(cell+31),hash21(cell+73))*4.5;
    float microRadius = 0.45+seed*1.35;
    float2 microP = (local-center)/microRadius;
    float microR2 = dot(microP,microP);
    float microPresence = smoothstep(0.04,0.26,wet)*smoothstep(0.12,0.7,seed);
    float microH = max(0.0,1-microR2)*microRadius*0.38*microPresence*u.dropScale;
    if(h < microH) { h = microH; gradient = -2*microP*0.38*microPresence*(microR2<1 ? 1.0 : 0.0); }
    float ringRadius = 1.0+hash21(cell+91.4)*1.6;
    float ring = (1.0-smoothstep(0.0,0.24,abs(length(local-center)-ringRadius)))
               *smoothstep(0.58,0.88,seed)*microPresence*0.62;
    h += ring;
    gradient += normalize(float2(local-center)+float2(0.001))*ring*0.055;
    // All surface normals below come from the beads and their deposited trails.
    // No procedural bands or clear-progress-driven optical layer.
    float hose = 0, sheetLayer = 0, bandLayer = 0, depth = 0;
    float turbulence = 0, detail = 0, rippleB = 0;
    float dropCoverage = smoothstep(0.015,0.18,h);
    float3 N = normalize(float3(-gradient,1));
    float cosTheta = clamp(N.z,0.0,1.0);
    // Snell refraction for air -> water, and Schlick Fresnel (water IOR 1.333).
    float3 transmitted = refract(float3(0,0,-1),N,1.0/1.333);
    float opticalDepth = h+trailThickness*0.55;
    float2 displacement = transmitted.xy/max(0.3,-transmitted.z)*(30+opticalDepth*8.0);
    float2 broadWarp = float2(
        fbm(p*0.013+float2(u.time*0.030,-u.time*0.020)),
        fbm(p*0.013+float2(8.3-u.time*0.025,4.7+u.time*0.018))) - 0.5;
    float2 bandWarp = float2(
        fbm(p*0.041+float2(-u.time*0.08,u.time*0.33)),
        fbm(p*0.041+float2(5.2+u.time*0.07,-u.time*0.29))) - 0.5;
    float2 refracted = clamp(uv+displacement*px+broadWarp*(0.010*sheetLayer)
                             +bandWarp*(0.032*bandLayer),float2(0),float2(1));
    float fresnel = 0.02037+(1-0.02037)*pow(1-cosTheta,5.0);
    float waterCoverage = max(dropCoverage,max(smoothstep(0.04,0.62,depth),max(sheetLayer*0.58,bandLayer*0.72)));
    float patch = 0.68+0.32*noise(p*0.007)+0.08*noise(p*0.043);
    float fog = max(clamp(pow(wet,1.15)*patch*1.35,0.0,0.985)*(1-hose*0.12),
                    sheetLayer*(0.38+0.16*hose));
    float3 reflectionDirection = reflect(float3(0,0,-1),N);
    float keyLight = pow(max(0.0,dot(reflectionDirection,normalize(float3(-0.45,-0.65,1)))),72.0);
    float rim = pow(1-cosTheta,2.0);
    // A virtual window/sky supplies off-screen illumination. Reflecting only the
    // dark desktop would make a physically transparent bead almost disappear.
    float windowPanel = exp(-pow(abs((reflectionDirection.x+0.38)/0.25),4.0)
                            -pow(abs((reflectionDirection.y+0.20)/0.65),4.0));
    float windowBar = exp(-pow(abs((reflectionDirection.x+0.43)/0.065),2.0))
                      *smoothstep(-0.9,-0.55,reflectionDirection.y)
                      *(1-smoothstep(0.35,0.7,reflectionDirection.y));
    float skyAmount = smoothstep(-0.7,0.65,-reflectionDirection.y);
    float3 sky = mix(float3(0.075,0.095,0.13),float3(1.15,1.35,1.6),skyAmount);
    float3 studio = sky+windowPanel*float3(2.2,2.35,2.5)+windowBar*float3(4.5,4.8,5.1);
    if(u.hasCapture > 0.5) {
        float3 clean = desktop.sample(s,uv).rgb;
        float3 fogged = mix(softScene.sample(s,uv).rgb,fogScene.sample(s,uv).rgb,smoothstep(0.15,0.95,wet));
        fogged = mix(fogged,float3(0.71,0.75,0.76),wet*0.065);
        // Weak chromatic dispersion, confined to the lens edge.
        float3 transmittedColor;
        float chromaticGain = 0.008*u.chromaticAberration*(1.0+trailThickness*2.8);
        transmittedColor.r = desktop.sample(s,refracted+displacement*px*chromaticGain).r;
        transmittedColor.g = desktop.sample(s,refracted).g;
        transmittedColor.b = desktop.sample(s,refracted-displacement*px*chromaticGain).b;
        transmittedColor *= exp(-float3(0.006,0.0025,0.0015)*h);
        transmittedColor = mix(transmittedColor,fogged,clamp(sheetLayer*0.68,0.0,0.82));
        // Inside a runoff lane, nearby rays arrive from slightly different
        // points. Averaging those samples gives a soft, wavering image instead
        // of a bright drawn stripe.
        float2 rippleOffset = bandWarp*0.012;
        float3 bandBlur = (desktop.sample(s,refracted+rippleOffset).rgb
                         + desktop.sample(s,refracted).rgb
                         + desktop.sample(s,refracted-rippleOffset).rgb)/3.0;
        transmittedColor = mix(transmittedColor,bandBlur,clamp(bandLayer*0.58,0.0,0.62));
        float3 filmTint = float3(0.17,0.26,0.29)*(0.62+0.38*turbulence);
        transmittedColor = mix(transmittedColor,transmittedColor*0.72+filmTint,clamp(sheetLayer*0.28,0.0,0.28));
        float2 environmentUV = clamp(uv+reflectionDirection.xy*0.19,float2(0),float2(1));
        float3 environment = softScene.sample(s,environmentUV).rgb*0.65+studio*0.35;
        float roughReflection = max(fresnel, max(sheetLayer*(0.08+0.16*noise(p*0.027+float2(0,u.time*0.12))),
                                                   bandLayer*(0.025+0.035*rippleB)));
        float3 waterColor = mix(transmittedColor,environment,roughReflection);
        float sheetGlint = (sheetLayer*0.22+bandLayer*0.08)*pow(max(0.0,dot(reflectionDirection,normalize(float3(-0.55,-0.72,1)))),24.0)
                         *(0.30+0.70*noise(p*0.035+float2(u.time*0.11,-u.time*0.07)));
        waterColor += keyLight*(0.20-0.16*hose) + rim*(0.045-0.030*hose) + studio*sheetGlint*0.030 + studio*sheetLayer*detail*0.008;
        waterColor += float3(0.34,0.43,0.48)*ring*(0.45+0.35*hose);
        waterColor *= 1-rim*0.12;
        // Premultiplied alpha preserves an untouched, zero-latency desktop in wiped regions.
        float shadowHeight = height.sample(s,uv-float2(1.1,2.0)*px).r;
        float shadow = smoothstep(0.08,0.55,shadowHeight)*(1-waterCoverage)*0.10*(1-hose);
        float baseAlpha = fog+shadow*(1-fog);
        float alpha = baseAlpha*(1-waterCoverage)+waterCoverage;
        float3 color = fogged*fog*(1-shadow)*(1-waterCoverage)+waterColor*waterCoverage;
        float4 composed = float4(color+clean*(1-alpha),1);
        return composed;
    }
    float reflection = clamp(fresnel*(windowPanel*2+windowBar*2),0.0,0.65);
    float alpha = min(0.65,fog*0.30+waterCoverage*(rim*0.30+0.025+reflection));
    float3 tint = float3(0.49,0.54,0.57)+keyLight*0.3+reflection-rim*0.22;
    return float4(tint*alpha,alpha);
}
