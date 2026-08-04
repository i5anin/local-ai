# Быстрый CLI к локальной модели через Ollama.
# Примеры:
#   .\ai.ps1 "как развернуть nginx в docker"
#   .\ai.ps1 -Model qwen2.5:7b "придумай короткий тост"
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Model = "qwen2.5-coder-ru",
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Prompt
)
if (-not $Prompt) {
  Write-Host 'Использование: .\ai.ps1 "ваш вопрос"   (опц. -Model qwen2.5:7b)' -ForegroundColor Yellow
  exit 1
}
docker exec -i ollama ollama run $Model ($Prompt -join ' ')
