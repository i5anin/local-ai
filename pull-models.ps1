# Качает базовые модели и собирает из них русскоязычные варианты.
# Запускать ПОСЛЕ `docker compose up -d`.
#
# Итог: в списке остаются только `qwen2.5-ru` и `qwen2.5-coder-ru` —
# с русским системным промптом и низкой температурой (иначе 7B срывается
# на китайский). Базовые теги удаляются, чтобы их нельзя было выбрать
# в Open WebUI по ошибке. Веса общие — место не дублируется.

$Models = @(
  @{ Base = 'qwen2.5-coder:7b';     Ru = 'qwen2.5-coder-ru'
     Modelfile = '/shared/Modelfile.qwen-coder-ru'; Purpose = 'код'
     KeepBase = $false }
  @{ Base = 'qwen2.5:7b';           Ru = 'qwen2.5-ru'
     Modelfile = '/shared/Modelfile.qwen-ru';       Purpose = 'общий чат'
     KeepBase = $false }
  # Базовый тег остаётся: на него ссылается проект ai_pf-forum.
  @{ Base = 'qwen3-vl:4b-instruct'; Ru = 'qwen3-vl-ru'
     Modelfile = '/shared/Modelfile.qwen-vl-ru';    Purpose = 'изображения, чертежи'
     KeepBase = $true }
)

foreach ($model in $Models) {
  Write-Host "Качаю $($model.Base) ($($model.Purpose)) ..." -ForegroundColor Cyan
  docker exec ollama ollama pull $model.Base

  Write-Host "Собираю русский вариант $($model.Ru) ..." -ForegroundColor Cyan
  docker exec ollama ollama create $model.Ru -f $model.Modelfile

  if (-not $model.KeepBase) {
    docker exec ollama ollama rm $model.Base | Out-Null
  }
}

Write-Host "`nУстановленные модели:" -ForegroundColor Green
docker exec ollama ollama list
