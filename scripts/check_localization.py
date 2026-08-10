#!/usr/bin/env python3
"""Controlla che le traduzioni siano complete e coerenti.

Verifica tre cose:
  1. ogni chiave usata con L("...") esiste in entrambe le lingue;
  2. nessuna chiave e' definita ma mai usata;
  3. il numero di segnaposto %@ coincide fra italiano e inglese.

Le chiavi costruite a runtime (per esempio L("phase.\\(rawValue)")) vanno
elencate in DYNAMIC_PREFIXES, altrimenti risulterebbero inutilizzate.

Uso:
    python3 scripts/check_localization.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "SSDCopier")
TABLE = os.path.join(SOURCES, "Core", "Localization.swift")

# Chiavi composte a runtime da un rawValue: qui elenchiamo i prefissi ammessi.
DYNAMIC_PREFIXES = (
    "phase.",
    "verify.",
    "outcome.",
    "issue.",
)

KEY_CALL = re.compile(r'\bL\(\s*"([^"\\]+)"')
DYNAMIC_CALL = re.compile(r'\bL\(\s*"([^"]*?)\\\(')
ENTRY = re.compile(r'^\s*"([^"]+)"\s*:\s*"(.*)",\s*$')


def collect_used_keys() -> tuple[set[str], set[str]]:
    """Chiavi letterali e prefissi dinamici trovati nei sorgenti."""
    literal: set[str] = set()
    dynamic: set[str] = set()

    for directory, _, filenames in os.walk(SOURCES):
        for filename in sorted(filenames):
            if not filename.endswith(".swift"):
                continue
            path = os.path.join(directory, filename)
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
            # La tabella stessa non conta come uso.
            if os.path.abspath(path) == os.path.abspath(TABLE):
                source = source.split("// MARK: - Tables")[0]
            literal.update(KEY_CALL.findall(source))
            dynamic.update(DYNAMIC_CALL.findall(source))

    return literal, dynamic


def collect_tables() -> dict[str, dict[str, str]]:
    with open(TABLE, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    tables: dict[str, dict[str, str]] = {"italian": {}, "english": {}}
    current: str | None = None
    for line in lines:
        if "static let italian" in line:
            current = "italian"
            continue
        if "static let english" in line:
            current = "english"
            continue
        if current is None:
            continue
        match = ENTRY.match(line)
        if match:
            tables[current][match.group(1)] = match.group(2)
    return tables


def main() -> int:
    literal, dynamic = collect_used_keys()
    tables = collect_tables()
    italian, english = tables["italian"], tables["english"]
    problems: list[str] = []

    if not italian or not english:
        problems.append("Tabelle non lette: controlla il formato di Localization.swift.")

    for key in sorted(literal):
        if key not in italian:
            problems.append(f"chiave assente in italiano: {key}")
        if key not in english:
            problems.append(f"chiave assente in inglese:  {key}")

    # Chiavi definite ma mai usate, escluse quelle costruite a runtime.
    defined = set(italian) | set(english)
    for key in sorted(defined):
        if key in literal:
            continue
        if any(key.startswith(prefix) for prefix in DYNAMIC_PREFIXES):
            continue
        problems.append(f"chiave definita ma mai usata: {key}")

    for key in sorted(set(italian) & set(english)):
        it_slots = italian[key].count("%@")
        en_slots = english[key].count("%@")
        if it_slots != en_slots:
            problems.append(
                f"segnaposto diversi per {key}: italiano {it_slots}, inglese {en_slots}"
            )

    only_italian = sorted(set(italian) - set(english))
    only_english = sorted(set(english) - set(italian))
    for key in only_italian:
        problems.append(f"tradotta solo in italiano: {key}")
    for key in only_english:
        problems.append(f"tradotta solo in inglese:  {key}")

    print(f"Chiavi definite: {len(defined)}   usate letteralmente: {len(literal)}")
    if dynamic:
        print(f"Prefissi dinamici trovati: {', '.join(sorted(dynamic))}")

    if problems:
        print(f"\n{len(problems)} problemi:")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print("Localizzazione completa e coerente.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
