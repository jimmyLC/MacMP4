#!/usr/bin/env python3
"""Run with python3 Tests/regressions.py; uses disposable synthetic media only."""
import os
import json
import plistlib
import re
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENV = dict(os.environ, CLANG_MODULE_CACHE_PATH='/private/tmp/macmp4-module-cache', SWIFT_MODULECACHE_PATH='/private/tmp/macmp4-module-cache')
FFMPEG = shutil.which('ffmpeg')
FFPROBE = shutil.which('ffprobe')
assert FFMPEG, 'Install ffmpeg before running regressions'
failures = []
def check(name, fn):
    try:
        fn()
        print('PASS:', name, flush=True)
    except Exception as error:
        failures.append(name)
        print('FAIL:', name, str(error), flush=True)
def run(args):
    return subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=20, env=ENV)
def require(condition, message):
    if not condition:
        raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='macmp4-regressions-') as folder:
    tmp = Path(folder)
    cli = tmp / 'cli'
    subprocess.run(['swiftc', '-swift-version', '5', str(ROOT/'Sources/Engine.swift'), str(ROOT/'CLI/main.swift'), '-o', str(cli)], env=ENV, check=True)
    normal = tmp / 'normal.ts'
    short = tmp / 'short.ts'
    for path, duration in [(normal, '1'), (short, '0.2')]:
        result = run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x64:rate=30', '-t', duration, '-c:v', 'libx264', '-f', 'mpegts', path])
        require(result.returncode == 0, result.stderr)
    def directory_preserved():
        output = tmp/'normal.mp4'
        output.mkdir()
        sentinel = output/'sentinel'
        sentinel.write_text('KEEP')
        result = run([cli, '--no-gpu', normal])
        require(sentinel.is_file() and sentinel.read_text() == 'KEEP', 'existing output directory was deleted')
        require(result.returncode != 0, 'directory collision must report failure')
    check('preserve directory at output path', directory_preserved)
    def short_works():
        result = run([cli, '--no-gpu', short])
        require(result.returncode == 0 and (tmp/'short.mp4').is_file(), result.stdout)
    check('convert valid 0.2 second clip', short_works)
    # This calls the real FF.probe with a noisy executable to force pipe backpressure.
    source = tmp/'main.swift'
    source.write_text('import Foundation\nlet result = FF.probe(url: URL(fileURLWithPath: "/unused"), ffprobe: CommandLine.arguments[1])\nexit(result?.hasVideo == true ? 0 : 1)\n')
    probe = tmp/'probe-harness'
    subprocess.run(['swiftc', '-swift-version', '5', str(ROOT/'Sources/Engine.swift'), str(source), '-o', str(probe)], env=ENV, check=True)
    fake = tmp/'noisy-probe'
    fake.write_text('#!/bin/sh\ndd if=/dev/zero bs=1024 count=1024 1>&2 2>/dev/null\necho \'{"streams":[{"codec_type":"video","codec_name":"h264"}],"format":{"duration":"1"}}\'\n')
    fake.chmod(0o755)
    def noisy_probe():
        process = subprocess.Popen([str(probe), str(fake)], start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.communicate(timeout=4)
            require(process.returncode == 0, 'probe failed to read valid JSON')
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise AssertionError('probe blocked on stderr')
    check('probe drains error-heavy output', noisy_probe)
    def swift_regression(name, sources, arguments):
        executable = tmp/name
        compiled = run(['swiftc', '-swift-version', '5', '-parse-as-library', ROOT/'Sources/Engine.swift', *sources, '-o', executable])
        require(compiled.returncode == 0, compiled.stderr)
        result = run([executable, *arguments])
        require(result.returncode == 0, result.stdout + result.stderr)
        print(result.stdout.strip(), flush=True)
    check('transaction regression suite', lambda: swift_regression('output-tests', [ROOT/'Tests/OutputRegression.swift'], []))
    check('GUI model regression suite', lambda: swift_regression('model-tests', [ROOT/'Sources/Model.swift', ROOT/'Tests/ModelRegression.swift'], [short, FFMPEG, FFPROBE]))
    check('tool installer regression suite', lambda: swift_regression('tool-setup-tests', [ROOT/'Sources/Model.swift', ROOT/'Sources/ToolSetup.swift', ROOT/'Tests/ToolSetupRegression.swift'], []))
    def localization():
        expected = json.loads(run(['plutil', '-convert', 'json', '-o', '-', ROOT/'Resources/en.lproj/Localizable.strings']).stdout)
        keys = set()
        for source in (ROOT/'Sources').glob('*.swift'):
            keys.update(re.findall(r'L\("([^"\n]*)"\)', source.read_text()))
        require(not keys-expected.keys(), f'Missing English translations: {keys-expected.keys()}')
        for key, translation in expected.items():
            tokens = r'%(?:\.\d+)?[d@f%]'
            require(re.findall(tokens, key) == re.findall(tokens, translation), f'Format mismatch: {key}')
        app = tmp/'LocalizationTests.app/Contents'
        resources = app/'Resources'
        binary = app/'MacOS/localization-tests'
        binary.parent.mkdir(parents=True)
        resources.mkdir()
        for language in ['en', 'zh-Hant']:
            shutil.copytree(ROOT/f'Resources/{language}.lproj', resources/f'{language}.lproj')
        (resources/'Expected.json').write_text(json.dumps(expected))
        (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': binary.name, 'CFBundleIdentifier': 'local.macmp4.LocalizationRegression', 'CFBundleDevelopmentRegion': 'en'}))
        compiled = run(['swiftc', '-swift-version', '5', '-parse-as-library', ROOT/'Sources/Engine.swift', ROOT/'Tests/LocalizationRegression.swift', '-o', binary])
        require(compiled.returncode == 0, compiled.stderr)
        result = run([binary])
        require(result.returncode == 0, result.stdout + result.stderr)
        print(result.stdout.strip(), flush=True)
    check('localization resources and runtime lookup', localization)



if failures:
    raise SystemExit(f'{len(failures)} regression(s) failed')
