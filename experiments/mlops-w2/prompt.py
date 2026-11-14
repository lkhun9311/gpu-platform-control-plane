"""W2's prompt and inference settings: the exact text every model is asked with, and how it must answer.

Design: docs/superpowers/specs/2026-11-14-w2-banking77-and-m1-gate-design.md. Standard library only.
This file is the template; its hash is recorded with every evaluation, so a changed word is a different prompt.
"""

from __future__ import annotations

import hashlib
import json

MODEL = "Qwen/Qwen2.5-1.5B-Instruct"
MODEL_REVISION = "989aa7980e4cf806f80c7fef2b1adb7bc71aa306"

# Greedy, so one prompt has one answer; 32 new tokens is several times the longest label's JSON answer.
GENERATION = {"temperature": 0.0, "top_p": 1.0, "max_new_tokens": 32, "stop": "end_of_turn"}

SYSTEM = (
    "You classify a bank customer's message into exactly one intent.\n"
    "The intents are, one per line:\n"
    "{labels}\n"
    'Answer with one JSON object and nothing else: {{"label": "<intent>"}}, where <intent> is copied exactly from the list.'
)


def messages(text: str, names: list[str]) -> list[dict[str, str]]:
    """The chat messages for one customer message, the label names listed in id order."""
    return [
        {"role": "system", "content": SYSTEM.format(labels="\n".join(names))},
        {"role": "user", "content": text},
    ]


def answer(label: str) -> str:
    """The exact answer a correct model gives, which is also the training target."""
    return json.dumps({"label": label})


def template_hash(names: list[str]) -> str:
    """sha256 over the template, the label list and the generation settings, recorded with every evaluation."""
    payload = json.dumps({"system": SYSTEM, "labels": names, "generation": GENERATION, "model": MODEL,
                          "revision": MODEL_REVISION}, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()
