$ErrorActionPreference = 'Stop'
$work = $env:RJE_COMPARE_ROOT
$rows = [Collections.Generic.List[object]]::new()
$names = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll')
$system = Join-Path $env:SystemRoot 'System32'
$script = Join-Path $env:GITHUB_WORKSPACE 'tests-integration/windows-compare.R'
$rscript = $env:RJE_COMPARE_RSCRIPT
$env:R_HOME = $env:RJE_COMPARE_R_HOME
$env:JAVA_HOME = $env:RJE_JAVA_HOME_TEST
$env:NOAWT = '1'
$probePath = @((Join-Path $env:R_HOME 'bin/x64'), (Join-Path $env:R_HOME 'bin'), $system, $env:SystemRoot) -join ';'
foreach ($build in 'master', 'candidate', 'msvc', 'current', 'jri') {
    $jarPresent = Test-Path "$work/lib/$build/rJava/jri/JRI.jar"
    if ($jarPresent -ne ($build -eq 'jri')) { throw "Unexpected bundled JRI presence for $build" }
    Write-Output "PACKAGING $build JRI.jar=$jarPresent"
}

function Probe([string]$fixture, [string]$build, [string]$scenario) {
    $label = "$fixture-$build-$scenario"
    $library = "$work/lib/$build"
    $env:R_LIBS = $library
    $env:R_LIBS_USER = $library
    $savedPath = $env:PATH
    $env:PATH = $probePath
    try {
        if ($scenario -eq 'external-jri') {
            $exe = Join-Path $env:RJE_JAVA_HOME_TEST 'bin/java.exe'
            $native = "$work/lib/jri/rJava/jri/x64"
            if (!(Test-Path $native)) { $native = "$work/lib/jri/rJava/jri" }
            $cp = @("$work/lib/jri/rJava/jri/JRI.jar", "$library/rJava/java/boot", "$work/classes") -join ';'
            $arguments = @("-Djava.library.path=$native", '-cp', $cp, 'WindowsCompareJri')
        } else {
            $exe = $rscript
            $arguments = @('--vanilla', $script, $library, $scenario)
        }
        $quoted = $arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
        $out = "$work/logs/$label.stdout"
        $err = "$work/logs/$label.stderr"
        $process = Start-Process -FilePath $exe -ArgumentList $quoted -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
        $timeout = !$process.WaitForExit(120000)
        if ($timeout) { $process.Kill(); $process.WaitForExit() }
        $process.Refresh()
        $code = if ($timeout) { 124 } else { $process.ExitCode }
        $text = (Get-Content $out -Raw) + (Get-Content $err -Raw)
        $valid = $text -match '(RESULT\||PASS external JRI host|FAIL external JRI host|Exception|Error)'
        if (!$valid) { throw "Probe produced no interpretable result: $label exit $code`n$text" }
        $status = if ($code -eq 0) { 'PASS' } else { 'FAIL' }
        $row = [pscustomobject]@{fixture=$fixture; build=$build; scenario=$scenario; status=$status; exit=$code; log=$label}
        $rows.Add($row)
        Write-Output "OBSERVATION $fixture $build $scenario => $status ($code)"
        ($text -split "`n" | Select-Object -Last 6) | Write-Output
    } finally { $env:PATH = $savedPath }
}

# Genuine VC++ 2015 Update 3 payload, pinned and extracted without installing.
$old = "$work/vc2015"
New-Item -ItemType Directory -Force $old | Out-Null
$exe = "$old/vc_redist.x64.exe"
Invoke-WebRequest 'https://download.microsoft.com/download/6/d/f/6df3ff94-f7f9-4f0b-838c-a328d1a7d0ee/vc_redist.x64.exe' -OutFile $exe
if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne 'D7257265DBC0635C96DD67DDF938A09ABE0866CB2D4FA05F8B758C8644E724E4') { throw 'VC++ payload SHA256 mismatch' }
$bytes = [IO.File]::ReadAllBytes($exe)
$cab = New-Object byte[] 14465070
[Array]::Copy($bytes, 821856, $cab, 0, $cab.Length)
[IO.File]::WriteAllBytes("$old/payload.cab", $cab)
& 7z x -y "-o$old/payload" "$old/payload.cab" a10 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'VC++ payload extraction failed' }
& 7z x -y "-o$old/dlls" "$old/payload/a10" msvcp140.dll vcruntime140.dll | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'VC++ DLL extraction failed' }
foreach ($name in 'msvcp140.dll', 'vcruntime140.dll') {
    $v = (Get-Item "$old/dlls/$name").VersionInfo
    if ($v.FileMajorPart -ne 14 -or $v.FileMinorPart -ne 0 -or $v.FileBuildPart -ne 24212) { throw "Wrong old fixture $name" }
}

foreach ($fixture in 'normal', 'missing', 'old') {
    $hidden = @()
    $installed = @()
    try {
        if ($fixture -ne 'normal') {
            foreach ($name in $names) {
                $path = Join-Path $system $name
                if (Test-Path $path) {
                    takeown /f $path | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "takeown failed: $path" }
                    icacls $path /grant '*S-1-5-32-544:F' | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "icacls failed: $path" }
                    Rename-Item $path "$name.rjava-comparison-hidden"
                    $hidden += $path
                }
                if (Test-Path $path) { throw "Cannot establish missing-system fixture: $path" }
            }
            if ($fixture -eq 'old') {
                foreach ($name in 'msvcp140.dll', 'vcruntime140.dll') {
                    $path = Join-Path $system $name
                    Copy-Item "$old/dlls/$name" $path
                    $installed += $path
                    if ((Get-FileHash $path).Hash -ne (Get-FileHash "$old/dlls/$name").Hash) { throw 'System fixture differs from pinned DLL' }
                }
            }
        }
        Write-Output "FIXTURE $fixture"
        foreach ($name in $names) {
            $path = Join-Path $system $name
            if (Test-Path $path) { Write-Output "$path version $((Get-Item $path).VersionInfo.FileVersion)" }
        }
        foreach ($build in 'master', 'candidate', 'msvc', 'current') {
            foreach ($scenario in 'fresh', 'hosted') { Probe $fixture $build $scenario }
        }
        foreach ($build in 'msvc', 'current') { Probe $fixture $build 'retained' }
        if ($fixture -eq 'normal') {
            foreach ($build in 'master', 'candidate', 'current', 'jri') {
                Probe $fixture $build 'external-jri'
                Probe $fixture $build 'bundled-jri'
            }
        }
    } finally {
        foreach ($path in $installed) { Remove-Item $path -Force }
        foreach ($path in $hidden) { Rename-Item "$path.rjava-comparison-hidden" (Split-Path $path -Leaf) }
    }
}
$rows | Export-Csv -NoTypeInformation "$work/results.csv"
$rows | ConvertTo-Json -Depth 4 | Set-Content "$work/results.json"
$summary = [Collections.Generic.List[string]]::new()
$summary.Add('### Windows compatibility comparison')
$summary.Add("Master 534ff33; minimal pre-MSVC candidate fdbe195; current combined candidate $env:UPSTREAM_CANDIDATE. MSVC-only and JRI-only controls restore their respective changes from cd6bbe5.")
$summary.Add('')
$summary.Add('| System VC++ | Scenario | Master | Minimal candidate | MSVC only | Current candidate | Interpretation |')
$summary.Add('|---|---|---|---|---|---|---|')
$regressions = 0
foreach ($fixture in 'normal', 'missing', 'old') {
    foreach ($scenario in 'fresh', 'hosted') {
        $m = ($rows | Where-Object { $_.fixture -eq $fixture -and $_.build -eq 'master' -and $_.scenario -eq $scenario }).status
        $c = ($rows | Where-Object { $_.fixture -eq $fixture -and $_.build -eq 'candidate' -and $_.scenario -eq $scenario }).status
        $e = ($rows | Where-Object { $_.fixture -eq $fixture -and $_.build -eq 'msvc' -and $_.scenario -eq $scenario }).status
        $n = ($rows | Where-Object { $_.fixture -eq $fixture -and $_.build -eq 'current' -and $_.scenario -eq $scenario }).status
        $meaning = if ($m -eq 'PASS' -and $c -eq 'FAIL') { $regressions++; 'Candidate regression: inspect stage and module origins' }
                   elseif ($m -eq 'FAIL' -and $c -eq 'FAIL' -and $e -eq 'PASS') { 'MSVC enhancement extends baseline compatibility' }
                   elseif ($m -eq 'PASS' -and $c -eq 'PASS') { 'No enhancement required in this case' }
                   else { 'Inspect logs; outcome does not establish necessity' }
        $summary.Add("| $fixture | $scenario | $m | $c | $e | $n | $meaning |")
    }
}
$summary.Add('')
$summary.Add('Current-candidate lifetime checks:')
foreach ($row in ($rows | Where-Object { $_.build -eq 'current' -and $_.scenario -eq 'retained' })) {
    $summary.Add("- $($row.fixture) / original owner releases MSVC DLLs: $($row.status)")
}
$summary.Add('')
$summary.Add('JRI observations (an external application supplies the JRI-only build as its own dependency):')
foreach ($row in ($rows | Where-Object { $_.scenario -match 'jri' })) {
    $summary.Add("- $($row.build) / $($row.scenario): $($row.status)")
}
$summary.Add('')
$summary.Add('Missing/old system DLLs are controlled deployment conditions, not prevalence estimates. Loaded DLL origins before and after Java are in the logs. This is a hosted worker with altered system VC++ DLLs, not a clean Windows VM image.')
$summary | Set-Content "$work/summary.md"
$summary | Add-Content $env:GITHUB_STEP_SUMMARY
if ($regressions) { throw "$regressions candidate-only failures need investigation" }
foreach ($build in 'master', 'candidate', 'msvc', 'current') {
    if ($rows | Where-Object { $_.fixture -eq 'normal' -and $_.build -eq $build -and $_.scenario -in @('fresh', 'hosted') -and $_.status -ne 'PASS' }) { throw "Normal-system workload failed: $build" }
}
foreach ($build in 'master', 'candidate', 'current', 'jri') {
    if ($rows | Where-Object { $_.build -eq $build -and $_.scenario -eq 'external-jri' -and $_.status -ne 'PASS' }) { throw "External JRI application failed: $build" }
}
if (($rows | Where-Object { $_.build -eq 'jri' -and $_.scenario -eq 'bundled-jri' }).status -ne 'PASS') { throw 'Bundled JRI positive control failed' }

if ($rows | Where-Object { $_.build -eq 'current' -and $_.scenario -in @('fresh', 'hosted', 'retained') -and $_.status -ne 'PASS' }) {
    throw 'Combined main candidate failed a Windows deployment workload'
}
