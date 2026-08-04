# Мониторинг загрузки GPU и моделей, занимающих VRAM.
# Примеры:
#   .\gpu-watch.ps1 -Once                 разовый снимок
#   .\gpu-watch.ps1                       наблюдение каждые 5 с, Ctrl+C — стоп
#   .\gpu-watch.ps1 -IntervalSec 2 -Minutes 10
#   .\gpu-watch.ps1 -History 30           пики за прошедшие 30 мин (из Netdata)
[CmdletBinding()]
param(
  [int]$IntervalSec = 5,
  [int]$Minutes = 0,          # 0 — без ограничения по времени
  [switch]$Once,
  [int]$History = 0,          # минут назад; требует запущенный контейнер netdata
  [int]$Buckets = 10,         # на сколько интервалов делить историю
  [string]$LogDir = "$PSScriptRoot\logs"
)

$OllamaApi = 'http://127.0.0.1:11434/api/ps'
$NetdataApi = 'http://127.0.0.1:19999/api/v1'

# --- история: пики за период из базы Netdata -----------------------------------
# nvidia-smi показывает только «сейчас». Прошедшие пики (модель уже выгружена,
# вентиляторы уже стихли) остаются только в базе Netdata.
function Get-GpuChartId([string]$metric) {
  $charts = (Invoke-RestMethod "$NetdataApi/charts" -TimeoutSec 15).charts
  $charts.PSObject.Properties.Name |
    Where-Object { $_ -like "nvidia_smi.gpu_*_$metric" } | Select-Object -First 1
}

function Get-Peaks([string]$chartId, [int]$minutes, [int]$points, [string]$dimension) {
  if (-not $chartId) { return @() }
  $url = "$NetdataApi/data?chart=$chartId&after=-$($minutes * 60)" +
         "&points=$points&group=max&format=json"
  if ($dimension) { $url += "&dimensions=$dimension" }
  (Invoke-RestMethod $url -TimeoutSec 25).data
}

function Show-History([int]$minutes, [int]$points) {
  $metrics = [ordered]@{
    'ЗагрузкаGPU' = @('gpu_utilization', $null)
    'МощностьВт'  = @('power_draw', $null)
    'ТемпC'       = @('temperature', $null)
    'VramМБ'      = @('frame_buffer_memory_usage', 'used')
  }

  $series = @{}
  foreach ($name in $metrics.Keys) {
    $metric, $dimension = $metrics[$name]
    $series[$name] = Get-Peaks (Get-GpuChartId $metric) $minutes $points $dimension
  }

  $times = $series['ЗагрузкаGPU']
  if (-not $times) {
    Write-Host 'Нет данных: контейнер netdata не запущен или история пуста.' `
      -ForegroundColor Red
    return
  }

  $rows = foreach ($i in 0..($times.Count - 1)) {
    $stamp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$times[$i][0]).LocalDateTime
    [pscustomobject]@{
      'Время'       = $stamp.ToString('HH:mm')
      'Загрузка %'  = [int][math]::Round([double]$times[$i][1])
      'Мощность Вт' = [int][math]::Round([double]$series['МощностьВт'][$i][1])
      'Темп °C'     = [int][math]::Round([double]$series['ТемпC'][$i][1])
      'VRAM МБ'     = [int][math]::Round([double]$series['VramМБ'][$i][1] / 1MB)
    }
  }
  Write-Host "Пики за последние $minutes мин (максимум в каждом интервале):" `
    -ForegroundColor Cyan
  $rows | Sort-Object 'Время' -Descending | Format-Table -AutoSize
}

if ($History -gt 0) {
  Show-History $History $Buckets
  return
}

function Get-GpuSample {
  $fields = 'utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw'
  $raw = nvidia-smi --query-gpu=$fields --format=csv,noheader,nounits 2>$null
  if (-not $raw) { return $null }

  $values = ($raw | Select-Object -First 1) -split '\s*,\s*'
  [pscustomobject]@{
    GpuPct      = [int]$values[0]
    VramUsedMb  = [int]$values[1]
    VramTotalMb = [int]$values[2]
    TempC       = [int]$values[3]
    PowerW      = [double]$values[4]
  }
}

# Что именно держит VRAM: nvidia-smi на Windows не отдаёт память по процессам
# (WDDM), поэтому источник истины по моделям — сам Ollama.
function Get-LoadedModels {
  try { $response = Invoke-RestMethod $OllamaApi -TimeoutSec 5 }
  catch { return @() }

  foreach ($model in $response.models) {
    $onGpu = if ($model.size -gt 0) {
      [math]::Round(100 * $model.size_vram / $model.size)
    } else { 0 }

    [pscustomobject]@{
      Name     = $model.name
      SizeMb   = [math]::Round($model.size / 1MB)
      VramMb   = [math]::Round($model.size_vram / 1MB)
      OnGpuPct = $onGpu
      Until    = $model.expires_at
    }
  }
}

function Format-Models($models) {
  if (-not $models) { return 'нет загруженных моделей' }
  ($models | ForEach-Object {
    '{0} {1}МБ {2}% GPU' -f $_.Name, $_.VramMb, $_.OnGpuPct
  }) -join '; '
}

if (-not (Test-Path $LogDir)) {
  New-Item -ItemType Directory -Path $LogDir | Out-Null
}
$logPath = Join-Path $LogDir ("gpu-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
'time;gpu_pct;vram_used_mb;vram_total_mb;temp_c;power_w;models' |
  Set-Content -Path $logPath -Encoding utf8

$deadline = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { $null }
Write-Host "Лог: $logPath" -ForegroundColor Cyan

while ($true) {
  $gpu = Get-GpuSample
  if (-not $gpu) {
    Write-Host 'nvidia-smi недоступен — драйвер NVIDIA не найден.' -ForegroundColor Red
    break
  }

  $models = Get-LoadedModels
  $stamp = Get-Date -Format 'HH:mm:ss'
  $modelText = Format-Models $models

  "$stamp;$($gpu.GpuPct);$($gpu.VramUsedMb);$($gpu.VramTotalMb);" +
    "$($gpu.TempC);$($gpu.PowerW);$modelText" | Add-Content -Path $logPath

  $vramPct = [math]::Round(100 * $gpu.VramUsedMb / $gpu.VramTotalMb)
  Write-Host ("[{0}] GPU {1,3}%  VRAM {2}/{3} МБ ({4}%)  {5}°C  {6} Вт  | {7}" -f
    $stamp, $gpu.GpuPct, $gpu.VramUsedMb, $gpu.VramTotalMb, $vramPct,
    $gpu.TempC, $gpu.PowerW, $modelText)

  if ($Once) { break }
  if ($deadline -and (Get-Date) -ge $deadline) { break }
  Start-Sleep -Seconds $IntervalSec
}
