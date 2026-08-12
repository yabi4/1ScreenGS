# Launch a ROM in melonDS, let it boot, and screenshot the emulator window.
#   powershell -File scripts/shot.ps1 -Rom out\ipgf-vanilla.nds -Out shot.png -Wait 25
#
# Tries PrintWindow first (captures the window even when occluded, and does not
# steal focus). Falls back to forcing the window foreground and grabbing the
# screen region if PrintWindow returns a blank image (happens with some
# GPU-accelerated renderers).
param(
  [Parameter(Mandatory=$true)][string]$Rom,
  [Parameter(Mandatory=$true)][string]$Out,
  [int]$Wait = 25,
  [switch]$Reuse,
  [string]$Keys = ""
)

Add-Type -AssemblyName System.Drawing

# DS button -> the keyboard key melonDS is bound to -> Win32 virtual key code.
$VK = @{
  "a"     = 0x58   # DS A     <- keyboard X
  "b"     = 0x5A   # DS B     <- keyboard Z
  "x"     = 0x53   # DS X     <- keyboard S
  "y"     = 0x41   # DS Y     <- keyboard A
  "l"     = 0x51   # DS L     <- keyboard Q
  "r"     = 0x57   # DS R     <- keyboard W
  "start" = 0x0D   # Return
  "select"= 0x08   # Backspace
  "up"    = 0x26
  "down"  = 0x28
  "left"  = 0x25
  "right" = 0x27
  "swap"  = 0x54   # melonDS HK_SwapScreens <- keyboard T
}
$EXT = @("up", "down", "left", "right")
Add-Type @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool alt);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@ -ReferencedAssemblies System.Drawing

$exe = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\melonDS.melonDS_Microsoft.Winget.Source_8wekyb3d8bbwe\melonDS.exe"
if (-not (Test-Path $exe)) {
  $exe = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter melonDS.exe -ErrorAction SilentlyContinue |
          Select-Object -First 1 -ExpandProperty FullName)
}
if (-not $exe) { Write-Output "melonDS.exe not found"; exit 1 }

if (-not $Reuse) {
  Get-Process melonDS -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 800
  Start-Process -FilePath $exe -ArgumentList (Resolve-Path $Rom).Path | Out-Null
}

Start-Sleep -Seconds $Wait

$p = Get-Process melonDS -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output "melonDS window not found"; exit 1 }
$hwnd = $p.MainWindowHandle

# Bring to front so key input reaches the emulator (ALT tap unlocks SetForegroundWindow).
[Win]::ShowWindow($hwnd, 9) | Out-Null
[Win]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
[Win]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
[Win]::SwitchToThisWindow($hwnd, $true)
[Win]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 700

# The ALT tap above focuses the Qt menu bar; ESC releases it so keystrokes
# reach the emulated DS instead of triggering menu items.
$wsh = New-Object -ComObject WScript.Shell
$wsh.SendKeys("{ESC}")
Start-Sleep -Milliseconds 300

$r = New-Object Win+RECT
[Win]::GetWindowRect($hwnd, [ref]$r) | Out-Null
$w = $r.R - $r.L; $h = $r.B - $r.T
if ($w -le 0 -or $h -le 0) { Write-Output "bad window rect"; exit 1 }

if ($Keys) {
  # Click the TOP screen area (not touch-sensitive) purely to give the emulator
  # window real keyboard focus - SendKeys goes to the focused window, whereas
  # mouse_event is position-based and works regardless.
  [Win]::SetCursorPos($r.L + [int]($w / 2), $r.T + 150) | Out-Null
  Start-Sleep -Milliseconds 120
  [Win]::mouse_event(0x02, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 100
  [Win]::mouse_event(0x04, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 400

  # Safety: force-release every mapped key. If a key-up was ever lost the DS
  # sees it as held forever, which silently breaks all later movement.
  foreach ($name in $VK.Keys) {
    $e = if ($EXT -contains $name) { 3 } else { 2 }
    [Win]::keybd_event([byte]$VK[$name], 0, $e, [IntPtr]::Zero)
  }
  Start-Sleep -Milliseconds 200

  foreach ($k in $Keys.Split("|")) {
    if ($k -match '^wait(\d+)$') { Start-Sleep -Milliseconds ([int]$Matches[1]); continue }
    # tap:X,Y  -> touchscreen tap at window-relative pixel coordinates
    if ($k -match '^tap:(\d+),(\d+)$') {
      [Win]::SetCursorPos($r.L + [int]$Matches[1], $r.T + [int]$Matches[2]) | Out-Null
      Start-Sleep -Milliseconds 120
      [Win]::mouse_event(0x02, 0, 0, 0, [IntPtr]::Zero)   # left down
      Start-Sleep -Milliseconds 160
      [Win]::mouse_event(0x04, 0, 0, 0, [IntPtr]::Zero)   # left up
      Start-Sleep -Milliseconds 250
      continue
    }
    # c:A+B[:hold] -> press several keys simultaneously (button combos)
    if ($k -match '^c:([\w+]+)(?::(\d+))?$') {
      $names = $Matches[1].ToLower().Split("+")
      $hold = if ($Matches[2]) { [int]$Matches[2] } else { 220 }
      $bad = $names | Where-Object { -not $VK.ContainsKey($_) }
      if ($bad) { Write-Output "unknown key(s): $bad"; continue }
      foreach ($n in $names) {
        $e = if ($EXT -contains $n) { 1 } else { 0 }
        [Win]::keybd_event([byte]$VK[$n], 0, $e, [IntPtr]::Zero)
      }
      Start-Sleep -Milliseconds $hold
      foreach ($n in $names) {
        $e = if ($EXT -contains $n) { 3 } else { 2 }
        [Win]::keybd_event([byte]$VK[$n], 0, $e, [IntPtr]::Zero)
      }
      Start-Sleep -Milliseconds 200
      continue
    }

    # k:NAME -> inject a real key press held long enough for the emulator to
    # sample it. The DS polls input once per frame (16.7ms); SendKeys presses
    # and releases in well under a millisecond and gets missed entirely.
    if ($k -match '^k:(\w+)(?::(\d+))?$') {
      $name = $Matches[1].ToLower()
      $hold = if ($Matches[2]) { [int]$Matches[2] } else { 110 }
      if (-not $VK.ContainsKey($name)) { Write-Output "unknown key '$name'"; continue }
      $vkCode = $VK[$name]
      $ext = if ($EXT -contains $name) { 1 } else { 0 }
      [Win]::keybd_event([byte]$vkCode, 0, $ext, [IntPtr]::Zero)
      Start-Sleep -Milliseconds $hold
      [Win]::keybd_event([byte]$vkCode, 0, ($ext -bor 2), [IntPtr]::Zero)
      Start-Sleep -Milliseconds 140
      continue
    }
    $wsh.SendKeys($k)
    Start-Sleep -Milliseconds 250
  }
  Start-Sleep -Milliseconds 800
}

function Save-Bitmap($bmp, $path) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
}

$full = Join-Path (Get-Location) $Out

# --- attempt 1: PrintWindow (PW_RENDERFULLCONTENT) ---
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [Win]::PrintWindow($hwnd, $hdc, 2)
$g.ReleaseHdc($hdc); $g.Dispose()

$blank = $true
if ($ok) {
  for ($y = 0; $y -lt $h -and $blank; $y += 17) {
    for ($x = 0; $x -lt $w -and $blank; $x += 13) {
      $c = $bmp.GetPixel($x, $y)
      if ($c.R -gt 12 -or $c.G -gt 12 -or $c.B -gt 12) { $blank = $false }
    }
  }
}

if (-not $blank) {
  Save-Bitmap $bmp $full
  $bmp.Dispose()
  Write-Output "captured ${w}x${h} via PrintWindow -> $Out  (title: $($p.MainWindowTitle))"
  exit 0
}
$bmp.Dispose()

# --- attempt 2: screen grab of the (now foreground) window region ---
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
Save-Bitmap $bmp $full
$g.Dispose(); $bmp.Dispose()
Write-Output "captured ${w}x${h} via screen grab -> $Out  (title: $($p.MainWindowTitle))"
