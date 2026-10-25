"""Read-only source checks; no network and no Apple credentials required."""
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'ios-budget-ai/BudgetAI.xcodeproj'


def check():
    pbx = (PROJECT / 'project.pbxproj').read_text(encoding='utf-8')
    app = ROOT / 'ios-budget-ai/BudgetAI'
    swift = list(app.rglob('*.swift'))
    assert swift, 'No Swift source files'
    assert '105FC5792E9EAD3100EA8BCF' in pbx, 'App target missing'
    assert 'IPHONEOS_DEPLOYMENT_TARGET = 18.0;' in pbx
    assert 'GENERATE_INFOPLIST_FILE = YES;' in pbx
    assert 'PBXShellScriptBuildPhase' not in pbx, 'Review new build scripts before upload'
    ET.parse(PROJECT / 'project.xcworkspace/contents.xcworkspacedata')
    ET.parse(PROJECT / 'xcshareddata/xcschemes/BudgetAI.xcscheme')
    config = (app / 'Config.swift').read_text(encoding='utf-8')
    assert re.search(r'allValues:\s*\[String:\s*String\]\s*=\s*\[:\]', config), 'Config must remain an empty stub'
    catalogs = list(app.rglob('Contents.json'))
    for path in catalogs:
        data = json.loads(path.read_text(encoding='utf-8'))
        for item in data.get('images', []):
            if item.get('filename'):
                assert (path.parent / item['filename']).is_file(), f'Missing asset: {path}'
    # Report filenames only, never print matching secret values.
    secret = re.compile(r'AIza[0-9A-Za-z_-]{35}|gh[pousr]_[0-9A-Za-z]{30,}|github_pat_[0-9A-Za-z_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
    suspicious = []
    for path in (ROOT / 'ios-budget-ai').rglob('*'):
        if not path.is_file():
            continue
        if path.name.startswith('.env') or path.suffix.lower() in {'.p12', '.p8', '.pem', '.key', '.mobileprovision'}:
            suspicious.append(str(path.relative_to(ROOT)))
        elif path.suffix in {'.swift', '.pbxproj', '.json', '.plist', '.xcconfig'}:
            if secret.search(path.read_text(encoding='utf-8')):
                suspicious.append(str(path.relative_to(ROOT)))
    assert not suspicious, 'Review possible credentials in: ' + ', '.join(suspicious)
    print(json.dumps({'app_swift_files': len(swift), 'asset_catalog_json_files': len(catalogs),
                      'minimum_ios': '18.0', 'config_stub': 'empty',
                      'source_checks': 'passed', 'compiled': False}, indent=2))


if __name__ == '__main__':
    check()
