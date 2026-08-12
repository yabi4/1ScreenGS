# Read DS memory from a running melonDS via its GDB stub.
#   powershell -File scripts/probe.ps1 -Addrs "0x021D112C:4w,0x021D1195:1b"
#
# Each spec is ADDR:COUNT+FORMAT where format is w (word) or b (byte).
# Attaching halts the CPU; the script always detaches so emulation resumes.
param(
  [string]$Addrs = "0x021D112C:4w",
  [int]$Port = 3333
)

$gdb = "C:\devkitPro\devkitARM\bin\arm-none-eabi-gdb.exe"
if (-not (Test-Path $gdb)) { Write-Output "gdb not found at $gdb"; exit 1 }

$cmds = @("-ex", "set confirm off", "-ex", "set pagination off",
          "-ex", "target remote 127.0.0.1:$Port")
foreach ($spec in $Addrs.Split(",")) {
  if ($spec -match '^\s*(0x[0-9A-Fa-f]+):(\d+)([wb])\s*$') {
    $cmds += @("-ex", "x/$($Matches[2])x$($Matches[3]) $($Matches[1])")
  }
}
$cmds += @("-ex", "detach", "-ex", "quit")

& $gdb -batch @cmds 2>&1 | Where-Object {
  $_ -notmatch '^\s*$' -and $_ -notmatch 'warning: No executable' -and $_ -notmatch 'Remote debugging using'
}
