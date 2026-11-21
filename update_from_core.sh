#!/usr/bin/env bash
#
# Update the custom ZHA BLZ component from a local HA core checkout.
#
# Usage:
#   ./update_from_core.sh /path/to/ha-core [tag-or-ref]
#
# Examples:
#   ./update_from_core.sh /path/to/ha-core              # uses latest stable tag
#   ./update_from_core.sh /path/to/ha-core 2026.2.1     # uses specific tag
#
# IMPORTANT: Always use a stable release tag, NOT the dev branch.
# The dev branch targets a newer Python version and may contain
# syntax incompatible with the Python version in HA stable Docker.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZHA_DIR="$SCRIPT_DIR/custom_components/zha"
BLZ_RELEASE_DATE="${BLZ_RELEASE_DATE:-$(date -u +%Y%m%d)}"
BLZ_RELEASE_REVISION="${BLZ_RELEASE_REVISION:-1}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/ha-core [tag-or-ref]"
    echo ""
    echo "If tag-or-ref is omitted, the latest stable release tag is used."
    exit 1
fi

CORE_DIR="$1"
CORE_ZHA="$CORE_DIR/homeassistant/components/zha"

if [ ! -d "$CORE_ZHA" ]; then
    echo "Error: $CORE_ZHA not found"
    exit 1
fi

# Determine which ref to use
if [ $# -ge 2 ]; then
    REF="$2"
else
    # Find the latest stable release tag (exclude beta/dev)
    REF=$(cd "$CORE_DIR" && git tag -l "20[0-9][0-9].[0-9]*.[0-9]" --sort=-v:refname | head -1)
    if [ -z "$REF" ]; then
        echo "Error: No stable release tags found. Please specify a tag."
        exit 1
    fi
fi

echo "Using ref: $REF"

# Checkout the target ref
ORIGINAL_REF=$(cd "$CORE_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
(cd "$CORE_DIR" && git checkout "$REF" --quiet 2>&1)

CORE_COMMIT=$(cd "$CORE_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
HA_VERSION=$(cd "$CORE_DIR" && python3 -c "
import re
with open('homeassistant/const.py') as f:
    text = f.read()
major = re.search(r'MAJOR_VERSION.*?=.*?(\d+)', text).group(1)
minor = re.search(r'MINOR_VERSION.*?=.*?(\d+)', text).group(1)
patch = re.search(r'PATCH_VERSION.*?=.*?\"(\d+)\"', text)
patch = patch.group(1) if patch else '0'
print(f'{major}.{minor}.{patch}')
" 2>/dev/null || echo "0.0.0")
BLZ_VERSION="${HA_VERSION}-blz.${BLZ_RELEASE_DATE}.${BLZ_RELEASE_REVISION}"

echo "Updating from HA core $REF (commit $CORE_COMMIT, version $HA_VERSION)"
echo ""

# Step 1: Copy all files from core ZHA
echo "Step 1: Copying ZHA files from core..."
find "$ZHA_DIR" -mindepth 1 -not -path '*/.git/*' -not -name '.git' -delete 2>/dev/null || true
cp -r "$CORE_ZHA"/* "$ZHA_DIR/"
echo "  Done."

# Step 2: Patch manifest.json (string-based to preserve upstream formatting)
echo "Step 2: Patching manifest.json..."
python3 -c "
import re, sys
with open(sys.argv[1]) as f: content = f.read()
# 1. Name
content = content.replace('\"Zigbee Home Automation\"', '\"Zigbee Home Automation BLZ\"', 1)
# 2. Add zigpy_blz logger (after last logger entry)
if 'zigpy_blz' not in content:
    content = content.replace(
        '\"universal_silabs_flasher\",\n    \"serialx\"',
        '\"universal_silabs_flasher\",\n    \"serialx\",\n    \"zigpy_blz\"',
    )
# 3. Replace requirements line
content = re.sub(
    r'\"requirements\": \[.*?\]',
    '\"requirements\": [\n    \"zha @ git+https://github.com/bouffalolab/zha.git@feat/blz-2.4.3\",\n    \"zigpy-blz>=0.1.0\"\n  ]',
    content,
    flags=re.DOTALL,
)
# 4. Add version before usb (after requirements closing bracket)
if '\"version\"' not in content:
    content = content.replace(
        '  ],\n  \"usb\"',
        '  ],\n  \"version\": \"' + sys.argv[2] + '\",\n  \"usb\"',
    )
else:
    content = re.sub(
        r'\"version\":\s*\"[^\"]+\"',
        '\"version\": \"' + sys.argv[2] + '\"',
        content,
    )
# 5. Add/update homeassistant minimum version (e.g. '2026.3.0' from '2026.3.4')
ha_minor = '.'.join(sys.argv[3].split('.')[:2]) + '.0'
if '\"homeassistant\"' not in content:
    content = content.replace(
        '\"config_flow\": true',
        '\"config_flow\": true,\n  \"homeassistant\": \"' + ha_minor + '\"',
    )
else:
    content = re.sub(
        r'\"homeassistant\":\s*\"[^\"]+\"',
        '\"homeassistant\": \"' + ha_minor + '\"',
        content,
    )
with open(sys.argv[1], 'w') as f: f.write(content)
" "$ZHA_DIR/manifest.json" "$BLZ_VERSION" "$HA_VERSION"
echo "  Done."

# Step 3: Patch radio_manager.py - add RadioType.blz to RECOMMENDED_RADIOS
echo "Step 3: Patching radio_manager.py..."
python3 -c "
import re, sys
with open(sys.argv[1]) as f: content = f.read()
if 'RadioType.blz' not in content:
    content = re.sub(
        r'(RECOMMENDED_RADIOS\s*=\s*\([^)]*RadioType\.deconz),?\s*\)',
        r'\1,\n    RadioType.blz,\n)',
        content,
    )
with open(sys.argv[1], 'w') as f: f.write(content)
" "$ZHA_DIR/radio_manager.py"
echo "  Done."

# Restore original branch
(cd "$CORE_DIR" && git checkout "$ORIGINAL_REF" --quiet 2>&1)

echo ""
echo "Update complete! Based on HA core $REF ($CORE_COMMIT, version $HA_VERSION)."
echo "Version set to: ${BLZ_VERSION}"
echo ""
echo "Files patched:"
echo "  - custom_components/zha/manifest.json  (name, loggers, requirements, version)"
echo "  - custom_components/zha/radio_manager.py  (RadioType.blz in RECOMMENDED_RADIOS)"
echo ""
echo "Next steps:"
echo "  1. Verify bouffalolab/zha feat/blz branch is compatible with ZHA $(grep -oP 'zha==\K[^"]+' "$CORE_ZHA/manifest.json" 2>/dev/null || echo '(check version)')"
echo "  2. git add -A && git commit -m 'Update to HA core $REF ($CORE_COMMIT)'"
echo "  3. git push"
