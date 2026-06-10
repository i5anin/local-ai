# 🦊 local-ai — локальная ИИ (Ollama + Open WebUI)

Изолированный стек локального ИИ в Docker: движок **Ollama** + веб-интерфейс
**Open WebUI** (чат, RAG по документам, веб-поиск). Работает на видеокарте,
данные не покидают машину.

Проверено на: Windows 11, Docker Desktop 4.56 (WSL2), **RTX 3070 Ti (8 ГБ)**.

---

## Требования

| Что | Зачем |
|---|---|
| **Docker Desktop** (бэкенд WSL2) | запуск контейнеров |
| **NVIDIA GPU + свежий драйвер** | инференс на видеокарте (иначе CPU, медленно) |
| **WSL2 + Virtual Machine Platform** | требует Docker; см. «Грабли запуска» |
| ~15 ГБ свободного диска | образы (~5 ГБ) + модели (~10 ГБ) |

---

## Быстрый старт

```powershell
cd E:\development\local-ai
docker compose up -d        # поднять контейнеры (первый раз тянет образы)
.\pull-models.ps1           # скачать модели (~9 ГБ)
```

Открыть:

- **Интерфейс:** http://localhost:3000 — при первом входе зарегистрируй
  локальный аккаунт (он станет админом; данные в локальной БД).
- **API Ollama:** http://localhost:11434 (для IDE-плагинов и скриптов).

После закачки: в интерфейсе сверху «Выберите модель» → нужная модель → чат.
Первый ответ грузит модель в VRAM (~10–20 c), дальше быстро.

---

## Модели (под 8 ГБ VRAM)

| Модель | Назначение | Размер |
|---|---|---|
| `qwen2.5-coder:7b` | написание кода | ~4.7 ГБ |
| `qwen2.5:7b` | общий чат | ~4.7 ГБ |

Другую модель: `docker exec -it ollama ollama pull <модель>`.
14B-модели влезают, но впритык и медленно — повод для апгрейда VRAM
(цель 16 ГБ+, идеал — б/у RTX 3090 на 24 ГБ).

---

## Архитектура и изоляция

Контейнеры **не видят твою ОС**. Доступно только:

| Ресурс | Доступ |
|---|---|
| Папка `./shared` | ✅ читать/писать (единственное окно в файловую систему) |
| Интернет (исходящий) | ✅ есть (скачивание моделей, веб-поиск) |
| Видеокарта | ✅ проброшена в контейнер `ollama` |
| Остальная ФС (C:, E:\ …) | ❌ недоступна |
| Доступ к UI/API из локальной сети | ❌ порты только на `127.0.0.1` |

Модели и данные UI — в именованных Docker-томах (`ollama_models`,
`open_webui_data`), не в твоих папках.

---

## Команды

```powershell
docker compose ps                 # статус контейнеров
docker compose logs -f ollama     # логи движка (видно, нашёл ли GPU)
docker compose down               # остановить (данные в томах сохранятся)
docker compose pull               # обновить образы

docker exec -it ollama ollama list             # список моделей
docker exec -it ollama ollama ps               # что загружено в VRAM (GPU/CPU)
docker exec -it ollama ollama rm <модель>      # удалить модель
```

Проверить, что инференс идёт на GPU: `ollama ps` → колонка `PROCESSOR`
должна показывать `100% GPU`.

---

## Веб-поиск и знания из документов

- **Веб-поиск** включён (DuckDuckGo, без ключа). В чате включи Web Search 🌐.
  Если не активен — Settings → Web Search.
- **RAG по своим файлам:** положи документы в `./shared` или загрузи в чате
  через `#` — модель будет отвечать с опорой на них.

---

## ⚠️ Грабли запуска (Windows + Docker Desktop)

Если Docker не стартует или модели не качаются — почти всегда одно из трёх:

### 1. Docker Desktop «failed to start», WSL2 не поднимается
Симптом: `HypervisorPresent: False` при включённой в BIOS виртуализации
(`VirtualizationFirmwareEnabled: True`); ошибка `HCS_E_HYPERV_NOT_INSTALLED`.
Гипервизор не запускается при загрузке. Фикс (PowerShell от админа):

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart
bcdedit /set hypervisorlaunchtype auto
```
**Затем перезагрузить ПК** (без ребута изменение не вступит в силу).

### 2. Краш «initializing Inference manager … dockerInference»
Падение Docker Model Runner на залипшем сокете. Нам он не нужен. Фикс —
в `%APPDATA%\Docker\settings-store.json`:

```json
"EnableDockerAI": false,
"EnableInference": false
```
Если сокет не удаляется (даже `fsutil`) — переименовать/удалить папку
`%LOCALAPPDATA%\Docker\run` (и `docker-secrets-engine`), Docker создаст заново.

### 3. `ollama pull` падает с EOF (registry.ollama.ai)
Причина: системный прокси/VPN (напр. `127.0.0.1:2080`) ломает TLS, а Docker
гонит через него трафик контейнеров. Прямой доступ к реестру при этом работает.
Фикс — в `settings-store.json` перевести прокси Docker в прямой режим
(системный прокси не трогаем):

```json
"ProxyHttpMode": "manual",
"OverrideProxyHttp": "",
"OverrideProxyHttps": "",
"OverrideProxyExclude": ""
```
Перезапустить Docker после правок настроек.

---

## Что дальше

1. **Интеграция в IDE** — подключить Ollama (`http://localhost:11434`) к
   редактору: VS Code (Continue/Cline) или JetBrains (плагин ProxyAI).
2. **«Цифровой двойник»** — дообучение на своих переписках (QLoRA) отдельным
   контейнером (WeClone / LLaMA-Factory). Это отдельный этап, не входит в
   этот стек (он для инференса и знаний).
