# Crop and upscale a region of a melonDS capture for close inspection.
#   powershell -File scripts/zoom.ps1 -In build\p17.png -Out build\z.png -Screen top -Scale 3
param(
  [Parameter(Mandatory=$true)][string]$In,
  [Parameter(Mandatory=$true)][string]$Out,
  [ValidateSet("top","bottom","both")][string]$Screen = "top",
  [int]$Scale = 3
)

Add-Type -AssemblyName System.Drawing

# DS screen area inside the melonDS window capture (below the Qt menu bar)
$X = 8; $W = 256; $H = 192
$Y = switch ($Screen) { "top" { 57 } "bottom" { 249 } "both" { 57 } }
if ($Screen -eq "both") { $H = 384 }

$src = [System.Drawing.Image]::FromFile((Resolve-Path $In).Path)
$bmp = New-Object System.Drawing.Bitmap ($W * $Scale), ($H * $Scale)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g.DrawImage($src,
  (New-Object System.Drawing.Rectangle 0, 0, ($W * $Scale), ($H * $Scale)),
  (New-Object System.Drawing.Rectangle $X, $Y, $W, $H),
  [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose(); $src.Dispose()
$bmp.Save((Join-Path (Get-Location) $Out), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote $Out"
