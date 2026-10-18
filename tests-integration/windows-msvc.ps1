param([ValidateSet('normal', 'missing', 'old')][string]$Mode)
$ErrorActionPreference = 'Stop'
$names = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll')
$system = Join-Path $env:SystemRoot 'System32'
$work = Join-Path $env:RUNNER_TEMP 'msvc-2015'
$hidden = @()
$installed = @()
function Invoke-R([string[]]$RArguments) {
    & Rscript --vanilla @RArguments
    if ($LASTEXITCODE -ne 0) { throw "R test failed ($Mode): $RArguments" }
}
if ($Mode -eq 'old') {
    New-Item -ItemType Directory -Force $work | Out-Null
    $exe = Join-Path $work 'vc_redist.x64.exe'
    # Microsoft Visual C++ 2015 Update 3, 14.0.24212.0. Never install it globally.
    # Official download page: https://www.microsoft.com/en-us/download/details.aspx?id=53587
    Invoke-WebRequest 'https://download.microsoft.com/download/6/d/f/6df3ff94-f7f9-4f0b-838c-a328d1a7d0ee/vc_redist.x64.exe' -OutFile $exe
    if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne 'D7257265DBC0635C96DD67DDF938A09ABE0866CB2D4FA05F8B758C8644E724E4') { throw 'VC++ 2015 installer SHA256 mismatch' }
    # Extract its pinned Burn payload cabinet, then its Minimum Runtime cabinet.
    # The cabinet offsets/length correspond to the exact SHA256 above.
    $bytes = [IO.File]::ReadAllBytes($exe)
    $cab = New-Object byte[] 14465070
    [Array]::Copy($bytes, 821856, $cab, 0, $cab.Length)
    [IO.File]::WriteAllBytes((Join-Path $work 'payload.cab'), $cab)
    & 7z x -y "-o$work/payload" "$work/payload.cab" a10 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Burn payload extraction failed' }
    & 7z x -y "-o$work/old" "$work/payload/a10" msvcp140.dll vcruntime140.dll | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Runtime cabinet extraction failed' }
    foreach ($name in 'msvcp140.dll', 'vcruntime140.dll') {
        $old = Get-Item "$work/old/$name"
        if ($old.VersionInfo.FileMajorPart -ne 14 -or $old.VersionInfo.FileMinorPart -ne 0 -or $old.VersionInfo.FileBuildPart -ne 24212) { throw "Wrong old runtime: $name" }
        Write-Output "Old fixture $name version $($old.VersionInfo.FileVersion), SHA256 $((Get-FileHash $old).Hash)"
        foreach ($home in $env:RJE_JAVA_HOME_A, $env:RJE_JAVA_HOME_B) {
            $bundles = Get-ChildItem $home -Recurse -Filter $name
            if (!$bundles) { throw "No bundled $name in $home" }
            foreach ($bundle in $bundles) {
                $v = $bundle.VersionInfo
                $version = [version]::new($v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart)
                if ($version -le [version]'14.0.24212.0') { throw "Fixture is not older than $bundle ($version)" }
                Write-Output "JDK $bundle version $version"
            }
        }
    }
}
try {
    if ($Mode -ne 'normal') {
        foreach ($name in $names) {
            $path = Join-Path $system $name
            if (Test-Path $path) {
                takeown /f $path | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "takeown failed: $path" }
                icacls $path /grant '*S-1-5-32-544:F' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "icacls failed: $path" }
                Rename-Item $path "$name.rjava-hidden"
                $hidden += $path
            }
            if (Test-Path $path) { throw "Runtime still visible: $path" }
        }
        if ($Mode -eq 'old') {
            foreach ($name in 'msvcp140.dll', 'vcruntime140.dll') {
                $path = Join-Path $system $name
                Copy-Item "$work/old/$name" $path
                $installed += $path
            }
            # Positive control: a clean R process really can load the old system DLL.
            Invoke-R -RArguments @('-e', 'p <- file.path(Sys.getenv("SystemRoot"), "System32", "msvcp140.dll"); d <- dyn.load(p); stopifnot(tolower(normalizePath(d[["path"]])) == tolower(normalizePath(p))); cat("PASS old System32 runtime control\n")')
        }
    }
    Write-Output "Testing runtime policy: $Mode"
    Invoke-R -RArguments @('tests-integration/msvc.R', 'retained')
    Invoke-R -RArguments @('tests-integration/msvc.R', 'laterload')
    Invoke-R -RArguments @('tests-integration/msvc.R', 'laterload', 'b')
    Invoke-R -RArguments @('tests-integration/msvc.R', 'hosted', 'laterload')
    Invoke-R -RArguments @('tests-integration/msvc.R', 'hosted', 'laterload-b')
    if ($Mode -ne 'normal') {
        Invoke-R -RArguments @('tests-integration/jri.R')
        $a = $env:RJE_JAVA_HOME_A
        $b = $env:RJE_JAVA_HOME_B
        try {
            $env:RJE_JAVA_HOME_A = $b
            $env:RJE_JAVA_HOME_B = $a
            Invoke-R -RArguments @('tests-integration/jri.R')
        } finally {
            $env:RJE_JAVA_HOME_A = $a
            $env:RJE_JAVA_HOME_B = $b
        }
    }
} finally {
    foreach ($path in $installed) { Remove-Item $path -Force }
    foreach ($path in $hidden) { Rename-Item "$path.rjava-hidden" (Split-Path $path -Leaf) }
}
