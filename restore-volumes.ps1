# Восстановление Docker-томов из .\backup (новая машина / после переустановки).
# Запускать ДО `docker compose up -d` (пока контейнеров нет).

$ErrorActionPreference = "Stop"
$backup = Join-Path $PSScriptRoot "backup"
$bmount = ($backup -replace '\\','/')

# тома должны существовать (создаём пустые, если их нет)
docker volume create local-ai_open_webui_data | Out-Null
docker volume create local-ai_ollama_models   | Out-Null

$webui = Join-Path $backup "open_webui_data.tar.gz"
if (Test-Path $webui) {
  Write-Host "Восстановление open_webui_data..." -ForegroundColor Cyan
  docker run --rm -v local-ai_open_webui_data:/data -v "${bmount}:/backup" alpine `
    sh -c "rm -rf /data/* && tar xzf /backup/open_webui_data.tar.gz -C /data"
} else { Write-Host "open_webui_data.tar.gz не найден — пропуск" -ForegroundColor Yellow }

$models = Join-Path $backup "ollama_models.tar.gz"
if (Test-Path $models) {
  Write-Host "Восстановление ollama_models..." -ForegroundColor Cyan
  docker run --rm -v local-ai_ollama_models:/data -v "${bmount}:/backup" alpine `
    sh -c "rm -rf /data/* && tar xzf /backup/ollama_models.tar.gz -C /data"
} else { Write-Host "ollama_models.tar.gz не найден — модели качай через .\pull-models.ps1" -ForegroundColor Yellow }

Write-Host "`nГотово. Теперь: docker compose up -d" -ForegroundColor Green
