#!/usr/bin/env python3
"""Wraps Russian string literals of the Swift sources into L("...") calls.
Interpolations become %@ placeholders: "Сохранено: \\(name)" -> L("Сохранено: %@", "\\(name)").
Usage: wrap_strings.py file.swift [...]   (rewrites files in place, prints the number of changes)
"""
import re, sys

CYR = re.compile(r'[А-Яа-яЁё]')

def parse_string(src, i):
    """src[i] == '"'. Returns (parts, end) where parts are ('text', s) / ('interp', code)."""
    assert src[i] == '"'
    i += 1
    parts, buf = [], []
    while i < len(src):
        c = src[i]
        if c == '\\':
            if src[i + 1] == '(':
                if buf: parts.append(('text', ''.join(buf))); buf = []
                code, i = parse_code(src, i + 2, closing=')')
                parts.append(('interp', code))
                continue
            buf.append(src[i:i + 2]); i += 2; continue
        if c == '"':
            if buf: parts.append(('text', ''.join(buf)))
            return parts, i + 1
        if c == '\n':
            raise ValueError('unterminated string')
        buf.append(c); i += 1
    raise ValueError('eof in string')

def render_string(parts):
    out = ['"']
    for kind, val in parts:
        out.append(val if kind == 'text' else '\\(' + val + ')')
    out.append('"')
    return ''.join(out)

def parse_code(src, i, closing=None):
    """Copies code until the matching `closing` paren (for interpolations), transforming literals."""
    out, depth = [], 0
    while i < len(src):
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i); j = len(src) if j < 0 else j
            out.append(src[i:j]); i = j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i) + 2
            out.append(src[i:j]); i = j; continue
        if src.startswith('#"', i):
            j = src.find('"#', i + 2) + 2
            out.append(src[i:j]); i = j; continue
        if src.startswith('"""', i):
            j = src.find('"""', i + 3) + 3
            out.append(src[i:j]); i = j; continue
        if c == '"':
            parts, j = parse_string(src, i)
            out.append(transform_literal(parts, ''.join(out)))
            i = j; continue
        if closing:
            if c == '(':
                depth += 1
            elif c == ')':
                if depth == 0:
                    return ''.join(out), i + 1
                depth -= 1
        out.append(c); i += 1
    return ''.join(out), i

changes = 0

def transform_literal(parts, before):
    global changes
    literal = render_string(parts)
    has_cyr = any(kind == 'text' and CYR.search(val) for kind, val in parts)
    if not has_cyr or re.search(r'\bL\(\s*$', before):
        return literal
    changes += 1
    interps = [val for kind, val in parts if kind == 'interp']
    if not interps:
        return 'L(' + literal + ')'
    key = ''.join(val.replace('%', '%%') if kind == 'text' else '%@' for kind, val in parts)
    args = ', '.join('"\\(' + val + ')"' for val in interps)
    return 'L("' + key + '", ' + args + ')'

SKIP_LINE = re.compile(r'russianSample\s*=|static let sample = ')

for path in sys.argv[1:]:
    src = open(path).read()
    changes = 0
    cut = len(src)
    marker = src.find('public enum HallucinationFilter')
    if marker >= 0:
        cut = marker  # Russian data (hallucination phrases) stays as is
    head, tail = src[:cut], src[cut:]
    lines = head.split('\n')
    # protect lines that must stay Russian data
    protected = {}
    for n, line in enumerate(lines):
        if SKIP_LINE.search(line):
            protected[n] = line
            lines[n] = '//__PROTECTED_%d__' % n
    head = '\n'.join(lines)
    result, _ = parse_code(head, 0)
    for n, line in protected.items():
        result = result.replace('//__PROTECTED_%d__' % n, line)
    if changes:
        if 'import SubtitsCore' not in result and '/SubtitsCore/' not in path:
            pass
        open(path, 'w').write(result + tail)
    print(f'{changes:4d} {path}')
