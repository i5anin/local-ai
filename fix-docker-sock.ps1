<#
.SYNOPSIS
    Фикс падения Docker Desktop на старте: Secrets Engine не может
    удалить устаревший engine.sock.

.DESCRIPTION
    Симптом: диалог «An unexpected error occurred» с текстом
    «initializing Secrets Engine: listening on
    unix://C:\Users\<user>\AppData\Local\docker-secrets-engine\engine.sock:
    remove ...: The file cannot be accessed by the system».

    Причина: после аварийного завершения Docker остаётся файл unix-сокета
    (reparse point), который Windows не даёт удалить штатным путём движка.

    Скрипт:
      1. Останавливает процессы Docker Desktop и backend.
      2. Удаляет каталог docker-secrets-engine с устаревшим сокетом.
      3. Запускает Docker Desktop заново.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\fix-docker-sock.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$SockDir    = Join-Path $env:LOCALAPPDATA 'docker-secrets-engine'
$DockerExe  = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$ProcNames  = @(
    'Docker Desktop', 'com.docker.backend', 'com.docker.build',
    'com.docker.dev-envs', 'docker'
)

Write-Host '--- Остановка Docker ---' -ForegroundColor Yellow
$procs = Get-Process -Name $ProcNames -ErrorAction SilentlyContinue
if ($procs) {
    $procs | Stop-Process -Force -Confirm:$false
    Start-Sleep -Seconds 3
    Write-Host "✅ Остановлено процессов: $($procs.Count)"
} else {
    Write-Host '✅ Процессы Docker не запущены'
}

Write-Host '--- Удаление устаревшего сокета ---' -ForegroundColor Yellow
if (Test-Path $SockDir) {
    Remove-Item $SockDir -Recurse -Force -Confirm:$false
    Write-Host "✅ Удалён: $SockDir"
} else {
    Write-Host '✅ Каталог отсутствует, удалять нечего'
}

Write-Host '--- Запуск Docker Desktop ---' -ForegroundColor Yellow
if (Test-Path $DockerExe) {
    Start-Process $DockerExe
    Write-Host '✅ Docker Desktop запущен, старт занимает ~30-60 с'
} else {
    Write-Host "⚠️  Не найден $DockerExe — запустите Docker вручную" `
        -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Проверка после старта:'
Write-Host '   docker info' -ForegroundColor DarkGray
