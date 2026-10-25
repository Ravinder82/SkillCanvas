#!/bin/bash
set -euo pipefail
DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR" ] || [ ! -f "$DIR/SKILL.md" ]; then echo "Usage: $0 /path/to/skill-folder (must contain SKILL.md)" >&2; exit 2; fi
python3 - "$DIR/SKILL.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
match = re.match(r'^---\s*\n(.*?)\n---\s*\n', text, re.S)
if not match: raise SystemExit('Missing YAML frontmatter delimited by ---')
for key in ('name:', 'description:'):
    if key not in match.group(1): raise SystemExit(f'Missing required field: {key}')
print('Skill structure looks valid.')
PY
