"""Build on macOS, verify a device app, then package it for local re-signing."""
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import zipfile

from preflight import ROOT, PROJECT, check


def main():
    build = ROOT / 'build'
    logs = build / 'logs'
    logs.mkdir(parents=True, exist_ok=True)
    os.chdir(ROOT)
    env = os.environ.copy()

    def run(args, name):
        with (logs / name).open('w', encoding='utf-8') as log:
            process = subprocess.Popen([str(a) for a in args], env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, errors='replace')
            output = []
            for line in process.stdout:
                print(line, end='', flush=True)
                log.write(line)
                output.append(line)
            code = process.wait()
        if code:
            raise RuntimeError(f'{args[0]} failed ({code}); see build/logs/{name}')
        return ''.join(output)

    check()
    if platform.system() != 'Darwin':
        raise RuntimeError('iOS compilation requires macOS with Xcode. Run the GitHub Actions workflow.')
    bundle = env.get('BUNDLE_ID', 'com.personal.budgetai.h6klv4u0xbpkhe31v9hk0')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+', bundle):
        raise ValueError('Invalid bundle ID')
    # Use a stable Xcode 26 installation. Avoid silently falling back to Xcode 16.
    candidates = []
    for path in Path('/Applications').glob('Xcode*.app'):
        match = re.fullmatch(r'Xcode_(26(?:\.\d+)*).app', path.name)
        if match:
            candidates.append((tuple(map(int, match[1].split('.'))), path))
    if not candidates:
        raise RuntimeError('Stable Xcode 26 not found on this runner; inspect the runner image and select a supported image.')
    env['DEVELOPER_DIR'] = str(max(candidates)[1] / 'Contents/Developer')
    version = run(['xcodebuild', '-version'], 'xcode-version.txt')
    run(['xcodebuild', '-showsdks'], 'sdks.txt')
    run(['plutil', '-lint', PROJECT / 'project.pbxproj'], 'project-validation.txt')
    run(['xcodebuild', '-list', '-json', '-project', PROJECT], 'targets.json')
    archive = build / 'BudgetAI.xcarchive'
    result = build / 'Archive.xcresult'
    if archive.exists() or result.exists() or (build / 'output').exists():
        raise RuntimeError('Build output already exists. Move build/ aside before rebuilding; nothing was deleted.')
    args = ['xcodebuild', '-project', PROJECT, '-scheme', 'BudgetAI', '-configuration', 'Release',
            '-destination', 'generic/platform=iOS', '-sdk', 'iphoneos',
            '-derivedDataPath', build / 'DerivedData', '-archivePath', archive,
            '-resultBundlePath', result, 'archive', 'CODE_SIGNING_ALLOWED=NO',
            'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=',
            f'PRODUCT_BUNDLE_IDENTIFIER={bundle}', 'IPHONEOS_DEPLOYMENT_TARGET=18.0',
            'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'SKIP_INSTALL=NO']
    run(args, 'archive.log')
    app = archive / 'Products/Applications/BudgetAI.app'
    with (app / 'Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if info.get('CFBundleIdentifier') != bundle or info.get('CFBundlePackageType') != 'APPL':
        raise RuntimeError('Archive does not contain the expected application')
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise RuntimeError('Expected a physical-device build, not a simulator app')
    if info.get('MinimumOSVersion') != '18.0':
        raise RuntimeError('Unexpected minimum iOS version')
    executable = app / info['CFBundleExecutable']
    run(['xcrun', 'lipo', '-verify_arch', 'arm64', executable], 'architecture.txt')
    run(['xcrun', 'vtool', '-show-build', executable], 'macho-platform.txt')
    # A successful archive should already be unsigned. Never ship a provisioning profile.
    if (app / 'embedded.mobileprovision').exists():
        raise RuntimeError('Unexpected provisioning profile in unsigned archive')
    if not (app / 'Assets.car').is_file():
        raise RuntimeError('Compiled asset catalog is missing')
    payload = build / 'package/Payload'
    payload.mkdir(parents=True)
    shutil.copytree(app, payload / app.name, symlinks=True)
    output = build / 'output'
    output.mkdir()
    ipa = output / 'BudgetAI-unsigned.ipa'
    # ditto preserves executable permissions and symlinks on macOS.
    run(['ditto', '-c', '-k', '--keepParent', '--norsrc', payload, ipa], 'package.log')
    with zipfile.ZipFile(ipa) as package:
        if package.testzip() is not None:
            raise RuntimeError('IPA ZIP integrity check failed')
        if f'Payload/BudgetAI.app/{executable.name}' not in package.namelist():
            raise RuntimeError('IPA executable is missing')
        packed = plistlib.loads(package.read('Payload/BudgetAI.app/Info.plist'))
        if packed != info:
            raise RuntimeError('Packaged metadata mismatch')
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (output / 'SHA256SUMS.txt').write_text(f'{digest}  {ipa.name}\n', encoding='utf-8')
    metadata = {'bundle_id': bundle, 'minimum_ios': info['MinimumOSVersion'],
                'architecture': 'arm64', 'xcode': version.strip(), 'signed': False,
                'commit': env.get('GITHUB_SHA'), 'sha256': digest,
                'device_installation_verified': False,
                'next_step': 'Re-sign and install locally with Sideloadly using your free Apple account.'}
    (output / 'build-info.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    summary = env.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as file:
            file.write(f'Unsigned device IPA built and ZIP verified. Minimum iOS: 18.0.\n\n'
                       f'Bundle ID: `{bundle}`. Requires local re-signing before installation.\n\n'
                       f'SHA-256: `{digest}`\n')


if __name__ == '__main__':
    main()
