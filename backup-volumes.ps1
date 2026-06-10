# Бэкап Docker-томов в .\backup
#   open_webui_data — чаты/аккаунты/настройки (КРИТИЧНО, всегда)
#   ollama_models   — модели (крупно; можно пропустить и перекачать)
# Запускать при поднятом Docker (стек можно не останавливать).

$ErrorActionPreference = "Stop"
$backup = Join-Path $PSScriptRoot "backup"
New-Item -ItemType Directory -Force $backup | Out-Null
$bmount = ($backup -replace '\\','/')   # docker -v любит прямые слэши

Write-Host "[1/2] Бэкап open_webui_data (чаты, аккаунты, настройки)..." -ForegroundColor Cyan
docker run --rm -v local-ai_open_webui_data:/data -v "${bmount}:/backup" alpine `
  tar czf /backup/open_webui_data.tar.gz -C /data .

Write-Host "[2/2] Бэкап ollama_models (модели; крупный)..." -ForegroundColor Cyan
docker run --rm -v local-ai_ollama_models:/data -v "${bmount}:/backup" alpine `
  tar czf /backup/ollama_models.tar.gz -C /data .

Write-Host "`nГотово. Файлы в .\backup :" -ForegroundColor Green
Get-ChildItem $backup -Filter *.tar.gz |
  Select-Object Name, @{n='Размер,ГБ';e={[math]::Round($_.Length/1GB,2)}}
