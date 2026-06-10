# Качает модели в работающий контейнер Ollama.
# Запускать ПОСЛЕ `docker compose up -d`.

Write-Host "Качаю qwen2.5-coder:7b (код) ..." -ForegroundColor Cyan
docker exec -it ollama ollama pull qwen2.5-coder:7b

Write-Host "Качаю qwen2.5:7b (общий чат) ..." -ForegroundColor Cyan
docker exec -it ollama ollama pull qwen2.5:7b

Write-Host "`nУстановленные модели:" -ForegroundColor Green
docker exec -it ollama ollama list
