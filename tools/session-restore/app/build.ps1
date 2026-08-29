#requires -Version 5.1
<#
.SYNOPSIS
    Builds Sessions.exe -- the session console as an application.

.DESCRIPTION
    Two steps, no dependencies to install: draw the icon, then compile the host.

    THE COMPILER IS ALREADY ON THE MACHINE. csc.exe ships with the .NET
    Framework, which every supported Windows has, so this repo stays what it has
    always been: PowerShell and nothing else you have to fetch. There is no SDK,
    no NuGet, no MSBuild and no project file.

    WHAT IS BUILT is a ~15 KB launcher that hosts a PowerShell runspace and runs
    libsessions-gui2.ps1 inside it. The scripts are NOT compiled in and NOT hidden --
    they stay on disk next to the exe, readable and editable, and every test
    driver keeps running them directly. Editing a .ps1 does not need a rebuild;
    only editing SessionsHost.cs does.

    THE ICON IS DRAWN, not shipped as a binary blob: a spark in Claude's clay
    with a tick over it -- what the app is for, which conversations come back.
    Drawing it means the repo carries no checked-in binary and the icon changes
    by editing arithmetic rather than by opening an image editor.

    It replaced a dark rounded square containing ">_", which was the Windows
    Terminal icon in all but name and distinguished itself from none of the eight
    terminals already on the taskbar.

.PARAMETER Force
    Rebuild even when Sessions.exe is already newer than its sources.

.PARAMETER Quiet
    Print nothing on success. For the installer, which has its own reporting.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }

$root   = Split-Path -Parent $here
$source = Join-Path $here 'SessionsHost.cs'
$icoOut = Join-Path $here 'sessions.ico'
$exeOut = Join-Path $root 'Sessions.exe'

function Write-Step($msg) { if (-not $Quiet) { Write-Host "  $msg" } }

# ---------------------------------------------------------------------------
# The icon.
#
# PNG payloads inside the .ico container for every size. The alternative is a
# 32bpp BMP with a separate AND mask per entry, which is three times the code and
# buys nothing here: PNG-in-ICO has been read by the Windows shell since Vista
# and this app targets Windows 10 and 11.
# ---------------------------------------------------------------------------
function New-AppIcon {
    param([string]$Path, [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256))

    Add-Type -AssemblyName System.Drawing

    $ink   = [System.Drawing.Color]::FromArgb(255, 240, 241, 243)  # the tick
    $panel = [System.Drawing.Color]::FromArgb(255,  21,  22,  26)  # the plate
    $edge  = [System.Drawing.Color]::FromArgb(255,  60,  64,  70)  # its rim
    $clay  = [System.Drawing.Color]::FromArgb(255, 217, 119,  87)  # the spark

    $pngs = New-Object 'System.Collections.Generic.List[byte[]]'

    foreach ($size in $Sizes) {
        # Every size is DRAWN AT ITS OWN SIZE rather than downscaled from 256.
        # A 16 px icon resampled from 256 goes to mush; drawn directly, the
        # antialiaser gets to place the strokes itself and the chevron survives.
        $s = $size / 256.0
        $bmp = New-Object System.Drawing.Bitmap($size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb))
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.Clear([System.Drawing.Color]::Transparent)

            # The plate: a rounded square, inset so the rim is not clipped.
            $inset = 6 * $s
            $r     = 52 * $s
            $w     = $size - (2 * $inset)
            $plate = New-Object System.Drawing.Drawing2D.GraphicsPath
            $plate.AddArc($inset, $inset, $r, $r, 180, 90)
            $plate.AddArc($inset + $w - $r, $inset, $r, $r, 270, 90)
            $plate.AddArc($inset + $w - $r, $inset + $w - $r, $r, $r, 0, 90)
            $plate.AddArc($inset, $inset + $w - $r, $r, $r, 90, 90)
            $plate.CloseFigure()

            $fill = New-Object System.Drawing.SolidBrush($panel)
            $g.FillPath($fill, $plate)
            $fill.Dispose()

            $rim = New-Object System.Drawing.Pen($edge, [float](7 * $s))
            $g.DrawPath($rim, $plate)
            $rim.Dispose()
            $plate.Dispose()

            # THE SPARK. Radiating tapered rays, in Claude's clay, because the
            # previous icon was a dark rounded square containing ">_" -- which is
            # the Windows Terminal icon. On a taskbar holding eight terminals it
            # distinguished itself from none of them, which was the one job it
            # had.
            #
            # It is a spark in the STYLE of Claude's mark, drawn from arithmetic
            # here; it is not a copy of Anthropic's trademark and this is a local
            # tool, not a product pretending to be one.
            #
            # 🪤 RAY COUNT DROPS WITH SIZE. Twelve rays at 256 px is the shape;
            # twelve rays at 16 px is a smudge, because the gaps between them
            # land inside one pixel. Each size is already drawn at its own size
            # rather than downscaled, so it can simply use fewer.
            # 🪤 THREE ATTEMPTS, AND THE WIDTH IS NEVER WHERE YOU THINK. A blade
            # based at an inner radius measures 2*r*sin(half) across, so a small
            # inner radius stays a hairline however wide the ANGLE -- attempt one
            # (r=15) came out as sunburst clip-art. Widening the base instead
            # (r=36, tip at 84, hub at 0.82r) made the blades shorter than the
            # disc they stood on: a child's drawing of the sun. What works is a
            # petal with no hub at all, widest partway out.
            # 🪤 SMALL SIZES GET THEIR OWN GEOMETRY, NOT THE SAME SHAPE SCALED.
            # At 16 px the tick drawn to the large proportions came out about two
            # pixels of white and simply disappeared, leaving an orange smudge
            # that says nothing about what the app decides. Below 48 px the spark
            # gives up room, the blade count halves and the tick is drawn much
            # heavier -- so the two marks stay legible as marks rather than
            # becoming texture.
            $small = ($size -lt 48)

            $cx = $(if ($small) { 96 } else { 110 }) * $s
            $cy = $(if ($small) { 92 }  else { 104 }) * $s
            $rMid = $(if ($small) { 30 } else { 36 }) * $s   # where each blade is widest
            $rOut = $(if ($small) { 78 } else { 96 }) * $s   # where it comes to a point
            $rays = $(if ($small) { 8 } else { 12 })
            $half = ([Math]::PI / $rays) * 0.85             # angular half-width at $rMid

            # 🪤 EACH BLADE IS A PETAL, NOT A TRIANGLE ON A DISC. A triangle
            # based at an inner radius needs a hub to hide the hole at the
            # middle, and that hub is what made attempt two look like the sun and
            # attempt three look like a starburst with a bead in it. A four-point
            # petal -- centre, widest at $rMid, tip at $rOut, back to centre --
            # converges on its own, so there is no hub and nothing to balance.
            $sparkBrush = New-Object System.Drawing.SolidBrush($clay)
            for ($k = 0; $k -lt $rays; $k++) {
                $a = (($k / [double]$rays) * 2 * [Math]::PI) - ([Math]::PI / 2)
                $pts = [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF([float]$cx, [float]$cy)),
                    (New-Object System.Drawing.PointF(
                        [float]($cx + $rMid * [Math]::Cos($a - $half)),
                        [float]($cy + $rMid * [Math]::Sin($a - $half)))),
                    (New-Object System.Drawing.PointF(
                        [float]($cx + $rOut * [Math]::Cos($a)),
                        [float]($cy + $rOut * [Math]::Sin($a)))),
                    (New-Object System.Drawing.PointF(
                        [float]($cx + $rMid * [Math]::Cos($a + $half)),
                        [float]($cy + $rMid * [Math]::Sin($a + $half))))
                )
                $g.FillPolygon($sparkBrush, $pts)
            }
            $sparkBrush.Dispose()

            # THE TICK, bottom right: what this app is actually for -- which of
            # these comes back at logon. Drawn TWICE: a fat stroke in the plate
            # colour first, so the tick punches a hole through whatever rays sit
            # behind it, then the light stroke inside that. Without the knockout
            # it reads as another ray at small sizes.
            $tick = $(if ($small) {
                [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF([float](132 * $s), [float](170 * $s))),
                    (New-Object System.Drawing.PointF([float](166 * $s), [float](206 * $s))),
                    (New-Object System.Drawing.PointF([float](232 * $s), [float](128 * $s)))
                )
            } else {
                [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF([float](158 * $s), [float](180 * $s))),
                    (New-Object System.Drawing.PointF([float](182 * $s), [float](204 * $s))),
                    (New-Object System.Drawing.PointF([float](226 * $s), [float](150 * $s)))
                )
            })
            foreach ($layer in @(
                @{ Colour = $panel; Width = $(if ($small) { 64 } else { 38 }) },
                @{ Colour = $ink;   Width = $(if ($small) { 38 } else { 21 }) }
            )) {
                $pen = New-Object System.Drawing.Pen($layer.Colour, [float]($layer.Width * $s))
                $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
                $g.DrawLines($pen, $tick)
                $pen.Dispose()
            }
        } finally { $g.Dispose() }

        $ms = New-Object System.IO.MemoryStream
        try {
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $pngs.Add($ms.ToArray())
        } finally { $ms.Dispose(); $bmp.Dispose() }
    }

    # ICONDIR, then one ICONDIRENTRY per size, then the payloads.
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0)               # reserved
        $bw.Write([uint16]1)               # 1 = icon
        $bw.Write([uint16]$Sizes.Count)

        # 6 bytes of header plus 16 per entry: where the first payload starts.
        $offset = 6 + (16 * $Sizes.Count)
        for ($i = 0; $i -lt $Sizes.Count; $i++) {
            # 256 is written as 0. The field is one byte, so 256 does not fit,
            # and 0 is the agreed spelling of it.
            $dim = $(if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] })
            $bw.Write([byte]$dim)          # width
            $bw.Write([byte]$dim)          # height
            $bw.Write([byte]0)             # palette entries: none, it is truecolour
            $bw.Write([byte]0)             # reserved
            $bw.Write([uint16]1)           # colour planes
            $bw.Write([uint16]32)          # bits per pixel
            $bw.Write([uint32]$pngs[$i].Length)
            $bw.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($p in $pngs) { $bw.Write($p) }
    } finally { $bw.Dispose(); $fs.Dispose() }
}

# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $source)) {
    throw "SessionsHost.cs is missing from $here"
}

# Skip a rebuild nobody asked for. The installer calls this every time.
if (-not $Force -and (Test-Path -LiteralPath $exeOut)) {
    $exeAge = (Get-Item -LiteralPath $exeOut).LastWriteTimeUtc
    $srcAge = (Get-Item -LiteralPath $source).LastWriteTimeUtc
    if ($exeAge -gt $srcAge) {
        Write-Step "Sessions.exe is already current ($([int]((Get-Item -LiteralPath $exeOut).Length / 1KB)) KB)"
        return 0
    }
}

# A running instance holds its own image open, and csc's error for that is
# unhelpful. Say the actual thing.
if (Test-Path -LiteralPath $exeOut) {
    try {
        $fs = [System.IO.File]::Open($exeOut, 'Open', 'ReadWrite', 'None')
        $fs.Dispose()
    } catch {
        throw "Sessions.exe is running -- close the session window, then build again."
    }
}

Write-Step 'drawing the icon...'
New-AppIcon -Path $icoOut

# Assembly paths are taken from assemblies THIS PowerShell has already loaded,
# rather than guessed at in the GAC. That way the compiler references exactly
# the System.Management.Automation the window will actually run on.
# Only System.Management.Automation is named. csc.exe reads csc.rsp from its own
# directory, and that already references System.dll and System.Windows.Forms.dll
# -- naming them again is not additive, it is error CS1703 "already imported",
# because the GAC copy and the framework-directory copy are one assembly under
# two paths.
$refSma = [System.Management.Automation.PowerShell].Assembly.Location

$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw "The .NET Framework C# compiler was not found. Looked for csc.exe under $env:SystemRoot\Microsoft.NET."
}

Write-Step 'compiling...'
$cscArgs = @(
    '/nologo'
    '/target:winexe'          # winexe, not exe: no console is ever allocated
    '/platform:anycpu'
    '/optimize+'
    "/out:$exeOut"
    "/win32icon:$icoOut"
    "/reference:$refSma"
    $source
)
$out = & $csc @cscArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    $out | ForEach-Object { Write-Host $_ }
    throw "csc.exe failed with exit code $LASTEXITCODE"
}

if (-not $Quiet) {
    $kb = [Math]::Round((Get-Item -LiteralPath $exeOut).Length / 1KB, 1)
    Write-Host ""
    Write-Host "  Sessions.exe  $kb KB  ->  $exeOut" -ForegroundColor Green
    Write-Host ""
}
return 0
