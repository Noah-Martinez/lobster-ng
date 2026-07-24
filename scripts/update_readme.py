#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1] if len(sys.argv) > 1 else "README.md")
text = path.read_text()

intro = """# Lobster-ng

Lobster-ng is the continued and maintained fork of Lobster, a shell-based CLI for watching movies and TV shows. It keeps the existing command-line experience and installation options while continuing provider fixes, compatibility work, packaging, and security maintenance.

"""

if not text.startswith("# Lobster-ng\n"):
    text = intro + text

text = text.replace("github:justchokingaround/lobster", "github:Noah-Martinez/lobster-ng")
text = text.replace("github.com/justchokingaround/lobster/raw/main/lobster.sh", "github.com/Noah-Martinez/lobster-ng/raw/main/lobster.sh")
text = text.replace("https://raw.githubusercontent.com/justchokingaround/lobster/main/lobster.sh", "https://raw.githubusercontent.com/Noah-Martinez/lobster-ng/main/lobster.sh")
text = text.replace("curl -O \"https://raw.githubusercontent.com/justchokingaround/lobster/main/lobster.sh\"", "curl -O \"https://raw.githubusercontent.com/Noah-Martinez/lobster-ng/main/lobster.sh\"")

path.write_text(text)
