"""
Маршрутизатор к Ollama: если в запросе есть изображение, а выбранная модель
его не принимает — подменяет модель на зрительную.

Зачем: Open WebUI хранит выбранную модель в браузере, и серверные настройки
(DEFAULT_MODELS, настройки пользователя, запись чата в базе) её не перебивают.
Пользователь прикладывает чертёж к текстовой модели и получает отказ 400
«model does not support multimodal requests». Здесь запрос правится по пути,
поэтому состояние браузера уже ничего не решает.

Прозрачен для всего остального: любой другой путь и метод идут вверх без правок.
Переменные: OLLAMA_TARGET (куда), VISION_MODEL (чем подменять), LISTEN_PORT.
"""

import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TARGET = os.getenv("OLLAMA_TARGET", "http://ollama:11434").rstrip("/")
VISION_MODEL = os.getenv("VISION_MODEL", "qwen3-vl-ru")
PORT = int(os.getenv("LISTEN_PORT", "11434"))
ROUTED_PATHS = ("/api/chat", "/api/generate", "/v1/chat/completions")

# Заголовки, которые нельзя пересылать как есть: относятся к самому соединению.
HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer",
              "upgrade", "proxy-authorization", "proxy-authenticate"}

_capabilities: dict[str, set] = {}


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def capabilities(model: str) -> set:
    """Возможности модели по данным Ollama; ответ кэшируется на время жизни."""
    if model in _capabilities:
        return _capabilities[model]
    try:
        request = urllib.request.Request(
            f"{TARGET}/api/show",
            data=json.dumps({"model": model}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            found = set(json.load(response).get("capabilities") or [])
    except Exception as error:
        log(f"[router] не удалось узнать возможности {model}: {error}")
        return set()
    _capabilities[model] = found
    return found


def has_image(payload: dict) -> bool:
    if payload.get("images"):                       # /api/generate
        return True
    for message in payload.get("messages") or []:
        if message.get("images"):                   # нативный формат Ollama
            return True
        content = message.get("content")
        if isinstance(content, list):               # формат OpenAI
            if any(part.get("type") == "image_url" for part in content
                   if isinstance(part, dict)):
                return True
    return False


def reroute(body: bytes) -> bytes:
    """Возвращает тело запроса, при необходимости с подменённой моделью."""
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return body
    if not isinstance(payload, dict):
        return body

    model = payload.get("model")
    if not model or not has_image(payload):
        return body
    if "vision" in capabilities(model):
        return body

    payload["model"] = VISION_MODEL
    log(f"[router] изображение в запросе к {model} → подменил на {VISION_MODEL}")
    return json.dumps(payload, ensure_ascii=False).encode()


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.0 с закрытием соединения: ответ отдаётся потоком, и заголовок
    # Content-Length для него неизвестен. Так не нужно переупаковывать чанки.
    protocol_version = "HTTP/1.0"
    server_version = "vision-router"

    def log_message(self, fmt, *args):              # тише штатного лога
        pass

    def proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        if body and self.path in ROUTED_PATHS:
            body = reroute(body)

        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP and k.lower() != "content-length"}
        request = urllib.request.Request(
            TARGET + self.path, data=body, headers=headers, method=self.command)

        try:
            upstream = urllib.request.urlopen(request, timeout=1800)
        except urllib.error.HTTPError as error:      # ошибку движка отдаём как есть
            upstream = error
        except Exception as error:
            log(f"[router] {self.command} {self.path}: {error}")
            self.send_error(502, "upstream unavailable")
            return

        with upstream:
            self.send_response(upstream.status)
            for key, value in upstream.headers.items():
                if key.lower() not in HOP_BY_HOP and key.lower() != "content-length":
                    self.send_header(key, value)
            self.end_headers()
            while True:
                chunk = upstream.read(8192)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = proxy


if __name__ == "__main__":
    log(f"[router] {PORT} → {TARGET}, зрительная модель {VISION_MODEL}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
