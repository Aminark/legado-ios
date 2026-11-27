"""Keep Readium 3.11's CSS selector tokenizer compatible with iOS 15 WebKit."""

import sys
from pathlib import Path


directory = Path(sys.argv[1])
original = ".split(/--|__|[-]|(?<=[a-z])(?=[A-Z])/)"
compatible = '.replace(/([a-z])([A-Z])/g,"$1-$2").split(/--|__|[-]/)'
for name in ("readium-reflowable.js", "readium-fixed.js"):
    path = directory / name
    script = path.read_text(encoding="utf-8")
    if original in script:
        path.write_text(script.replace(original, compatible), encoding="utf-8")
