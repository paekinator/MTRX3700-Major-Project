param([string]$ModelSimBin='C:\intelFPGA_lite\18.1\modelsim_ase\win32aloem')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath (Join-Path $root 'sim')
try {
 & (Join-Path $ModelSimBin 'vlog.exe') -sv '+define+VERILATOR' -work work -l extra_compile.log (Join-Path $PSScriptRoot 'integration/perceptionCoreReplay_tb.sv') (Join-Path $PSScriptRoot 'integration/tb_v2_pixel_latency.sv')
 if($LASTEXITCODE -ne 0){throw 'Extra tests compile failed'}
 & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish exit -l tb_v2_collision.log work.perceptionCoreReplay_tb '+COLLISION_ONLY' -do (Join-Path $PSScriptRoot 'run.do')
 if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath tb_v2_collision.log -Pattern 'PASS perceptionCoreCollision_tb' -SimpleMatch -Quiet)){throw 'new B collision regression failed'}
 & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish exit -l tb_v2_pixel_latency.log work.tb_v2_pixel_latency -do (Join-Path $PSScriptRoot 'run.do')
 if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath tb_v2_pixel_latency.log -Pattern 'PASS: tb_v2_pixel_latency' -SimpleMatch -Quiet)){throw 'pixel latency failed'}
}finally{Pop-Location}
