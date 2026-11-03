$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if((Resolve-Path $root).Path -ne 'C:\Quartus_Projects\ECHO7_Integrated_V2'){throw 'Wrong project root'}
& python (Join-Path $PSScriptRoot 'check_v2.py')
if($LASTEXITCODE -ne 0){throw 'Source audit failed'}
$expected=@{
 'tb_member_c'='PASS: tb_member_c';'tb_motion_uart'='PASS: tb_motion_uart';'tb_wheel_uart'='PASS: tb_wheel_uart';
 'tb_safety_arbiter'='PASS: tb_safety_arbiter';'tb_uart_stop_priority'='PASS: tb_uart_stop_priority';
 'tb_integrated_link'='PASS: tb_integrated_link';'tb_integrated_pins'='PASS: tb_integrated_pins';
 'memberBDebug_tb'='PASS memberBDebug_tb:';'tb_jtag_ownership'='PASS: tb_jtag_ownership';
 'tb_v2_collision'='PASS perceptionCoreCollision_tb';'tb_v2_pixel_latency'='PASS: tb_v2_pixel_latency'
}
foreach($entry in $expected.GetEnumerator()){
 $p=Join-Path $root ('sim/'+$entry.Key+'.log')
 if(!(Test-Path $p) -or !(Select-String -LiteralPath $p -SimpleMatch $entry.Value -Quiet)){throw ('Simulation gate failed: '+$entry.Key)}
}
$lock=Join-Path $root 'full_compile_once.started'
$stream=[System.IO.File]::Open($lock,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write)
$writer=New-Object System.IO.StreamWriter($stream)
$writer.WriteLine((Get-Date).ToString('o'));$writer.Close()
Push-Location -LiteralPath (Join-Path $root 'quartus')
try {
 & 'C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sh.exe' --flow compile PartBDebug -c PartBDebug 2>&1 | Tee-Object -FilePath (Join-Path $root 'full_compile_once.log')
 $code=$LASTEXITCODE
 ('ExitCode='+$code) | Set-Content -LiteralPath (Join-Path $root 'full_compile_once.result')
 if($code -ne 0){throw 'Full compile failed. No RTL changes or automatic recompile permitted.'}
}finally{Pop-Location}
