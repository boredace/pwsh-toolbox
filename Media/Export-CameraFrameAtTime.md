# Export-CameraFrameAtTime: installing dependencies

[`Export-CameraFrameAtTime.ps1`](Export-CameraFrameAtTime.ps1) uses two external command-line tools. Everything else, including writing the EXIF capture time, is built into the script.

| Tool | Used for | Version |
|---|---|---|
| [FFmpeg](https://ffmpeg.org/) (`ffmpeg.exe`, `ffprobe.exe`) | Listing frame timestamps, cropping the overlay, saving the JPEG | Any recent build |
| [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) (`tesseract.exe` + `eng.traineddata`) | Reading the camera's on-screen clock | 5.x (tested with 5.5.3) |

Both tools run locally. The script sends nothing over the network.

PowerShell: Windows PowerShell 5.1 or PowerShell 7.

## Default paths

The script looks for the tools here unless you pass different paths:

| Parameter | Default |
|---|---|
| `-FFmpeg` | `C:\tools\bin\ffmpeg\bin\ffmpeg.exe` |
| `-FFprobe` | `C:\tools\bin\ffmpeg\bin\ffprobe.exe` |
| `-Tesseract` | `C:\tools\bin\tesseract\tesseract.exe` |
| `-TessdataDir` | *(empty: Tesseract's own `tessdata` folder)* |

The script checks these as file paths, not through `PATH`. Having `ffmpeg` on `PATH` is not enough: either install to the default paths (option B) or pass full paths (option A).

## Option A: install with winget

The quickest option. The tools go into winget's own locations, so you pass their paths to the script.

```powershell
winget install --id Gyan.FFmpeg -e
winget install --id UB-Mannheim.TesseractOCR -e
```

Open a new PowerShell window so `PATH` picks up FFmpeg, then find the full paths:

```powershell
(Get-Command ffmpeg).Source
(Get-Command ffprobe).Source
Test-Path 'C:\Program Files\Tesseract-OCR\tesseract.exe'
```

The Tesseract installer does not add itself to `PATH`. Its default folder is `C:\Program Files\Tesseract-OCR`.

Pass the paths when you run the script:

```powershell
.\Export-CameraFrameAtTime.ps1 -Folder 'D:\cam' `
    -FFmpeg    (Get-Command ffmpeg).Source `
    -FFprobe   (Get-Command ffprobe).Source `
    -Tesseract 'C:\Program Files\Tesseract-OCR\tesseract.exe'
```

## Option B: install to the default paths

Use this if you want to run the script without passing tool paths.

### FFmpeg

1. Download a Windows build, for example `ffmpeg-release-essentials.zip` from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/).
2. Extract it and rename the extracted folder (`ffmpeg-<version>-essentials_build`) to `ffmpeg`.
3. Move it to `C:\tools\bin\`, so that these files exist:

   ```text
   C:\tools\bin\ffmpeg\bin\ffmpeg.exe
   C:\tools\bin\ffmpeg\bin\ffprobe.exe
   ```

### Tesseract OCR

1. Download the Windows installer (`tesseract-ocr-w64-setup-5.x.x.exe`) from the [UB Mannheim Tesseract page](https://github.com/UB-Mannheim/tesseract/wiki).
2. Run it. When it asks for the destination folder, enter `C:\tools\bin\tesseract`.
3. Keep the default components. English (`eng.traineddata`) is always included.

These files should now exist:

```text
C:\tools\bin\tesseract\tesseract.exe
C:\tools\bin\tesseract\tessdata\eng.traineddata
```

## Language data (`eng.traineddata`)

The script runs Tesseract with `-l eng`. The UB Mannheim installer includes it, so normally there is nothing to do.

If your Tesseract has no `eng.traineddata` (for example a portable build), download it from [tesseract-ocr/tessdata](https://github.com/tesseract-ocr/tessdata), put it in any folder, and point the script at that folder:

```powershell
.\Export-CameraFrameAtTime.ps1 -Folder 'D:\cam' -TessdataDir 'C:\tools\tessdata'
```

## Check the install

Run each tool once. Each command should print a version and no error:

```powershell
& 'C:\tools\bin\ffmpeg\bin\ffmpeg.exe' -version | Select-Object -First 1
& 'C:\tools\bin\ffmpeg\bin\ffprobe.exe' -version | Select-Object -First 1
& 'C:\tools\bin\tesseract\tesseract.exe' --version
& 'C:\tools\bin\tesseract\tesseract.exe' --list-langs
```

`--list-langs` should include `eng`. Adjust the paths if you used option A.

## Unblock the script

A downloaded script may be blocked by your execution policy. Read it first, then unblock it:

```powershell
Unblock-File .\Media\Export-CameraFrameAtTime.ps1
```

## First run

Start with `-Calibrate` to confirm OCR can read the overlay before running a full search:

```powershell
.\Export-CameraFrameAtTime.ps1 -Folder 'D:\cam' -Calibrate
```

It saves the corner crops it OCRs as `_calib-*.png` in the clip folder and prints what Tesseract read. If the clock is cut off, adjust `-CornerWidth` / `-CornerHeight`. Then run without `-Calibrate`:

```powershell
.\Export-CameraFrameAtTime.ps1 -Folder 'D:\cam' -Target '12:00:00'
```

See `Get-Help .\Media\Export-CameraFrameAtTime.ps1 -Full` for all parameters.

## Troubleshooting

| Error | Cause and fix |
|---|---|
| `Not found: C:\tools\bin\...` | A tool is not at the default path. Install it there (option B) or pass `-FFmpeg` / `-FFprobe` / `-Tesseract`. |
| `eng.traineddata not found in <folder>` | `-TessdataDir` points to a folder without the English model. Download `eng.traineddata` into it. |
| `tesseract failed on ... (exit 1)` | Usually missing language data. Run `tesseract --list-langs` and check that `eng` is listed. |
| `ffprobe returned no video timestamps` | The file has no readable video stream. Check that it plays and matches `-Filter` (default `*.mp4`). |
