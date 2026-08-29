"""
title: Совет из 5 проходов
author: local-ai2
version: 1.0
requirements: requests
description: Один вопрос проходит пять последовательных ролей — разбор,
    решение, критика, правка, сводка. Каждый шаг видит результат предыдущего,
    поэтому ошибка ловится на следующем шаге, а не уходит в финальный ответ.
    Метрики каждого шага (время, токены) выводятся в чат, полные тела
    запросов — в Langfuse одним трейсом.
"""

import os
import time
import uuid
from typing import Generator, List

import requests
from pydantic import BaseModel

# Роли проходов. Ключ `model`: `main` — общая модель, `code` — кодовая.
# Порядок не произвольный: критика отделена от правки, иначе модель
# правит и оценивает в одном ответе и почти всегда признаёт своё решение
# верным.
STEPS = [
    {
        "name": "Разбор",
        "model": "main",
        "instruction": "Разбери задачу: что требуется, какие данные даны, "
                       "какие условия не названы прямо. Решение не давай.",
    },
    {
        "name": "Решение",
        "model": "code",
        "instruction": "Дай решение по разбору выше. Кратко, по делу.",
    },
    {
        "name": "Критика",
        "model": "main",
        "instruction": "Найди в решении выше ошибки, упущенные условия и "
                       "неверные допущения. Только перечень проблем, без "
                       "исправленного варианта.",
    },
    {
        "name": "Правка",
        "model": "code",
        "instruction": "Исправь решение по замечаниям выше.",
    },
    {
        "name": "Сводка",
        "model": "main",
        "instruction": "Дай итоговый ответ на исходную задачу по "
                       "исправленному решению. Ход рассуждений и упоминания "
                       "шагов не включай.",
    },
]


def spaced(number: int) -> str:
    """1240 → «1 240»: длинные числа в таблице иначе не читаются."""
    return f"{number:,}".replace(",", " ")


class Pipeline:
    class Valves(BaseModel):
        LITELLM_BASE_URL: str = "http://litellm:4000/v1"
        LITELLM_API_KEY: str = ""
        MODEL_MAIN: str = "qwen2.5-ru-traced"
        MODEL_CODE: str = "qwen2.5-coder-ru-traced"
        # Одна модель на все проходы. На карте 8 ГБ две модели 7B
        # одновременно не держатся: каждое переключение — выгрузка весов
        # и повторное чтение с диска, плюс 5–15 с к каждому шагу.
        # Выключить — получить разные модели ценой четырёх перезагрузок.
        SINGLE_MODEL: bool = True
        # Температура по шагам. Высокая на критике — намеренно: на низкой
        # модель повторяет решение вместо поиска в нём изъянов.
        TEMPERATURES: str = "0.2,0.2,0.7,0.1,0.3"
        SHOW_STEPS: bool = True
        REQUEST_TIMEOUT: int = 1800

    def __init__(self):
        self.name = "Совет из 5 проходов"
        self.valves = self.Valves(
            LITELLM_BASE_URL=os.getenv("LITELLM_BASE_URL",
                                       "http://litellm:4000/v1"),
            LITELLM_API_KEY=os.getenv("LITELLM_API_KEY", ""),
        )

    # ── Вспомогательное ────────────────────────────────────────────────
    def temperatures(self) -> List[float]:
        try:
            values = [float(part) for part in
                      self.valves.TEMPERATURES.split(",")]
        except ValueError:
            values = []
        # Недостающие значения добираются последним, лишние отбрасываются:
        # опечатка в настройке не должна ломать весь проход.
        while len(values) < len(STEPS):
            values.append(values[-1] if values else 0.3)
        return values[:len(STEPS)]

    def model_for(self, step: dict) -> str:
        if self.valves.SINGLE_MODEL or step["model"] == "main":
            return self.valves.MODEL_MAIN
        return self.valves.MODEL_CODE

    def ask(self, model: str, temperature: float, prompt: str,
            step_name: str, trace_id: str, attach: bool) -> tuple:
        # Метаданные читает LiteLLM и передаёт в Langfuse: все проходы
        # ложатся в один трейс с именами шагов, а не пятью отдельными.
        metadata = {
            "trace_id": trace_id,
            "trace_name": "council",
            "session_id": trace_id,
            "generation_name": step_name,
            "tags": ["council", step_name],
        }
        # Со второго шага — присоединение к уже созданному трейсу.
        # На первом шаге этого ключа быть не должно: с ним LiteLLM считает
        # трейс существующим и не проставляет ему имя и метки.
        if attach:
            metadata["existing_trace_id"] = trace_id
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": temperature,
            "stream": False,
            "metadata": metadata,
        }
        started = time.monotonic()
        response = requests.post(
            f"{self.valves.LITELLM_BASE_URL}/chat/completions",
            json=payload,
            headers={"Authorization": f"Bearer {self.valves.LITELLM_API_KEY}"},
            timeout=self.valves.REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        data = response.json()
        usage = data.get("usage") or {}
        return (data["choices"][0]["message"]["content"],
                usage.get("prompt_tokens", 0),
                usage.get("completion_tokens", 0),
                time.monotonic() - started)

    # ── Точка входа ────────────────────────────────────────────────────
    def pipe(self, user_message: str, model_id: str, messages: List[dict],
             body: dict):
        # Open WebUI отдельным запросом просит модель придумать название
        # чата. Гонять на это пять проходов бессмысленно.
        if body.get("title"):
            return self.name
        return self.run(user_message, body)

    def run(self, user_message: str, body: dict) -> Generator[str, None, None]:
        trace_id = str(body.get("chat_id") or uuid.uuid4())
        temperatures = self.temperatures()
        report = []
        previous_name = ""
        previous_text = ""

        for number, step in enumerate(STEPS, start=1):
            model = self.model_for(step)
            yield f"`шаг {number}/{len(STEPS)} · {step['name']} · {model}`\n\n"

            if previous_text:
                prompt = (f"{step['instruction']}\n\n"
                          f"Исходная задача:\n{user_message}\n\n"
                          f"Результат предыдущего шага ({previous_name}):\n"
                          f"{previous_text}")
            else:
                prompt = f"{step['instruction']}\n\nЗадача:\n{user_message}"

            try:
                text, prompt_tokens, answer_tokens, seconds = self.ask(
                    model, temperatures[number - 1], prompt,
                    step["name"], trace_id, attach=number > 1)
            except Exception as error:
                yield (f"\n**Шаг {number} ({step['name']}) не выполнен:** "
                       f"{error}\n")
                return

            report.append({
                "number": number, "name": step["name"], "model": model,
                "seconds": seconds, "prompt": prompt_tokens,
                "answer": answer_tokens,
            })
            head = (f"{number}. {step['name']} · {model} · "
                    f"{seconds:.1f} с · {spaced(prompt_tokens)}→"
                    f"{spaced(answer_tokens)} ток.")

            if number < len(STEPS):
                if self.valves.SHOW_STEPS:
                    yield (f"<details><summary>{head}</summary>\n\n{text}\n\n"
                           f"</details>\n\n")
                else:
                    yield f"`{head}`\n\n"
            else:
                yield f"---\n\n{text}\n\n"

            previous_name = step["name"]
            previous_text = text

        yield self.metrics(report)

    def metrics(self, report: List[dict]) -> str:
        lines = ["\n---\n",
                 "| Шаг | Модель | Время | Промпт | Ответ |",
                 "|---|---|---:|---:|---:|"]
        for row in report:
            lines.append(
                f"| {row['number']}. {row['name']} | {row['model']} | "
                f"{row['seconds']:.1f} с | {spaced(row['prompt'])} | "
                f"{spaced(row['answer'])} |")
        total_seconds = sum(row["seconds"] for row in report)
        total_prompt = sum(row["prompt"] for row in report)
        total_answer = sum(row["answer"] for row in report)
        lines.append(
            f"| **Итого** | | **{total_seconds:.1f} с** | "
            f"**{spaced(total_prompt)}** | **{spaced(total_answer)}** |")
        return "\n".join(lines) + "\n"
