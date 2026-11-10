#Requires -Version 5.1
<#
.SYNOPSIS
    For each camera clip, find the first frame whose burned-in timestamp reads the target time
    (default 12:00:00) and save that frame as a full-resolution JPEG.

.DESCRIPTION
    These exports carry no capture time in their metadata (creation_time = export time, no
    timecode track), so the camera's on-screen timestamp is the only source of truth. This
    script reads it with Tesseract OCR (local CLI, no network). Windows' built-in OCR was
    tried first and consistently drops the HH:MM:SS group, so it is not used.

    Per clip:
      1. Lists every video frame timestamp with ffprobe (packet scan, no decoding).
      2. Finds which corner holds the overlay (remembered per camera, e.g. "cam-01-elevator-1",
         for the rest of the run; nothing is saved between runs).
      3. Binary-searches the frames, OCR-ing the overlay (~12 reads), for the first frame
         whose overlay reads >= the target time.
      4. Verifies: that frame must read exactly the target AND the frame before it must read
         target - 1 s. If not, it rescans +/-1.5 s frame by frame.
      5. Saves the frame as a JPEG next to the clip and writes a CSV log of every clip
         (frame number, overlay readings, status) for audit.

    Status values in the log:
      OK             Exact transition frame found and verified.
      StartsAtTarget Clip's first frame already reads the target; the true transition may be
                     before the clip. Frame 0 is saved.
      CheckManually  Best guess saved, but the verification failed (OCR misreads or the
                     camera skipped that second). Look at the JPEG.
      NotInClip      The target time isn't inside this clip.
      Error          See the Error column.

.PARAMETER Calibrate
    Don't search. For each clip, save the corner crops of frame 0 exactly as OCR sees them
    (as _calib-*.png, only where OCR found text) and print what OCR read. Use it to check that
    the timestamp is fully inside a crop; adjust -CornerWidth / -CornerHeight if it isn't.

.EXAMPLE
    .\Export-CameraFrameAtTime.ps1 -Folder 'C:\Users\username\Downloads\cam' -Calibrate
.EXAMPLE
    .\Export-CameraFrameAtTime.ps1 -Folder 'C:\Users\username\Downloads\cam' -Target '12:00:00'

.NOTES
    Requires Tesseract OCR 5.x (tested with 5.5.3). Runs in Windows PowerShell 5.1 or PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$Folder       = 'C:\Users\username\Downloads\cam',
    [string]$Filter       = '*.mp4',
    [string]$Target       = '12:00:00',
    [string]$FFmpeg       = 'C:\tools\bin\ffmpeg\bin\ffmpeg.exe',
    [string]$FFprobe      = 'C:\tools\bin\ffmpeg\bin\ffprobe.exe',
    [string]$Tesseract    = 'C:\tools\bin\tesseract\tesseract.exe',
    [string]$TessdataDir  = '',    # folder holding eng.traineddata; empty = Tesseract's own tessdata
    [double]$CornerWidth  = 0.45,  # fraction of frame width each corner crop covers
    [double]$CornerHeight = 0.08,  # fraction of frame height each corner crop covers
    [int[]]$Threshold     = @(190, 220, 240), # brightness cutoffs tried in order (higher = for bright scenes)
    [ValidateRange(1, 31)]
    [int]$JpegQuality     = 2,     # ffmpeg -q:v (1 = best, 31 = worst)
    [string]$UtcOffset    = '',    # e.g. '-07:00'; empty = from the time-zone abbreviation in the file name
    [switch]$Calibrate
)

$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture

foreach ($exe in $FFmpeg, $FFprobe, $Tesseract) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "Not found: $exe" }
}
if (-not (Test-Path -LiteralPath $Folder)) { throw "Folder not found: $Folder" }
$TessArgs = @('-l', 'eng')
if ($TessdataDir) {
    if (-not (Test-Path -LiteralPath (Join-Path $TessdataDir 'eng.traineddata'))) { throw "eng.traineddata not found in $TessdataDir" }
    $TessArgs += @('--tessdata-dir', $TessdataDir)
}
$targetTs = [TimeSpan]::Parse($Target)
$oneSec   = [TimeSpan]::FromSeconds(1)

# ---------------------------------------------------------------------------------------------
# OCR: Tesseract CLI, English model, result on stdout. Page-segmentation mode (--psm):
#   7 = single text line (best on clean crops), 6 = text block, 11 = sparse text
#   (6/11 cope with bright scenery speckles left around the overlay)
# ---------------------------------------------------------------------------------------------
function Get-OcrText([string]$PngPath, [int]$Psm = 7) {
    $out = & $Tesseract $PngPath stdout --psm $Psm @TessArgs 2>$null
    if ($LASTEXITCODE -ne 0) { throw "tesseract failed on $PngPath (exit $LASTEXITCODE)" }
    (@($out) -join ' ').Trim()
}

# ---------------------------------------------------------------------------------------------
# Overlay parsing
# ---------------------------------------------------------------------------------------------
function ConvertFrom-OverlayText([string]$Text) {
    if (-not $Text) { return $null }
    # Common OCR letter/digit confusions
    $t = $Text -replace '[Oo]', '0' -replace '[Il|]', '1'
    # Prefer a proper HH:MM:SS; fall back to looser separators OCR sometimes produces
    foreach ($pattern in '(\d{1,2})\s*:\s*(\d{2})\s*:\s*(\d{2})', '(\d{1,2})\s*[:.;]\s*(\d{2})\s*[:.;]\s*(\d{2})') {
        foreach ($m in [regex]::Matches($t, $pattern)) {
            $h = [int]$m.Groups[1].Value; $mi = [int]$m.Groups[2].Value; $s = [int]$m.Groups[3].Value
            if ($h -lt 24 -and $mi -lt 60 -and $s -lt 60) { return New-Object TimeSpan $h, $mi, $s }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------------------------
# Corner crops and OCR pre-processing (ffmpeg filter strings, culture-invariant numbers)
# ---------------------------------------------------------------------------------------------
$w = $CornerWidth.ToString($inv)
$h = $CornerHeight.ToString($inv)
$Corners = [ordered]@{
    TL = "crop=iw*${w}:ih*${h}:0:0"
    TR = "crop=iw*${w}:ih*${h}:iw*(1-${w}):0"
    BL = "crop=iw*${w}:ih*${h}:0:ih*(1-${h})"
    BR = "crop=iw*${w}:ih*${h}:iw*(1-${w}):ih*(1-${h})"
}
# Tried in order until OCR yields a valid time. Each variant turns the white overlay text black
# on a clean white page (pixels brighter than the cutoff = text) and pads it so OCR has a margin.
# Higher cutoffs handle bright scenes where the background behind the text is also light.
function New-Prep([int]$Height, [int]$Cutoff) {
    $pad = [int]($Height / 4)
    "scale=-2:${Height}:flags=lanczos,format=gray,lut=c0='if(gt(val\,$Cutoff)\,0\,255)',pad=iw+$(2*$pad):ih+$(2*$pad):${pad}:${pad}:white"
}
# OCR attempts in order (cutoff x layout mode x size). The first attempt that works on a clip is
# tried first for the rest of that clip, so the long list only costs time when a frame is hard.
$Attempts = New-Object System.Collections.Generic.List[object]
function Add-Attempt([int]$Cutoff, [int]$Psm, [int]$Height) {
    $Attempts.Add([pscustomobject]@{ Prep = (New-Prep $Height $Cutoff); Psm = $Psm; Label = "cut$Cutoff/psm$Psm/h$Height" })
}
foreach ($psm in 7, 6, 11) { foreach ($t in $Threshold) { Add-Attempt $t $psm 160 } }
foreach ($t in $Threshold) { Add-Attempt $t 7 240 }
$script:OcrN = 0

# ---------------------------------------------------------------------------------------------
# Per-clip helpers (operate on $Clip, set in the main loop)
# ---------------------------------------------------------------------------------------------
function Get-SeekArg([int]$Index) {
    # A hair before the frame's own timestamp so accurate seek lands exactly on it
    ([Math]::Max(0.0, $Clip.Pts[$Index] - $Clip.Start - 0.0005)).ToString('F6', $inv)
}

function Save-OverlayCrop([int]$Index, [string]$Corner, [string]$PrepFilter, [string]$OutPng) {
    & $FFmpeg -v error -y -ss (Get-SeekArg $Index) -i $Clip.In -frames:v 1 `
        -vf "$($Corners[$Corner]),$PrepFilter" -update 1 $OutPng
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed extracting frame $Index" }
}

function Read-OverlayTime([int]$Index, [string]$Corner = $Clip.Corner) {
    $key = "$Corner/$Index"
    if ($Clip.Cache.ContainsKey($key)) { return $Clip.Cache[$key] }
    $result = $null
    $order = @(0..($Attempts.Count - 1))
    if ($null -ne $Clip.Best) { $order = @($Clip.Best) + @($order | Where-Object { $_ -ne $Clip.Best }) }
    foreach ($a in $order) {
        # Unique file per read (avoids any lingering handle on the previous image)
        $script:OcrN++
        $png = Join-Path $TmpDir "ocr-$($script:OcrN).png"
        Save-OverlayCrop $Index $Corner $Attempts[$a].Prep $png
        $ts = ConvertFrom-OverlayText (Get-OcrText $png $Attempts[$a].Psm)
        Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue
        if ($null -ne $ts -and ($null -eq $Clip.MinOk -or ($ts -ge $Clip.MinOk -and $ts -le $Clip.MaxOk))) {
            $result = $ts
            $Clip.Best = $a
            break
        }
    }
    $Clip.Cache[$key] = $result
    return $result
}

# First readable frame walking from $From in direction $Dir (+1/-1): the first 10 frames one by
# one, then every half second for up to MaxSeconds (bright or busy stretches can defeat OCR)
function Find-ReadableFrame([int]$From, [int]$Dir, [double]$MaxSeconds = 15) {
    $half = [Math]::Max(1, [int][Math]::Round($Clip.Fps / 2))
    $offsets = @(0..9)
    $n = [int][Math]::Floor($MaxSeconds * 2)
    if ($n -ge 1) { $offsets += @(1..$n | ForEach-Object { 9 + $_ * $half }) }
    foreach ($o in $offsets) {
        $i = $From + $o * $Dir
        if ($i -lt 0 -or $i -gt $Clip.Last) { break }
        if ($null -ne (Read-OverlayTime $i)) { return $i }
    }
    return -1
}

function Find-OverlayCorner([string]$Preferred) {
    $order = @()
    if ($Preferred -and $Corners.Contains($Preferred)) { $order += $Preferred }
    $order += @($Corners.Keys | Where-Object { $_ -ne $Preferred })
    $probeFrames = @(0, [Math]::Min($Clip.Last, [int][Math]::Ceiling($Clip.Fps)))
    foreach ($c in $order) {
        foreach ($i in $probeFrames) {
            if ($null -ne (Read-OverlayTime $i $c)) { return @{ Corner = $c; Frame = $i } }
        }
    }
    return $null
}

function Test-Transition([int]$Index) {
    if ($Index -lt 1) { return $false }
    ((Read-OverlayTime $Index) -eq $targetTs) -and ((Read-OverlayTime ($Index - 1)) -eq ($targetTs - $oneSec))
}

function Format-Ts($Ts) { if ($null -eq $Ts) { '' } else { $Ts.ToString() } }

# ---------------------------------------------------------------------------------------------
# EXIF capture time: build a minimal EXIF (APP1) segment and insert it into the JPEG without
# re-encoding. Tags: DateTime (IFD0), ExifVersion, DateTimeOriginal, DateTimeDigitized,
# OffsetTime/Original/Digitized (when the UTC offset is known) and SubSecTimeOriginal.
# ---------------------------------------------------------------------------------------------
$TzOffsets = @{
    UTC = '+00:00'; GMT = '+00:00'
    PST = '-08:00'; PDT = '-07:00'; MST = '-07:00'; MDT = '-06:00'
    CST = '-06:00'; CDT = '-05:00'; EST = '-05:00'; EDT = '-04:00'
    AST = '-04:00'; ADT = '-03:00'; NST = '-03:30'; NDT = '-02:30'
}

function ConvertTo-LeBytes([uint32]$Value, [int]$Size) {
    $b = [BitConverter]::GetBytes($Value)
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($b) }
    $b[0..($Size - 1)]
}

# One IFD (entries sorted by tag) followed by its out-of-line data; offsets are relative to the
# start of the TIFF header, $Start is where this IFD will sit.
function Get-IfdBytes($Entries, [int]$Start) {
    $n = @($Entries).Count
    $dataStart = $Start + 2 + 12 * $n + 4
    $ifd  = New-Object System.Collections.Generic.List[byte]
    $data = New-Object System.Collections.Generic.List[byte]
    $ifd.AddRange([byte[]](ConvertTo-LeBytes $n 2))
    foreach ($e in $Entries) {
        $bytes = [byte[]]$e.Data
        $count = if ($e.Type -eq 4) { 1 } else { $bytes.Length }
        $ifd.AddRange([byte[]](ConvertTo-LeBytes $e.Tag 2))
        $ifd.AddRange([byte[]](ConvertTo-LeBytes $e.Type 2))
        $ifd.AddRange([byte[]](ConvertTo-LeBytes $count 4))
        if ($bytes.Length -le 4) {
            $v = New-Object byte[] 4
            [Array]::Copy($bytes, $v, $bytes.Length)
            $ifd.AddRange($v)
        } else {
            $ifd.AddRange([byte[]](ConvertTo-LeBytes ($dataStart + $data.Count) 4))
            $data.AddRange($bytes)
            if ($data.Count % 2) { $data.Add(0) }   # keep word alignment
        }
    }
    $ifd.AddRange([byte[]](ConvertTo-LeBytes 0 4))  # no next IFD
    $ifd.AddRange($data)
    , $ifd.ToArray()
}

function Set-JpegCaptureTime([string]$Path, [datetime]$Taken, [string]$Offset) {
    $ascii = [Text.Encoding]::ASCII
    $dt = $ascii.GetBytes($Taken.ToString('yyyy:MM:dd HH:mm:ss', $inv) + [char]0)

    $exifEntries = @(
        @{ Tag = 0x9000; Type = 7; Data = $ascii.GetBytes('0232') }   # ExifVersion
        @{ Tag = 0x9003; Type = 2; Data = $dt }                       # DateTimeOriginal
        @{ Tag = 0x9004; Type = 2; Data = $dt }                       # DateTimeDigitized
    )
    if ($Offset) {
        $o = $ascii.GetBytes($Offset + [char]0)
        $exifEntries += @{ Tag = 0x9010; Type = 2; Data = $o }       # OffsetTime
        $exifEntries += @{ Tag = 0x9011; Type = 2; Data = $o }       # OffsetTimeOriginal
        $exifEntries += @{ Tag = 0x9012; Type = 2; Data = $o }       # OffsetTimeDigitized
    }
    $exifEntries += @{ Tag = 0x9291; Type = 2; Data = $ascii.GetBytes('000' + [char]0) }  # SubSecTimeOriginal

    # IFD0 = DateTime + pointer to the Exif IFD (pointer value known once IFD0's size is known)
    $ifd0Entries = @(
        @{ Tag = 0x0132; Type = 2; Data = $dt }
        @{ Tag = 0x8769; Type = 4; Data = [byte[]](ConvertTo-LeBytes 0 4) }
    )
    $ifd0 = Get-IfdBytes $ifd0Entries 8
    $exifStart = 8 + $ifd0.Length
    $ifd0Entries[1].Data = [byte[]](ConvertTo-LeBytes $exifStart 4)
    $ifd0 = Get-IfdBytes $ifd0Entries 8
    $exifIfd = Get-IfdBytes $exifEntries $exifStart

    $tiff = New-Object System.Collections.Generic.List[byte]
    $tiff.AddRange([byte[]](0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00))   # "II", 42, IFD0 at 8
    $tiff.AddRange($ifd0)
    $tiff.AddRange($exifIfd)

    $payload = [byte[]](@(0x45, 0x78, 0x69, 0x66, 0x00, 0x00) + $tiff.ToArray())   # "Exif\0\0"
    $segLen = $payload.Length + 2
    if ($segLen -gt 65535) { throw 'EXIF segment too large' }
    $app1 = [byte[]](@(0xFF, 0xE1, ($segLen -shr 8), ($segLen -band 0xFF)) + $payload)

    # Insert after SOI and, if present, the JFIF APP0 segment that ffmpeg writes
    $jpg = [IO.File]::ReadAllBytes($Path)
    if ($jpg.Length -lt 4 -or $jpg[0] -ne 0xFF -or $jpg[1] -ne 0xD8) { throw "Not a JPEG: $Path" }
    $pos = 2
    if ($jpg[2] -eq 0xFF -and $jpg[3] -eq 0xE0) { $pos = 4 + (([int]$jpg[4] -shl 8) -bor $jpg[5]) }
    $ms = New-Object IO.MemoryStream
    $ms.Write($jpg, 0, $pos)
    $ms.Write($app1, 0, $app1.Length)
    $ms.Write($jpg, $pos, $jpg.Length - $pos)
    [IO.File]::WriteAllBytes($Path, $ms.ToArray())

    # File times too (some catalogs fall back on them)
    $local = if ($Offset) {
        ([DateTimeOffset]::new($Taken, [TimeSpan]::Parse($Offset.TrimStart('+')))).LocalDateTime
    } else { $Taken }
    $item = Get-Item -LiteralPath $Path
    $item.CreationTime  = $local
    $item.LastWriteTime = $local
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
# Overlay corner per camera, remembered for this run only (nothing written to disk)
$CornerMap = @{}

$TmpDir = Join-Path $env:TEMP ('overlay-ocr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpDir | Out-Null
$LogPath = Join-Path $Folder ('overlay-frames-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
$Results = New-Object System.Collections.Generic.List[object]

$files = @(Get-ChildItem -LiteralPath $Folder -Filter $Filter -File | Sort-Object Name)
if ($files.Count -eq 0) { throw "No files matching $Filter in $Folder" }

try {
    foreach ($f in $files) {
        Write-Host "`n== $($f.Name)" -ForegroundColor Cyan
        $camera = if ($f.BaseName -match '^(.+?)\s+\d{1,2}-\d{1,2}-\d{4},') { $Matches[1] } else { $f.BaseName }
        $row = [ordered]@{
            File = $f.Name; Camera = $camera; Corner = ''; Status = ''; Frame = ''; SecondsIntoClip = ''
            ClipFirstOverlay = ''; BeforeOverlay = ''; FrameOverlay = ''; CaptureTime = ''; OcrReads = 0; Output = ''; Error = ''
        }
        try {
            # --- frame timestamps (display order) ---
            $s = & $FFprobe -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 $f.FullName
            $start = if ($s -match '^-?[\d.]+$') { [double]$s } else { 0.0 }
            $list = New-Object System.Collections.Generic.List[double]
            & $FFprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $f.FullName |
                ForEach-Object { if ($_ -match '^-?[\d.]+$') { $list.Add([double]$_) } }
            if ($LASTEXITCODE -ne 0 -or $list.Count -eq 0) { throw 'ffprobe returned no video timestamps' }
            $pts = $list.ToArray(); [Array]::Sort($pts)
            $clipLen = $pts[-1] - $start

            $Clip = @{
                In = $f.FullName; Pts = $pts; Start = $start; Last = $pts.Length - 1
                Fps = if ($clipLen -gt 0) { ($pts.Length - 1) / $clipLen } else { 30.0 }
                Corner = $null; Cache = @{}; MinOk = $null; MaxOk = $null; Best = $null
            }

            # --- calibration mode ---
            if ($Calibrate) {
                # Every corner x every pre-processing variant; keep only crops where OCR saw text
                $anyTime = $false
                foreach ($c in $Corners.Keys) {
                    for ($v = 0; $v -lt $Attempts.Count; $v++) {
                        $png = Join-Path $Folder ("_calib-{0}-{1}-v{2}.png" -f $camera, $c, $v)
                        Save-OverlayCrop 0 $c $Attempts[$v].Prep $png
                        $text = Get-OcrText $png $Attempts[$v].Psm
                        if (-not $text) { Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue; continue }
                        $ts = ConvertFrom-OverlayText $text
                        $mark = if ($null -ne $ts) { $anyTime = $true; 'TIME OK' } else { 'no time' }
                        "{0} v{1} ({2}): [{3}] '{4}'  ->  {5}" -f $c, $v, $Attempts[$v].Label, $mark, $text, (Format-Ts $ts)
                    }
                }
                if (-not $anyTime) {
                    # Nothing worked: save the unprocessed colour crops so the overlay can be inspected
                    foreach ($c in $Corners.Keys) {
                        Save-OverlayCrop 0 $c 'scale=-2:160:flags=lanczos' (Join-Path $Folder ("_calib-{0}-{1}-raw.png" -f $camera, $c))
                    }
                    "No time read in any corner; saved _calib-$camera-<corner>-raw.png colour crops"
                }
                $row.Status = 'Calibrate'
                continue
            }

            # --- locate the overlay corner ---
            $found = Find-OverlayCorner $CornerMap[$camera]
            if (-not $found) { throw 'No readable HH:MM:SS overlay in any corner (run with -Calibrate)' }
            $Clip.Corner = $found.Corner
            $row.Corner = $found.Corner
            $CornerMap[$camera] = $found.Corner

            # Establish the clip's clock from several readings so one misread (e.g. 11 read as 14)
            # can't skew the search: each reading implies a clip start time (overlay - seconds into
            # clip); take the value most readings agree on (within 1.5 s), need at least two.
            $samples = @()
            $seen = @{}
            foreach ($k in 0..6) {
                $i = [Math]::Min($Clip.Last, [int][Math]::Round($k * 0.75 * $Clip.Fps))
                if ($seen.ContainsKey($i)) { continue }
                $seen[$i] = $true
                $t = Read-OverlayTime $i
                if ($null -ne $t) { $samples += [pscustomobject]@{ Frame = $i; Start = $t.TotalSeconds - ($pts[$i] - $start) } }
            }
            $best = $null; $bestN = 0
            foreach ($a in $samples) {
                $n = @($samples | Where-Object { [Math]::Abs($_.Start - $a.Start) -le 1.5 }).Count
                if ($n -gt $bestN) { $best = $a; $bestN = $n }
            }
            if ($bestN -lt 2) { throw "Could not get two consistent overlay readings in the first 5 s ($($samples.Count) readable)" }
            foreach ($a in $samples) {
                if ([Math]::Abs($a.Start - $best.Start) -gt 1.5) {
                    Write-Host ("   discarding misread at frame {0}" -f $a.Frame) -ForegroundColor DarkYellow
                    $Clip.Cache.Remove("$($Clip.Corner)/$($a.Frame)")
                }
            }
            # Plausibility window for every later read: clip span +/- 2 s around the agreed start
            $clipStartTs = [TimeSpan]::FromSeconds($best.Start)
            $Clip.MinOk = $clipStartTs - [TimeSpan]::FromSeconds(2)
            $Clip.MaxOk = $clipStartTs + [TimeSpan]::FromSeconds($clipLen + 2)

            # --- bracket the target ---
            $lo = Find-ReadableFrame 0 1
            if ($lo -lt 0) { throw 'Overlay unreadable in the first 15 s of the clip' }
            $tLo = Read-OverlayTime $lo
            $row.ClipFirstOverlay = Format-Ts $tLo

            if ($tLo -gt $targetTs) {
                if ($lo -eq 0) { $row.Status = "NotInClip (starts $tLo)"; continue }
                throw "Target falls in the unreadable start of the clip (first readable frame $lo shows $tLo)"
            }

            # Upper bracket: estimate where the target is from the first reading (+1.5 s margin) and
            # take the first readable frame from there; only fall back to the clip end if that fails
            $hi = -1
            if ($tLo -lt $targetTs) {
                $est = $lo + [int][Math]::Ceiling((($targetTs - $tLo).TotalSeconds + 1.5) * $Clip.Fps)
                if ($est -le $Clip.Last) {
                    $hi = Find-ReadableFrame $est 1 5
                    if ($hi -ge 0 -and (Read-OverlayTime $hi) -lt $targetTs) { $hi = -1 }
                }
            } else {
                $hi = $lo
            }
            if ($hi -lt 0) { $hi = Find-ReadableFrame $Clip.Last -1 }
            if ($hi -lt 0) { throw 'Overlay unreadable after the target and in the last 15 s of the clip' }
            $tHi = Read-OverlayTime $hi

            if ($tHi -lt $targetTs) {
                if ($hi -eq $Clip.Last) { $row.Status = "NotInClip (ends $tHi)"; continue }
                throw "Target falls in the unreadable end of the clip (last readable frame $hi shows $tHi)"
            }

            $status = $null
            if ($tLo -eq $targetTs) {
                $hi = $lo
                $status = 'StartsAtTarget'
            } else {
                # --- binary search: invariant  read(lo) < target <= read(hi) ---
                while ($hi - $lo -gt 1) {
                    $mid = [int][Math]::Floor(($lo + $hi) / 2)
                    $probe = $mid
                    $tm = Read-OverlayTime $mid
                    if ($null -eq $tm) {
                        $q = [Math]::Max(1, [int][Math]::Ceiling($Clip.Fps / 4))
                        foreach ($d in 1, -1, 2, -2, 3, -3, $q, -$q, (2 * $q), (-2 * $q), (3 * $q), (-3 * $q), (4 * $q), (-4 * $q)) {
                            $p = $mid + $d
                            if ($p -gt $lo -and $p -lt $hi) {
                                $tm = Read-OverlayTime $p
                                if ($null -ne $tm) { $probe = $p; break }
                            }
                        }
                        if ($null -eq $tm) { throw "Overlay unreadable around frame $mid" }
                    }
                    if ($tm -ge $targetTs) { $hi = $probe } else { $lo = $probe }
                }

                # --- verify; on failure rescan +/-1.5 s frame by frame ---
                if (Test-Transition $hi) {
                    $status = 'OK'
                } else {
                    $win = [int][Math]::Ceiling($Clip.Fps * 1.5)
                    $from = [Math]::Max(1, $hi - $win); $to = [Math]::Min($Clip.Last, $hi + $win)
                    Write-Host "   verification failed at frame $hi; rescanning frames $from-$to" -ForegroundColor Yellow
                    for ($i = $from; $i -le $to; $i++) {
                        if (Test-Transition $i) { $hi = $i; $status = 'OK'; break }
                    }
                    if (-not $status) { $status = 'CheckManually' }
                }
            }

            # --- extract the frame ---
            # "<camera> - YYYY-MM-DD HH.MM.jpg" (Windows forbids ':' in file names; date from the clip name)
            $clipDay = $null
            if ($f.BaseName -match '(\d{1,2})-(\d{1,2})-(\d{4}),') {
                $clipDay = [datetime]::new([int]$Matches[3], [int]$Matches[1], [int]$Matches[2])
            }
            $clipDate = if ($clipDay) { $clipDay.ToString('yyyy-MM-dd', $inv) } else { 'unknown-date' }
            $out = Join-Path $f.DirectoryName ('{0} - {1} {2:D2}.{3:D2}.jpg' -f $camera, $clipDate, $targetTs.Hours, $targetTs.Minutes)
            & $FFmpeg -v error -y -ss (Get-SeekArg $hi) -i $f.FullName -frames:v 1 -q:v $JpegQuality -update 1 $out
            if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed writing $out" }

            # EXIF capture time = clip date + the time shown on this frame; offset from the file name
            if ($clipDay) {
                $shown  = Read-OverlayTime $hi
                if ($null -eq $shown) { $shown = $targetTs }
                $taken  = $clipDay + $shown
                $offset = $UtcOffset
                if (-not $offset -and $f.BaseName -match '\d{1,2}\.\d{2}\.\d{2}\s+([A-Z]{2,5})\b') {
                    $offset = $TzOffsets[$Matches[1]]
                }
                Set-JpegCaptureTime $out $taken $offset
                $row.CaptureTime = $taken.ToString('yyyy-MM-dd HH:mm:ss', $inv) + $(if ($offset) { " $offset" } else { '' })
            } else {
                Write-Host '   no date in file name; EXIF capture time not written' -ForegroundColor Yellow
            }

            $row.Status          = $status
            $row.Frame           = $hi
            $row.SecondsIntoClip = ($pts[$hi] - $start).ToString('F3', $inv)
            $row.FrameOverlay    = Format-Ts (Read-OverlayTime $hi)
            $row.BeforeOverlay   = if ($hi -ge 1) { Format-Ts (Read-OverlayTime ($hi - 1)) } else { '' }
            $row.Output          = $out
        } catch {
            $row.Status = 'Error'
            $row.Error  = $_.Exception.Message
        } finally {
            if ($Clip) { $row.OcrReads = $Clip.Cache.Count }
            $Results.Add([pscustomobject]$row)
            $color = switch -Wildcard ($row.Status) { 'OK' { 'Green' } 'Calibrate' { 'Gray' } default { 'Yellow' } }
            Write-Host ("   {0}  frame={1}  t={2}s  overlay {3} -> {4}  corner={5}  {6}" -f `
                $row.Status, $row.Frame, $row.SecondsIntoClip, $row.BeforeOverlay, $row.FrameOverlay, $row.Corner, $row.Error) -ForegroundColor $color
            $Clip = $null
        }
    }
} finally {
    Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($Results.Count -gt 0) {
        $Results | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
        Write-Host "`nLog: $LogPath"
    }
}

# Non-zero exit if anything needs attention (for scheduled / scripted runs)
$bad = @($Results | Where-Object { $_.Status -notin 'OK', 'Calibrate' })
if ($bad.Count -gt 0) { exit 1 } else { exit 0 }