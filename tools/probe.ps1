# Read DS memory from a running melonDS via its GDB stub.
#   powershell -File scripts/probe.ps1 -Addrs "0x021D112C:4w,0x021D1195:1b"
#
# Each spec is ADDR:COUNT+FORMAT where format is w (word) or b (byte).
# Attaching halts the CPU; the script always detaches so emulation resumes.
#
# -Gdb passes raw gdb commands through, separated by ';'. Needed whenever the
# address you want is only reachable by following a pointer - the hook's own
# variables sit at fixed ITCM addresses, but everything they point into is
# heap-allocated and moves between runs, so
#
#   -Gdb "set `$bs = *(unsigned long*)0x01FF8680; x/32xb `$bs + 0x19C"
#
# is the only way to read a live struct in a single session. The stub accepts
# exactly one connection per emulator launch, so batch everything into one call.
param(
  [string]$Addrs = "0x021D112C:4w",
  [string]$Gdb = "",
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
foreach ($c in ($Gdb -split ';')) {
  if ($c.Trim()) { $cmds += @("-ex", $c.Trim()) }
}
$cmds += @("-ex", "detach", "-ex", "quit")

& $gdb -batch @cmds 2>&1 | Where-Object {
  $_ -notmatch '^\s*$' -and $_ -notmatch 'warning: No executable' -and $_ -notmatch 'Remote debugging using'
}
