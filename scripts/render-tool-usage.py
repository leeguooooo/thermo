"""Render a supplied usage report with the actual native panel and glass modifier.

Requires Debug libraries. This is offscreen rendering, not installed-app acceptance.
Usage: python3 scripts/render-tool-usage.py report.json output.png [height] [mcp|skill]
"""
from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) < 3:
    raise SystemExit('Usage: render-tool-usage.py report.json output.png [height] [mcp|skill]')
if not Path(sys.argv[1]).is_file():
    raise SystemExit('Input usage report must be an existing file: ' + sys.argv[1])

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/ThermoApp/Components.swift').read_text()
start = source.index('struct GlassPanel:')
end = source.index('/// A rounded tile', start)
with tempfile.TemporaryDirectory(prefix='thermo-render-usage-') as temporary:
    temporary = Path(temporary)
    glass = temporary / 'Glass.swift'
    glass.write_text('import SwiftUI\n' + source[start:end])
    binary = temporary / 'render'
    subprocess.run(['swiftc', '-parse-as-library', '-I', str(root / '.build/debug'), '-L', str(root / '.build/debug'),
                    '-lAgentDoctor', '-lAgentCore', '-lThermoL10n', '-lz', str(root / 'Sources/ThermoApp/ToolUsagePanel.swift'),
                    str(root / 'Sources/ThermoApp/OuterToolUsageBreakdown.swift'),
                    str(glass), str(root / 'scripts/render-tool-usage.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(Path(sys.argv[1]).resolve()), str(Path(sys.argv[2]).resolve()),
                    sys.argv[3] if len(sys.argv) > 3 else '620', sys.argv[4] if len(sys.argv) > 4 else 'mcp'], check=True)
