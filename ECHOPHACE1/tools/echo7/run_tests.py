#!/usr/bin/env python3
"""ECHO-7 team / AI-assisted by OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
Run self-checking RTL tests with an existing Verilator or ModelSim. No installation or cleanup.
Usage: python tools/echo7/run_tests.py [--simulator verilator|modelsim] [--regression]
Each invocation uses a fresh directory; old results are retained.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
ECHO=['rtl/echo7/'+x+'.sv' for x in ('rgbFixedSeg','rgbRatioSeg','hsvSeg','segmentationSelector','vgaMaskOverlay')]
DIAG=['rtl/echo7/'+x+'.sv' for x in ('echo7_diag_pkg','unsignedDivider','colourRegionStats',
    'colourMeanHsv','diagnosticFont','diagnosticRenderer','colourDiagnostics','roiCalibrationRenderer','roiCalibration','videoDiagnostics')]
SAFETY=['rtl/uart_tx.sv', 'rtl/safety/irEmergencyStop.sv', 'rtl/safety/controlWatchdog.sv', 'rtl/safety/ultrasonicSafety.sv', 'rtl/safety/motorSafetyArbiter.sv', 'rtl/safety/motorSafetyController.sv', 'rtl/safety/irMotionControl.sv', 'rtl/safety/safeChassisCommand.sv', 'rtl/safety/sonarSampleCdc.sv', 'rtl/safety/dualSonar.sv', 'rtl/safety/safetyHex.sv', 'rtl/safety/safetySystem.sv', 'rtl/safety/necDecoderSafe.sv', 'rtl/safety/reference/ir_drive.sv', 'rtl/safety/reference/uart_rx.sv', 'rtl/safety/reference/sonar_range.sv', 'rtl/safety/reference/sonar_pll.sv']
BASE=['rtl/camera_pkg.sv']+ECHO+DIAG
REF=['tb/echo7/echo7_ref_pkg.sv']
DREF=REF+['tb/echo7/echo7_diag_ref_pkg.sv']
TESTS={
    'safety_unit_tb': SAFETY+['tb/safety/safety_unit_tb.sv'],
    'uartSafety_tb': SAFETY+['tb/safety/uartSafety_tb.sv'],
    'irSafety_tb': SAFETY+['tb/safety/irSafety_tb.sv'],
    'sonarSafety_tb': SAFETY+['tb/safety/sonarSafety_tb.sv'],

    "rotation_tb": BASE+DREF+["rtl/frame_buffer.sv","rtl/camera_display.sv","tb/echo7/rotation_tb.sv"],
    "roiCalibration_protocol_tb": BASE+["tb/echo7/roiCalibration_protocol_tb.sv"],
    "roiCalibration_tb": BASE+DREF+["tb/echo7/roiCalibration_tb.sv"],
    'echo7_algorithms_tb': BASE+REF+['tb/echo7/echo7_algorithms_tb.sv'],
    'vgaMaskOverlay_tb': BASE+REF+['tb/echo7/vgaMaskOverlay_tb.sv'],
    'echo7_stream_tb': BASE+REF+['tb/echo7/echo7_stream_tb.sv'],
    'echo7_integration_tb': BASE+REF+['rtl/frame_buffer.sv','rtl/camera_display.sv','tb/echo7/echo7_integration_tb.sv'],
    'unsignedDivider_tb': BASE+['tb/echo7/unsignedDivider_tb.sv'],
    'colourMeanHsv_tb': BASE+DREF+['tb/echo7/colourMeanHsv_tb.sv'],
    'colourRegionStats_tb': BASE+DREF+['tb/echo7/colourRegionStats_tb.sv'],
    'diagnosticRenderer_tb': BASE+DREF+['tb/echo7/diagnosticRenderer_tb.sv'],
    'echo7_diagnostics_tb': BASE+DREF+['rtl/frame_buffer.sv','rtl/camera_display.sv','tb/echo7/echo7_diagnostics_tb.sv'],
    'colourDiagnostics_protocol_tb': BASE+REF+['tb/echo7/colourDiagnostics_protocol_tb.sv'],
}
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--verilator',default='verilator')
    ap.add_argument('--simulator',choices=['verilator','modelsim'],default='verilator')
    ap.add_argument('--modelsim-bin',type=Path)
    ap.add_argument('--tests',nargs='+',choices=sorted(TESTS))
    ap.add_argument('--timeout',type=int,default=1200)
    ap.add_argument('--regression',action='store_true')
    args=ap.parse_args()
    stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    run=ROOT/'work'/'echo7_tests'/stamp
    run.mkdir(parents=True)
    summary={'tool':None,'simulator':args.simulator,'course_preferred':'Verilator 5.050','results':[], 'rtl_simulation_executed':False}
    tests={name:TESTS[name] for name in args.tests} if args.tests else dict(TESTS)
    def save():
        (run/'summary.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    exe=shutil.which(args.verilator) if args.simulator=='verilator' else shutil.which(
        str(args.modelsim_bin/'vsim.exe') if args.modelsim_bin else 'vsim')
    if not exe:
        summary['results']=[{'test':name,'status':'NOT_RUN'} for name in tests]
        summary['status']='BLOCKED: '+args.simulator+' executable not found; no RTL test executed'
        save(); print(summary['status']); print(run); return 2
    try:
        version=subprocess.run([exe,'--version' if args.simulator=='verilator' else '-version'],capture_output=True,text=True)
    except OSError as exc:
        summary['status']='BLOCKED: simulator cannot start'; summary['error']=str(exc)
        summary['results']=[{'test':name,'status':'NOT_RUN'} for name in tests]
        save(); print(summary['status']); print(run); return 2
    summary['tool']=version.stdout.strip()
    if version.returncode:
        summary['status']='BLOCKED: simulator cannot start'; save(); print(summary['status']); return 2
    print(summary['tool'])
    if args.simulator=='verilator' and not re.search(r'Verilator\s+5\.050\b',version.stdout):
        print('NOTE: installed Verilator differs from course-preferred 5.050; recorded in summary.')
    if args.regression:
        tests['ov7670_capture_tb']=['rtl/ov7670_capture.sv','tb/ov7670_model.sv','tb/ov7670_capture_tb.sv']
        tests['frame_buffer_tb']=['rtl/frame_buffer.sv','tb/frame_buffer_tb.sv']
        tests['camera_display_tb']=['rtl/camera_pkg.sv','rtl/frame_buffer.sv','rtl/camera_display.sv','tb/vga_monitor_model.sv','tb/camera_display_tb.sv']
        tests['camera_system_tb']=BASE+SAFETY+['rtl/clock_divider.sv','rtl/i2c_master.sv','rtl/ov7670_config.sv',
            'rtl/ov7670_capture.sv','rtl/frame_buffer.sv','rtl/camera_display.sv','rtl/video_pll.sv','rtl/top_level.sv',
            'tb/ov7670_model.sv','tb/vga_monitor_model.sv','tb/vga_sink_sim.sv','tb/camera_system_tb.sv']
    failed=False
    for name,sources in tests.items():
        wd=run/name; wd.mkdir()
        source_paths=[str(ROOT/x) for x in sources]
        if args.simulator=='verilator':
            cmd=[exe,'--binary','--timing','--assert','-Wall','-Wno-fatal','--top-module',name,
                 '--Mdir',str(wd/'obj'),'-o',name,'-j','2']+source_paths
        else:
            bin_dir=Path(exe).parent
            library=wd/'simlib'
            with (wd/'library.log').open('w',encoding='utf-8') as log:
                lib=subprocess.run([str(bin_dir/'vlib.exe'),str(library)],cwd=wd,stdout=log,stderr=subprocess.STDOUT)
            if lib.returncode:
                summary['results'].append({'test':name,'status':'BUILD_FAIL','reason':'vlib failed'})
                failed=True; save(); continue
            cmd=[str(bin_dir/'vlog.exe'),'-sv','-work',str(library)]+source_paths
        result={'test':name,'status':'NOT_RUN','command':cmd}
        with (wd/'build.log').open('w',encoding='utf-8') as log:
            build=subprocess.run(cmd,cwd=wd,stdout=log,stderr=subprocess.STDOUT)
        if build.returncode:
            result['status']='BUILD_FAIL'; failed=True
        else:
            if args.simulator=='verilator':
                binary=wd/'obj'/name
                if os.name=='nt' and not binary.exists(): binary=binary.with_suffix('.exe')
                sim_cmd=[str(binary)]
            else:
                sim_cmd=[exe,'-c','-onfinish','exit','-lib',str(library),name,
                    '-do','onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0']
            result['simulation_command']=sim_cmd
            try:
                with (wd/'simulation.log').open('w',encoding='utf-8') as log:
                    sim=subprocess.run(sim_cmd,cwd=wd,stdout=log,stderr=subprocess.STDOUT,timeout=args.timeout)
                summary['rtl_simulation_executed']=True
                output=(wd/'simulation.log').read_text(encoding='utf-8',errors='replace')
                ok=sim.returncode==0 and 'PASS' in output and not re.search(r'\bFAIL(?:ED)?\b|%Error|Fatal:|\*\*\s+(?:Error|Fatal)',output)
                result['status']='PASS' if ok else 'FAIL'
                failed|=not ok
            except subprocess.TimeoutExpired:
                result['status']='TIMEOUT'; failed=True
            except OSError as exc:
                result['status']='EXECUTION_ERROR'; result['error']=str(exc); failed=True
        summary['results'].append(result); save(); print(name+': '+result['status'])
    summary['status']='FAIL' if failed else 'PASS'; save(); print(run)
    return 1 if failed else 0
if __name__=='__main__': sys.exit(main())
