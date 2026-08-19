# Compose labelled before/after screenshots into one image.
#   powershell -File scripts/compare.ps1 -Left a.png -Right b.png -LeftLabel "vanilla" -RightLabel "patched" -Out c.png
param(
  [Parameter(Mandatory=$true)][string]$Left,
  [Parameter(Mandatory=$true)][string]$Right,
  [string]$LeftLabel = "before",
  [string]$RightLabel = "after",
  [Parameter(Mandatory=$true)][string]$Out,
  # DS screen area inside the melonDS window capture (skips the Qt menu bar)
  [int]$CropX = 8, [int]$CropY = 57, [int]$CropW = 256, [int]$CropH = 384,
  [int]$Scale = 2
)

Add-Type -AssemblyName System.Drawing

function Get-Crop($path) {
  $src = [System.Drawing.Image]::FromFile((Resolve-Path $path).Path)
  $bmp = New-Object System.Drawing.Bitmap ($CropW * $Scale), ($CropH * $Scale)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $dst = New-Object System.Drawing.Rectangle 0, 0, ($CropW * $Scale), ($CropH * $Scale)
  $srcR = New-Object System.Drawing.Rectangle $CropX, $CropY, $CropW, $CropH
  $g.DrawImage($src, $dst, $srcR, [System.Drawing.GraphicsUnit]::Pixel)
  $g.Dispose(); $src.Dispose()
  return $bmp
}

$a = Get-Crop $Left
$b = Get-Crop $Right

$pad = 16; $header = 40
$W = $a.Width + $b.Width + $pad * 3
$H = $a.Height + $header + $pad * 2

$canvas = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($canvas)
$g.Clear([System.Drawing.Color]::FromArgb(24, 24, 28))
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$font = New-Object System.Drawing.Font "Segoe UI", 15, ([System.Drawing.FontStyle]::Bold)
$brush = [System.Drawing.Brushes]::White

$g.DrawString($LeftLabel,  $font, $brush, $pad, 12)
$g.DrawString($RightLabel, $font, $brush, ($pad * 2 + $a.Width), 12)
$g.DrawImage($a, $pad, $header + $pad)
$g.DrawImage($b, ($pad * 2 + $a.Width), $header + $pad)

$g.Dispose()
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$canvas.Save((Join-Path (Get-Location) $Out), [System.Drawing.Imaging.ImageFormat]::Png)
$canvas.Dispose(); $a.Dispose(); $b.Dispose()
Write-Output "wrote $Out (${W}x${H})"
