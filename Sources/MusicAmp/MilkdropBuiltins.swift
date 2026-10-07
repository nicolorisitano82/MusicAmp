import Foundation

/// Presets shipped with MusicAmp (written for it, public domain like the app). More go in
/// ~/Library/Application Support/MusicAmp/Milkdrop as .milk files.
enum MilkdropBuiltins {
    static let all: [(String, String)] = [
        ("MusicAmp - Bass Tunnel", """
        [preset00]
        fDecay=0.960
        fGammaAdj=1.800
        nWaveMode=0
        fWaveScale=1.300
        fWaveAlpha=0.900
        bAdditiveWaves=1
        bMaximizeWaveColor=1
        fWarpScale=1.500
        warp=0.400
        zoom=1.020
        per_frame_1=wave_r = 0.5 + 0.5*sin(time*0.7);
        per_frame_2=wave_g = 0.5 + 0.5*sin(time*0.9 + 2);
        per_frame_3=wave_b = 0.5 + 0.5*sin(time*1.1 + 4);
        per_frame_4=zoom = 1.0 + 0.045*bass_att;
        per_frame_5=rot = 0.02*sin(time*0.3);
        per_pixel_1=zoom = zoom + 0.03*rad*sin(time + rad*6);
        """),
        ("MusicAmp - Spiral Drift", """
        [preset00]
        fDecay=0.970
        fGammaAdj=1.250
        nWaveMode=6
        fWaveScale=1.100
        fWaveAlpha=0.800
        bAdditiveWaves=1
        bWaveThick=1
        fVideoEchoZoom=1.300
        fVideoEchoAlpha=0.200
        nVideoEchoOrientation=1
        zoom=0.990
        warp=0.200
        per_frame_1=wave_mystery = sin(time*0.25);
        per_frame_2=wave_r = 0.6 + 0.4*sin(time*0.37); wave_g = 0.3 + 0.3*treb_att; wave_b = 0.8;
        per_frame_3=rot = 0.03 + 0.02*mid_att;
        per_pixel_1=rot = rot + 0.06*(1 - rad);
        per_pixel_2=zoom = zoom - 0.02*bass*(1 - rad);
        """),
        ("MusicAmp - Kaleido", """
        [preset00]
        fDecay=0.950
        fGammaAdj=1.300
        nWaveMode=7
        fWaveAlpha=0.700
        fWaveScale=0.900
        bAdditiveWaves=1
        zoom=0.990
        warp=0.600
        shapecode_0_enabled=1
        shapecode_0_sides=6
        shapecode_0_textured=1
        shapecode_0_rad=0.450
        shapecode_0_tex_zoom=1.500
        shapecode_0_a=0.600
        shapecode_0_a2=0.450
        shapecode_0_r=0.85
        shapecode_0_g=0.85
        shapecode_0_b=0.9
        shapecode_0_r2=0.8
        shapecode_0_g2=0.8
        shapecode_0_b2=0.9
        shapecode_0_border_a=0
        shape_0_per_frame1=ang = time*0.2; tex_ang = -time*0.13;
        shape_0_per_frame2=rad = 0.42 + 0.05*bass_att;
        per_frame_1=wave_r = 0.5 + 0.5*sin(time); wave_g = 0.5 + 0.5*sin(time*1.3 + 1); wave_b = 0.5 + 0.5*sin(time*1.7 + 2);
        per_frame_2=wave_mystery = 0.3*sin(time*0.5);
        """),
        ("MusicAmp - Spectrum Rain", """
        [preset00]
        fDecay=0.970
        fGammaAdj=1.700
        nWaveMode=4
        fWaveAlpha=0.000
        warp=0.000
        zoom=1.000
        dy=-0.006
        wavecode_0_enabled=1
        wavecode_0_bSpectrum=1
        wavecode_0_samples=256
        wavecode_0_bAdditive=1
        wavecode_0_bDrawThick=1
        wavecode_0_fScaling=1.000
        wavecode_0_smoothing=0.300
        wave_0_per_point1=x = sample; y = 0.92 - min(0.8, value1*0.7);
        wave_0_per_point2=r = sample; g = 0.5 + 0.5*sin(time + sample*6); b = 1 - sample; a = 0.9;
        per_frame_1=dy = -0.004 - 0.004*treb_att;
        per_frame_2=dx = 0.002*sin(time*0.4);
        """),
        ("MusicAmp - Beat Rings", """
        [preset00]
        fDecay=0.930
        fGammaAdj=1.500
        nWaveMode=0
        fWaveAlpha=0.500
        fWaveScale=0.700
        bAdditiveWaves=1
        zoom=1.030
        warp=0.300
        ob_size=0.010
        ob_r=0.2
        ob_g=0.4
        ob_b=1.0
        ob_a=0.500
        shapecode_0_enabled=1
        shapecode_0_sides=48
        shapecode_0_additive=1
        shapecode_0_thickOutline=1
        shapecode_0_a=0
        shapecode_0_a2=0
        shapecode_0_border_a=1
        shape_0_per_frame1=rad = 0.05 + 0.25*min(2, bass_att);
        shape_0_per_frame2=border_r = 0.5 + 0.5*sin(time*1.1); border_g = 0.5 + 0.5*sin(time*1.3 + 2); border_b = 1;
        shapecode_1_enabled=1
        shapecode_1_sides=48
        shapecode_1_additive=1
        shapecode_1_a=0
        shapecode_1_a2=0
        shapecode_1_border_a=0.8
        shape_1_per_frame1=rad = 0.03 + 0.2*min(2, treb_att); border_r = 1; border_g = 0.6; border_b = 0.2;
        per_frame_1=zoom = 1.02 + 0.03*bass;
        per_frame_2=wave_r = 0.3; wave_g = 0.7; wave_b = 1;
        """),
        ("MusicAmp - Liquid Plasma", """
        [preset00]
        fDecay=0.940
        fGammaAdj=1.250
        nWaveMode=4
        fWaveAlpha=0.500
        fWaveScale=1.200
        bAdditiveWaves=1
        bWaveThick=1
        bDarkenCenter=1
        fWarpAnimSpeed=1.500
        fWarpScale=2.000
        warp=1.800
        zoom=1.000
        nMotionVectorsX=24
        nMotionVectorsY=18
        mv_a=0.080
        mv_l=1.000
        mv_r=0.4
        mv_g=0.7
        mv_b=1.0
        per_frame_1=wave_r = 0.5 + 0.5*sin(time*0.5); wave_g = 0.4; wave_b = 0.5 + 0.5*cos(time*0.6);
        per_frame_2=wave_y = 0.5 + 0.2*sin(time*0.7);
        per_frame_3=q1 = 0.004 + 0.004*mid_att;
        per_pixel_1=dx = q1*sin(y*10 + time);
        per_pixel_2=dy = q1*cos(x*10 + time*1.3);
        """),
    ]

    static var presets: [MilkPreset] { all.map { MilkPreset.parse($0.1, name: $0.0) } }
}
