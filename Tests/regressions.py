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
    hevc = tmp/'hevc.mkv'
    fixture = run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x64:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '0.3', '-c:v', 'libx265', '-x265-params', 'log-level=error:pools=1:frame-threads=1', '-c:a', 'aac', hevc])
    require(fixture.returncode == 0, fixture.stderr)
    def force_h264():
        for name, options, expected in [('copy', ['--no-gpu'], 'hevc'), ('forced-cpu', ['--force-h264', '--no-gpu'], 'h264'), ('forced-auto', ['--force-h264'], 'h264')]:
            output_dir = tmp/name
            output_dir.mkdir()
            result = run([cli, '--out', output_dir, *options, hevc])
            require(result.returncode == 0, result.stdout+result.stderr)
            probe_result = run([FFPROBE, '-v', 'error', '-show_streams', '-of', 'json', output_dir/'hevc.mp4'])
            streams = json.loads(probe_result.stdout)['streams']
            require(any(s['codec_type']=='video' and s['codec_name']==expected for s in streams), name+' wrong video codec')
            require(any(s['codec_type']=='audio' and s['codec_name']=='aac' for s in streams), name+' wrong audio codec')
        conflict = run([cli, '--force-h264', '--no-reencode', hevc])
        require(conflict.returncode == 2, 'conflicting flags silently accepted')
    check('H.265 default copy and forced H.264/AAC CPU and automatic hardware fallback', force_h264)
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
    check('GUI model regression suite', lambda: swift_regression('model-tests', [ROOT/'Sources/Model.swift', ROOT/'Tests/ModelRegression.swift'], [short, FFMPEG, FFPROBE, hevc]))
    def trim_regression():
        fixture = tmp/'trim.mp4'
        made = run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'color=red:size=64x64:rate=30:duration=2',
                    '-f', 'lavfi', '-i', 'color=green:size=64x64:rate=30:duration=2',
                    '-f', 'lavfi', '-i', 'color=blue:size=64x64:rate=30:duration=2',
                    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
                    '-filter_complex', '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]',
                    '-map', '[v]', '-map', '3:a', '-c:v', 'libx264', '-g', '180', '-sc_threshold', '0', '-c:a', 'aac', fixture])
        require(made.returncode == 0, made.stderr)
        others = []
        for ext in ['mkv', 'ts']:
            target = tmp/('trim.'+ext)
            made = run([FFMPEG, '-v', 'error', '-i', fixture, '-c', 'copy', target])
            require(made.returncode == 0, made.stderr)
            others.append(target)
        swift_regression('trim-tests', [ROOT/'Sources/Model.swift', ROOT/'Tests/TrimRegression.swift'], [FFMPEG, FFPROBE, fixture, *others])
    check('GUI trim regression suite', trim_regression)
    check('tool installer regression suite', lambda: swift_regression('tool-setup-tests', [ROOT/'Sources/Model.swift', ROOT/'Sources/ToolSetup.swift', ROOT/'Tests/ToolSetupRegression.swift'], []))
    check('appearance entitlement regression suite', lambda: swift_regression('appearance-tests', [ROOT/'Sources/AppAccess.swift', ROOT/'Tests/AppearanceRegression.swift'], []))
    def license_regression():
        fixture = tmp/'license-fixture.json'
        generated = run(['node', ROOT/'payments/scripts/license-fixtures.mjs', fixture])
        require(generated.returncode == 0, generated.stderr)
        swift_regression('license-tests', [ROOT/'Sources/AppAccess.swift', ROOT/'Sources/ProLicense.swift', ROOT/'Tests/ProLicenseRegression.swift'], [fixture])
    check('signed Pro license and payment client regression suite', license_regression)
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
    def streams_of(path):
        return json.loads(run([FFPROBE, '-v', 'error', '-show_streams', '-of', 'json', path]).stdout)['streams']
    def cli_fixes():
        # all audio tracks kept, HEVC tagged hvc1
        two = tmp/'twoaudio.ts'
        made = run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x64:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440', '-f', 'lavfi', '-i', 'sine=frequency=880',
                    '-map', '0', '-map', '1', '-map', '2', '-t', '1', '-c:v', 'libx265', '-x265-params', 'log-level=error:pools=1:frame-threads=1', '-c:a', 'aac', '-f', 'mpegts', two])
        require(made.returncode == 0, made.stderr)
        out = tmp/'fix-out'/'nested'          # --out is created when missing
        result = run([cli, '--out', out, two])
        require(result.returncode == 0, result.stdout + result.stderr)
        streams = streams_of(out/'twoaudio.mp4')
        require(sum(1 for x in streams if x['codec_type'] == 'audio') == 2, 'second audio track dropped')
        require(next(x for x in streams if x['codec_type'] == 'video')['codec_tag_string'] == 'hvc1', 'HEVC not tagged hvc1')
        # same basename, different sources
        dup = tmp/'dup'
        dup.mkdir()
        shutil.copy(normal, dup/'same.ts')
        require(run([FFMPEG, '-v', 'error', '-i', normal, '-c', 'copy', dup/'same.mkv']).returncode == 0, 'mkv fixture')
        result = run([cli, '--no-gpu', dup/'same.ts', dup/'same.mkv'])
        require(result.returncode == 0, result.stdout + result.stderr)
        require((dup/'same.mp4').is_file() and (dup/'same 2.mp4').is_file(), 'same-name outputs collided')
        # --out without a value is rejected
        require(run([cli, normal, '--out']).returncode == 2, '--out without value accepted')
    check('CLI keeps all audio, hvc1 tag, creates --out, avoids same-name collisions', cli_fixes)
    def sigint_cleanup():
        big = tmp/'big.ts'
        made = subprocess.run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30', '-f', 'lavfi', '-i', 'sine=duration=300',
                               '-t', '300', '-c:v', 'mpeg2video', '-b:v', '8M', '-c:a', 'mp2', '-f', 'mpegts', str(big)], capture_output=True, text=True, timeout=120)
        require(made.returncode == 0, made.stderr)
        work = tmp/'sigint'
        work.mkdir()
        proc = subprocess.Popen([str(cli), '--no-gpu', '--out', str(work), str(big)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        import time
        deadline = time.time() + 15
        while time.time() < deadline and not list(work.glob('.macmp4-*')):
            time.sleep(0.1)
        require(list(work.glob('.macmp4-*')), 'staging folder never appeared')
        proc.send_signal(signal.SIGINT)
        proc.wait(timeout=10)
        time.sleep(0.5)
        require(not list(work.glob('.macmp4-*')), 'staging folder left after SIGINT')
        require(proc.returncode == 130, 'unexpected exit status %s' % proc.returncode)
    check('Ctrl+C removes the staging folder', sigint_cleanup)
    def exfat_no_overwrite():
        image = tmp/'exfat.dmg'
        mount = tmp/'exfat-mount'
        mount.mkdir()
        made = subprocess.run(['hdiutil', 'create', '-size', '40m', '-fs', 'ExFAT', '-volname', 'MP4TEST', str(image)], capture_output=True, text=True)
        attached = made.returncode == 0 and subprocess.run(['hdiutil', 'attach', str(image), '-mountpoint', str(mount)], capture_output=True, text=True).returncode == 0
        if not attached:
            print('SKIP: exFAT image unavailable', flush=True)
            return
        try:
            result = run([cli, '--no-gpu', '--no-overwrite', '--out', mount, normal])
            require(result.returncode == 0 and (mount/'normal.mp4').is_file(), 'exFAT commit failed: ' + result.stdout + result.stderr)
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], capture_output=True)
    check('no-overwrite commit works on exFAT', exfat_no_overwrite)



if failures:
    raise SystemExit(f'{len(failures)} regression(s) failed')
