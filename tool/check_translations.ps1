# 校验 viewer 的 i18n 覆盖率。
#
# 硬性失败：源码引用的键在两份翻译里缺失 / zh 与 en 键集不一致 / 存在空值 /
# 翻译里有源码从不引用的多余键（避免文件腐化）。
#
# 用法：& .\tool\check_translations.ps1
# 退出码 0 = 通过；1 = 有问题。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $root 'lib'
$dartFiles = @(Get-ChildItem $lib -Recurse -Filter *.dart)

function Read-Translation([string]$path) {
  $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  $obj = ConvertFrom-Json -InputObject $text
  $map = @{}
  foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
  return $map
}

# UI 命名空间白名单：首段命中即认为是翻译键。
# 注意 motion.* 与引擎的 motion 方法名冲突，故单独用精确清单。
$namespaces = @('about', 'app', 'common', 'dialog', 'engine', 'menu', 'notice',
  'panel', 'progress', 'settings', 'shortcut', 'start', 'stat', 'status',
  'time', 'ui', 'viewer')
$motionKeys = @('motion.play', 'motion.pause', 'motion.loop', 'motion.speed',
  'motion.duration')

# 虽落在 UI 命名空间内、但实际是动作 id / 操作名 / 文件名的字面量，不算翻译键。
# （panel.left 这类动作 id 的翻译键是 shortcut.panel.left。）
$excluded = @('panel.left', 'panel.right', 'panel.bottom',
  'panel.fullscreenCanvas', 'settings.set')
$fileExtensions = @('dart', 'json', 'dll', 'so', 'dylib', 'png', 'jpg', 'md',
  'yaml', 'yml', 'toml', 'txt', 'amproj')

# diagnostics.stats 的字段名会被拼成 stat.<field>。
$statFields = @('nodes', 'parameters', 'textures', 'motions', 'expressions',
  'physics', 'drawables', 'revision', 'dirty', 'frame')

$used = New-Object System.Collections.Generic.HashSet[string]
$literalPattern = "'([a-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)'"
foreach ($f in $dartFiles) {
  $t = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
  foreach ($m in [regex]::Matches($t, $literalPattern)) {
    $key = $m.Groups[1].Value
    $parts = $key.Split('.')
    $head = $parts[0]
    $tail = $parts[-1]
    # 两段式且尾段是文件扩展名 → 是文件名（如 app.dart），不是翻译键。
    if ($parts.Count -eq 2 -and $fileExtensions -contains $tail) { continue }
    if ($excluded -contains $key) { continue }
    if ($namespaces -contains $head -or $motionKeys -contains $key) {
      [void]$used.Add($key)
    }
  }
  if ($t.Contains("'stat.`${")) {
    foreach ($field in $statFields) { [void]$used.Add("stat.$field") }
  }
}

$zh = Read-Translation (Join-Path $root 'assets\translations\zh-CN.json')
$en = Read-Translation (Join-Path $root 'assets\translations\en-US.json')

$missingZh = @($used | Where-Object { -not $zh.ContainsKey($_) } | Sort-Object)
$missingEn = @($used | Where-Object { -not $en.ContainsKey($_) } | Sort-Object)
$onlyZh = @($zh.Keys | Where-Object { -not $en.ContainsKey($_) } | Sort-Object)
$onlyEn = @($en.Keys | Where-Object { -not $zh.ContainsKey($_) } | Sort-Object)
$emptyZh = @($zh.Keys | Where-Object { $zh[$_] -eq '' } | Sort-Object)
$emptyEn = @($en.Keys | Where-Object { $en[$_] -eq '' } | Sort-Object)
$extraZh = @($zh.Keys | Where-Object { -not $used.Contains($_) } | Sort-Object)
$extraEn = @($en.Keys | Where-Object { -not $used.Contains($_) } | Sort-Object)

Write-Output "used=$($used.Count) zh=$($zh.Count) en=$($en.Count)"
Write-Output "missingInZh=$($missingZh.Count) missingInEn=$($missingEn.Count)"
Write-Output "onlyInZh=$($onlyZh.Count) onlyInEn=$($onlyEn.Count)"
Write-Output "emptyZh=$($emptyZh.Count) emptyEn=$($emptyEn.Count)"
Write-Output "extraZh=$($extraZh.Count) extraEn=$($extraEn.Count)"
if ($missingZh.Count) { Write-Output "MISSING_ZH: $($missingZh -join ', ')" }
if ($missingEn.Count) { Write-Output "MISSING_EN: $($missingEn -join ', ')" }
if ($onlyZh.Count) { Write-Output "ONLY_ZH: $($onlyZh -join ', ')" }
if ($onlyEn.Count) { Write-Output "ONLY_EN: $($onlyEn -join ', ')" }
if ($emptyZh.Count) { Write-Output "EMPTY_ZH: $($emptyZh -join ', ')" }
if ($emptyEn.Count) { Write-Output "EMPTY_EN: $($emptyEn -join ', ')" }
if ($extraZh.Count) { Write-Output "EXTRA_ZH: $($extraZh -join ', ')" }
if ($extraEn.Count) { Write-Output "EXTRA_EN: $($extraEn -join ', ')" }

$bad = $missingZh.Count + $missingEn.Count + $onlyZh.Count + $onlyEn.Count +
  $emptyZh.Count + $emptyEn.Count + $extraZh.Count + $extraEn.Count
if ($bad -gt 0) {
  Write-Output 'RESULT: FAIL'
  exit 1
}
Write-Output 'RESULT: OK'
exit 0
