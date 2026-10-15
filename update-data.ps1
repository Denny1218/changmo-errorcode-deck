# 창세기전 모바일 업데이트 게시판(네이버 게임 라운지 board 13)을 읽어 data.js 를 만듭니다.
# 사용법: 이 파일을 우클릭 → "PowerShell에서 실행"  (또는 update-data.bat 더블클릭)
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$cache = Join-Path $root 'cache'
New-Item -ItemType Directory -Force $cache | Out-Null
$api = 'https://comm-api.game.naver.com/nng_main/v1/community/lounge/theplayofgenesis'
$hdr = @{ 'User-Agent' = 'Mozilla/5.0'; 'Referer' = 'https://game.naver.com/' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Json($url) {
  $r = Invoke-WebRequest -UseBasicParsing -Headers $hdr $url
  return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}
function Clean($html) {
  $t = $html -replace '<br\s*/?>', "`n" -replace '</p>', "`n" -replace '<[^>]+>', ''
  $t = [Net.WebUtility]::HtmlDecode($t) -replace '[​ ]', ' '
  return (($t -split "`n" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { $_ }) -join "`n")
}
function OneLine($s) { return (($s -split "`n") -join ' ').Trim() }
function Norm-Attr($s) { return (($s -replace '\s*[\[\(].*$', '').Trim() -replace '결청체', '결정체') }
$ATTRS = '자유의 불꽃', '활력의 나무', '욕망의 그림자', '지성의 결정체', '신념의 빛'

# ---------- 1. 게시글 목록 + 본문 (캐시) ----------
Write-Host '게시글 목록을 가져오는 중...'
$list = @()
for ($p = 0; $p -lt 20; $p++) {
  $j = Get-Json "$api/feed?boardId=13&buffFilteringYN=N&limit=25&offset=$p&order=NEW" | ConvertFrom-Json
  if (-not $j.content.feeds -or $j.content.feeds.Count -eq 0) { break }
  $list += $j.content.feeds | ForEach-Object { $_.feed }
}
Write-Host "  총 $($list.Count)건"

$posts = @()
foreach ($f in $list) {
  $file = Join-Path $cache "$($f.feedId)_$($f.updatedDate).json"
  if (-not (Test-Path $file)) {
    Get-ChildItem $cache -Filter "$($f.feedId)_*.json" | Remove-Item -Force
    Write-Host "  다운로드: $($f.title)"
    [IO.File]::WriteAllText($file, (Get-Json "$api/feed/$($f.feedId)"), [Text.Encoding]::UTF8)
    Start-Sleep -Milliseconds 400
  }
  $d = ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json).content.feed
  $posts += [pscustomobject]@{ id = $d.feedId; date = $d.createdDate.Substring(0, 8); title = [Net.WebUtility]::HtmlDecode($d.title); html = $d.contents }
}
$posts = $posts | Sort-Object date   # 오래된 글부터 처리 → 최신 정보가 덮어씀

# ---------- 2. 파싱 ----------
$chars = [ordered]@{}; $weapons = [ordered]@{}; $armors = [ordered]@{}; $accs = [ordered]@{}; $seasons = @()
$artPairs = @(); $allArts = [ordered]@{}; $activeSkills = [ordered]@{}

function Get-Tables($html) {
  $out = @()
  foreach ($t in [regex]::Matches($html, '(?s)<table.*?</table>')) {
    $rows = @()
    foreach ($tr in [regex]::Matches($t.Value, '(?s)<tr.*?</tr>')) {
      $cells = @([regex]::Matches($tr.Value, '(?s)<td.*?>(.*?)</td>') | ForEach-Object { OneLine (Clean $_.Groups[1].Value) })
      $rows += , $cells
    }
    $out += , [pscustomobject]@{ rows = $rows; html = $t.Value }
  }
  return $out
}

foreach ($p in $posts) {
  $tables = Get-Tables $p.html
  $cur = $null
  for ($i = 0; $i -lt $tables.Count; $i++) {
    $rows = $tables[$i].rows
    if ($rows.Count -eq 0) { continue }
    $head = $rows[0] -join ' '
    $hdrIdx = -1
    for ($r = 0; $r -lt $rows.Count; $r++) { if (($rows[$r] -join '|') -match '^속성\|고유 ?패시브') { $hdrIdx = $r; break } }

    if ($hdrIdx -ge 0 -and $rows.Count -gt $hdrIdx + 1) {
      # 캐릭터 기본 정보 표
      $name = $rows[0][0]
      $v = $rows[$hdrIdx + 1]
      $img = ''
      $m = [regex]::Match($tables[$i].html, '<img[^>]+src="([^"]+)"'); if ($m.Success) { $img = $m.Groups[1].Value }
      $c = if ($chars.Contains($name)) { $chars[$name] } else { [ordered]@{ name = $name; attr = ''; weapon = ''; classes = @(); tiers = [ordered]@{}; artifacts = @(); released = $p.date; post = $p.id } }
      $c.attr = Norm-Attr $v[0]; $c.attrRaw = $v[0]
      if ($v.Count -ge 3) { $c.weapon = $v[2] }
      if ($img) { $c.img = $img }
      $chars[$name] = $c; $cur = $name
      continue
    }
    if ($cur -and $head -match '^전직 ?트리') {
      $all = @(); $tiers = [ordered]@{}
      foreach ($row in $rows[1..($rows.Count - 1)]) {
        if ($row.Count -lt 2) { continue }
        $tiers[$row[0]] = @($row[1..($row.Count - 1)] | Where-Object { $_ })
        $all += $tiers[$row[0]]
      }
      $chars[$cur].tiers = $tiers
      $t3 = @($tiers.Keys | Where-Object { $_ -match '3' } | ForEach-Object { $tiers[$_] })
      $chars[$cur].classes = if ($t3.Count) { @($t3 | Select-Object -Unique) } else { @($all | Select-Object -Unique) }
      continue
    }
    $flat = ($rows | ForEach-Object { $_ -join '|' }) -join "`n"
    # 아티팩트 표 — 형식 3가지
    #  ① "아티팩트" (신캐 소개 안, 바로 위 캐릭터 것)  ② "카이 아티팩트" + 행마다 이름  ③ "실버 아티팩트 [바람 걸음]" (2025년 형식)
    if ($rows[0].Count -le 2 -and $head -match '^(.*?)\s*(?:전용\s*)?(?:신규\s*)?아티팩트\s*(?:\[(.+?)\])?\s*$') {
      $who = $matches[1].Trim(); $single = $matches[2]
      if ($flat -match '변경 ?전|변경 ?후') { continue }   # 밸런스 변경 표는 건너뜀
      $names = if ($single) { @($single) } else {
        @($rows[1..($rows.Count - 1)] | ForEach-Object { $_[0] } |
          Where-Object { $_ -and $_.Length -le 16 -and $_ -notmatch '[%./]' -and $_ -ne '이름' }) }
      $names = @($names | ForEach-Object { ($_ -replace '\s*\d+-\d+$', '').Trim() } | Where-Object { $_ })
      $owners = if ($who -and $who -notmatch ':') { @($who -split '\s*및\s*') } elseif (-not $who -and -not $single -and $cur) { @($cur) } else { @() }
      foreach ($n in $names) {
        $allArts[$n] = 1
        foreach ($o in $owners) { $artPairs += [pscustomobject]@{ who = $o; name = $n; date = $p.date; bracket = [bool]$single } }
      }
      continue
    }
    # 액티브 스킬 이름 (밸런스 변경 공지에서만 나옴) — 스킬 검색 보조용
    if ($head -match '액티브 스킬') {
      if ($head -match '-\s*(.+)$') { $activeSkills[$matches[1].Trim()] = 1 }
      foreach ($row in $rows[1..($rows.Count - 1)]) { $n = $row[0]; if ($n -and $n.Length -le 12 -and $n -notmatch '[%.:/]' -and $n -notmatch '^이름$|^스킬$|변경|발현') { $activeSkills[$n] = 1 } }
      continue
    }
    if ($flat -match '전용 캐릭터' -and $flat -match '무기 타입') {
      $m = [regex]::Match($flat, '(?m)^[^|\n]*\|([^|\n]+)\|([^|\n]+)$')
      $owner = ''; foreach ($row in $rows) { if ($row.Count -ge 3 -and $row[0] -match '전설|희귀|영웅') { $owner = $row[2]; $wt = $row[1] } }
      $weapons[$rows[0][0]] = [ordered]@{ name = $rows[0][0]; type = $wt; owner = $owner; released = $p.date }
      continue
    }
    if ($flat -match '4세트 효과') {
      $e4 = ''; foreach ($row in $rows) { if ($row[0] -match '4세트') { $e4 = $row[1] } }
      $armors[$rows[0][0]] = [ordered]@{ name = $rows[0][0]; set4 = $e4; released = $p.date }
      continue
    }
    if ($flat -match '장신구' -and $flat -match '등급') {
      $accs[$rows[0][0]] = [ordered]@{ name = $rows[0][0]; released = $p.date }
      continue
    }
  }

  # 표가 없던 초기 공지: "신규 전설 캐릭터 [이름]과 전용 무기 [무기]" 문장에서 이름만이라도
  $plain = OneLine (Clean $p.html)
  foreach ($m in [regex]::Matches($plain, '신규 (?:전설 |희귀 |영웅 )?캐릭터 \[([^\]]+)\](?:[^\[]{0,6}전용 무기 \[([^\]]+)\])?')) {
    $n = $m.Groups[1].Value.Trim()
    if (-not $chars.Contains($n)) {
      $chars[$n] = [ordered]@{ name = $n; attr = ''; weapon = $m.Groups[2].Value; classes = @(); tiers = [ordered]@{}; artifacts = @(); released = $p.date; post = $p.id }
    }
  }

  # 에러코드 시즌 정보 (본문 텍스트)
  $lines = (Clean $p.html) -split "`n"
  for ($k = 0; $k -lt $lines.Count; $k++) {
    $ln = $lines[$k]
    if ($ln -notmatch '에러 ?코드' -or $ln -notmatch '정보|진행') { continue }
    if ($ln -match '보상|셔플|개선|수정|현상') { continue }
    $boss = if ($ln -match '아수라') { '아수라' } elseif ($ln -match '디에네') { '디에네' } else { continue }
    $mode = if ($ln -match '기사단') { '기사단' } else { '개인' }
    $sn = ''; $m = [regex]::Match($ln, '시즌\s*(\d+)(-\d+)?|(\d+)\s*시즌|디에네\s*(\d+-\d+)'); if ($m.Success) { $sn = ($m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value + $m.Groups[4].Value) }
    $block = @()
    for ($q = $k + 1; $q -lt [Math]::Min($lines.Count, $k + 25); $q++) {
      if ($lines[$q] -match '^\d+\)\s' -or $lines[$q] -match '^◆') { break }
      $block += $lines[$q]
    }
    $txt = $block -join "`n"
    $allowed = ''; $buff = ''; $rand = ''; $bd = ''
    for ($q = 0; $q -lt $block.Count; $q++) {
      $b = $block[$q]
      if ($b -match '입장할 수 있습니다\s*:?\s*(.*)') { $allowed = $matches[1] }
      elseif ($b -match '랜덤 캐릭터 버프 대상\s*:?\s*(.*)') { $rand = $matches[1]; $q2 = $q + 1; while ($q2 -lt $block.Count -and $block[$q2] -match '주차') { $rand += ' ' + $block[$q2]; $q2++ } }
      elseif ($b -match '캐릭터 버프 대상 정보\s*:?\s*(.*)') { $buff = $matches[1] }
      elseif ($b -match '버프/디버프\s*:?\s*(.*)') { $bd = $matches[1]; if (-not $bd -and $q + 1 -lt $block.Count) { $bd = $block[$q + 1] } }
    }
    $seasons += [ordered]@{ key = "$mode-$boss-$sn-$($p.date)"; mode = $mode; boss = $boss; season = $sn; postDate = $p.date; postId = $p.id; postTitle = $p.title;
      allowedText = $allowed; buffText = $buff; randomBuffText = $rand; buffDebuff = $bd; raw = $txt }
  }

  # 일정표에서 전투 일자(1차/2차...) 붙이기
  foreach ($t in $tables) {
    foreach ($row in $t.rows) {
      if ($row.Count -ge 2 -and $row[0] -match '에러 ?코드') {
        $boss = if ($row[0] -match '아수라') { '아수라' } elseif ($row[0] -match '디에네') { '디에네' } else { $null }
        $mode = if ($row[0] -match '기사단') { '기사단' } else { '개인' }
        foreach ($s in $seasons) { if ($s.postId -eq $p.id -and $s.boss -eq $boss -and $s.mode -eq $mode) { $s.schedule = $row[1] } }
      }
    }
  }
}

# 같은 글에서 중복으로 잡힌 시즌은 하나로
$seasons = @($seasons | Group-Object { "$($_.mode)|$($_.boss)|$($_.postId)" } | ForEach-Object { $_.Group | Sort-Object { -([string]$_.raw).Length } | Select-Object -First 1 })

# 공지마다 다르게 쓴 같은 캐릭터 이름 맞추기
$SAME = @{ '회색의 G.S' = '회색기사단 G.S' }
foreach ($s in $seasons) { foreach ($k in $SAME.Keys) { $s.randomBuffText = ([string]$s.randomBuffText).Replace($k, $SAME[$k]); $s.buffText = ([string]$s.buffText).Replace($k, $SAME[$k]) } }

# 출시 공지가 없는 초기(런칭) 캐릭터: 시즌 버프 대상 목록에 나온 이름으로 보충
foreach ($s in $seasons) {
  $txt = ($s.randomBuffText + ' / ' + $s.buffText) -replace '☑️', '' -replace '\d주차 전투\s*:', '/' -replace '신규 캐릭터 \[([^\]]+)\].*', '$1'
  foreach ($n in ($txt -split '[/,]')) {
    $n = ($n -replace '\s*등\s*$', '').Trim()
    if ($n.Length -lt 2 -or $n.Length -gt 14 -or $n -match '[:\[\]%]' -or $n -notmatch '[가-힣]') { continue }
    if (-not $chars.Contains($n)) {
      $chars[$n] = [ordered]@{ name = $n; attr = ''; weapon = ''; classes = @(); tiers = [ordered]@{}; artifacts = @(); released = ''; source = 'buff-list' }
    }
  }
}
# 아티팩트를 캐릭터에 연결 (공지마다 띄어쓰기가 달라서 공백 없이도 비교)
$noSpace = @{}; foreach ($k in $chars.Keys) { $noSpace[($k -replace '\s', '')] = $k }
foreach ($a in $artPairs) {
  $key = if ($chars.Contains($a.who)) { $a.who } else { $noSpace[($a.who -replace '\s', '')] }
  if (-not $key) {
    if (-not $a.bracket -or $a.who.Length -lt 2) { continue }   # "거너 아티팩트" 같은 클래스 표는 무시
    $key = $a.who
    $chars[$key] = [ordered]@{ name = $key; attr = ''; weapon = ''; classes = @(); tiers = [ordered]@{}; artifacts = @(); released = ''; source = 'artifact' }
    $noSpace[($key -replace '\s', '')] = $key
  }
  if (@($chars[$key].artifacts) -notcontains $a.name) { $chars[$key].artifacts = @($chars[$key].artifacts) + $a.name }
}

function Find-Names($text) {
  # "쿤 그리어"가 "수제자 쿤 그리어" 안에서 잡히지 않도록 긴 이름부터 찾아 지워 나감
  $found = @()
  foreach ($n in ($chars.Keys | Sort-Object { -$_.Length })) {
    if ($text -match [regex]::Escape($n)) { $found += $n; $text = $text -replace [regex]::Escape($n), '#' }
  }
  return , $found
}
foreach ($s in $seasons) {
  $s.allowed = @($ATTRS | Where-Object { $s.allowedText -match $_ })
  $s.buffChars = Find-Names $s.buffText
  $s.randomBuffChars = Find-Names $s.randomBuffText
}

$data = [ordered]@{
  generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm')
  postCount   = $posts.Count
  characters  = @($chars.Values)
  weapons     = @($weapons.Values)
  armors      = @($armors.Values)
  accessories = @($accs.Values)
  artifacts   = @($allArts.Keys)
  activeSkills = @($activeSkills.Keys)
  seasons     = @($seasons | Sort-Object { $_.postDate } -Descending)
}
$json = $data | ConvertTo-Json -Depth 8 -Compress
# 내용이 같으면(만든 시각만 다르면) 파일을 그대로 둠 → 자동 갱신 때 쓸데없는 커밋이 안 생김
$dataFile = Join-Path $root 'data.js'
$stamp = '"generatedAt":"[^"]*"'
$old = if (Test-Path $dataFile) { [IO.File]::ReadAllText($dataFile, [Text.Encoding]::UTF8) } else { '' }
Write-Host ''
Write-Host "완료: 캐릭터 $($chars.Count) / 무기 $($weapons.Count) / 방어구 $($armors.Count) / 장신구 $($accs.Count) / 에러코드 시즌 $($seasons.Count)"
if (($old -replace $stamp, '').Trim() -eq ("window.GENESIS_DATA = $json;" -replace $stamp, '').Trim()) {
  Write-Host "새 공지가 없어서 data.js 는 그대로예요."
} else {
  [IO.File]::WriteAllText($dataFile, "window.GENESIS_DATA = $json;`n", (New-Object Text.UTF8Encoding $false))
  Write-Host "data.js 를 갱신했습니다. index.html 을 새로고침하세요."
}
