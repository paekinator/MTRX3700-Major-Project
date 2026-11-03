param([string]$ModelSimBin='C:\intelFPGA_lite\18.1\modelsim_ase\win32aloem',[switch]$PinsOnly,[switch]$SkipPins,[string]$Only="")
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$sim=Join-Path $root 'sim'
New-Item -ItemType Directory -Path $sim -Force | Out-Null
Push-Location -LiteralPath $sim
try {
 if(!(Test-Path work)){ & (Join-Path $ModelSimBin 'vlib.exe') work; if($LASTEXITCODE -ne 0){throw 'vlib failed'} }
 $sources=@()
 foreach($line in Get-Content (Join-Path $root 'quartus/PartBDebug.qsf')){
   if($line -match '^-?set_global_assignment -name SYSTEMVERILOG_FILE (.+)$'){
     $sources+=Join-Path (Join-Path $root 'quartus') $Matches[1]
   }
 }
 $regression=@('tb_member_c','tb_motion_uart','tb_wheel_uart','tb_safety_arbiter','tb_uart_stop_priority')
 foreach($n in $regression){$sources+=Join-Path $PSScriptRoot ('member_c/'+$n+'.sv')}
 $sources+=Join-Path $PSScriptRoot 'member_c/hcsr04_model.sv'
 foreach($n in @('vga_sink_sim','tb_integrated_link','tb_integrated_pins','memberBDebug_tb','tb_jtag_ownership')){$sources+=Join-Path $PSScriptRoot ('integration/'+$n+'.sv')}
 & (Join-Path $ModelSimBin 'vlog.exe') -sv '+define+VERILATOR' ('+incdir+'+(Join-Path $root 'rtl/common')) ('+incdir+'+(Join-Path $PSScriptRoot 'integration')) -work work -l compile.log @sources
 if($LASTEXITCODE -ne 0){throw 'RTL/TB compilation failed'}
 $tests=$regression+@('memberBDebug_tb','tb_jtag_ownership','tb_integrated_link','tb_integrated_pins')
 if($PinsOnly){$tests=@('tb_integrated_pins')}
 if($SkipPins){$tests=$regression+@('tb_integrated_link')}
 if($Only){$tests=$Only.Split(',')}
 foreach($n in $tests){
  & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish exit -l ($n+'.log') ('work.'+$n) -do (Join-Path $PSScriptRoot 'run.do')
  $marker=if($n -eq 'memberBDebug_tb'){'PASS memberBDebug_tb:'}else{'PASS: '+$n}
  if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath ($n+'.log') -SimpleMatch $marker -Quiet)){throw ($n+' failed')}
 }
} finally {Pop-Location}
