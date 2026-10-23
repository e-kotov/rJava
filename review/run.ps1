$ErrorActionPreference = 'Stop'
$work = Join-Path $env:RUNNER_TEMP 'review'
$rscript = Join-Path $env:R_HOME_DIR 'bin/x64/Rscript.exe'
$probe = Join-Path $env:GITHUB_WORKSPACE 'review/probe.R'
$workload = Join-Path $env:GITHUB_WORKSPACE 'review/windows-workload.R'
$mutex = Join-Path $work 'native/mutex.dll'
$mods = Join-Path $work 'native/modules.dll'
$system = Join-Path $env:SystemRoot 'System32'
$names = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll')
$jdks = $env:REVIEW_JDKS | ConvertFrom-Json
$rows = [Collections.Generic.List[object]]::new()
$env:NOAWT = '1'
$env:PATH = @((Join-Path $env:R_HOME_DIR 'bin/x64'), $system, $env:SystemRoot) -join ';'

Write-Output '== System32 runtime versions'
foreach ($n in $names) { $p = Join-Path $system $n; if (Test-Path $p) { Write-Output "SYSTEM32 $n $((Get-Item $p).VersionInfo.FileVersion)" } }
Write-Output '== JDK-bundled runtime versions'
foreach ($j in $jdks.PSObject.Properties) {
    foreach ($bin in @((Join-Path $j.Value 'bin'), (Join-Path $j.Value 'jre/bin'))) {
        foreach ($n in $names) { $p = Join-Path $bin $n; if (Test-Path $p) { Write-Output "BUNDLED $($j.Name) $p $((Get-Item $p).VersionInfo.FileVersion)" } }
    }
}

function Probe([string]$jdk, [string]$build, [string]$scenario, [string]$fixture) {
    $home_ = $jdks.$jdk
    $env:JAVA_HOME = $home_
    $lib = if ($build -eq '-') { '-' } else { Join-Path $work "lib/$build" }
    $label = "$fixture-$jdk-$build-$scenario"
    $argv = @('--vanilla', $probe, $lib, $scenario, $mutex, $mods, $home_, $workload) | ForEach-Object { '"' + $_ + '"' }
    $out = Join-Path $work "logs/$label.out"; $err = Join-Path $work "logs/$label.err"
    $p = Start-Process -FilePath $rscript -ArgumentList $argv -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
    if (!$p.WaitForExit(180000)) { $p.Kill(); $code = 124 } else { $p.Refresh(); $code = $p.ExitCode }
    $text = (Get-Content $out -Raw) + (Get-Content $err -Raw)
    $status = if ($code -eq 0 -and $text -match 'RESULT\|PASS') { 'PASS' } elseif ($code -eq -1073741819) { 'CRASH(0xC0000005)' } else { "FAIL($code)" }
    $rows.Add([pscustomobject]@{fixture=$fixture; jdk=$jdk; build=$build; scenario=$scenario; status=$status; exit=$code})
    Write-Output "OBSERVATION $label => $status"
    ($text -split "`n" | Where-Object { $_ -match 'MODULE\||STAGE|MUTEX|JAVA |RESULT|Error|rJava:' }) | Write-Output
}

foreach ($jdk in $jdks.PSObject.Properties.Name) {
    Probe $jdk '-' 'plain' 'normal'
    Probe $jdk '-' 'jdk-msvcp-then-mutex' 'normal'
    foreach ($build in 'master', 'candidate', 'fix') {
        Probe $jdk $build 'jinit-then-mutex' 'normal'
        Probe $jdk $build 'mutex-then-jinit' 'normal'
    }
}
# Missing system runtimes: the case the candidate's MSVC retention cures.
$hidden = @()
if (!$env:REVIEW_SKIP_MISSING) { try {
    foreach ($n in $names) {
        $p = Join-Path $system $n
        if (Test-Path $p) {
            takeown /f $p | Out-Null; icacls $p /grant '*S-1-5-32-544:F' | Out-Null
            Rename-Item $p "$n.review-hidden"; $hidden += $p
        }
        if (Test-Path $p) { throw "cannot hide $p" }
    }
    foreach ($jdk in $jdks.PSObject.Properties.Name) {
        foreach ($build in 'master', 'candidate', 'fix') { Probe $jdk $build 'missing-workload' 'missing' }
    }
} finally { foreach ($p in $hidden) { Rename-Item "$p.review-hidden" (Split-Path $p -Leaf) } } }

$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
$rows | Export-Csv -NoTypeInformation (Join-Path $work 'results.csv')
$md = @('| fixture | jdk | build | scenario | status |', '|---|---|---|---|---|') + ($rows | ForEach-Object { "| $($_.fixture) | $($_.jdk) | $($_.build) | $($_.scenario) | $($_.status) |" })
$md | Add-Content $env:GITHUB_STEP_SUMMARY
