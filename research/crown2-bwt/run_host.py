#!/usr/bin/env python3
"""CROWN-2 H2.1: validate saved cloud probes, then pair timings on ace-core.

Import is inert. Only main or the private external-flock child starts work.
Every output lives in the explicitly supplied fresh work directory. No build,
candidate Silesia call, source mutation, merge or unrelated process action occurs.
"""
import argparse
import ctypes
import datetime as dt
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import signal
import statistics
import subprocess
import sys
import tarfile
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OVH_LOCK = '/run/lock/ovh-bench.lock'
CAL_FIRST = '5a3d21d6b9765dc8cf7f00090e135f71a6324b8d'
CLOUD_SOURCE = 'abd6bee1b1feef59ec2d27f829bcb725eef8c74a'
TB = Path('/home/ubuntu/hw-apex-bench-hw-region-2/.work/tb-lvl-0/bin/turbobench')
TB_SHA = '351ea9edf86f3cdaf222bcc54146260e8eea42efaee00ae81a589f0838f4204b'
SILESIA = Path('/home/ubuntu/hw-apex-bench-hw-region-2/.work/tb-lvl-0/input/silesia.ref.tar')
SILESIA_SHA = 'a667bac80089b3d04d5496772149e632f0758974b0579d743cd8d6e5e0d63eb2'
SILESIA_N = 211947520
KNOWN_BYTES = 50266774
BYTE_BUDGET = 64 * 1024 * 1024
PIECES = ('d2_text_en', 'd2_text_src', 'd2_x86', 'd2_table_sdf',
          'd2_table_db', 'd2_image', 'd2_xml')
KS = (1, 4, 8, 16, 32)
WAIT_SECONDS = 300
HEADER = 'dataset\tsize\tcsize\tdtime\tctime\tcodec\tlevel\tparam\tcmem\tdmem\tcstack\tdstack\ttime\terr'


class Blocked(RuntimeError):
    pass


def need(condition, message):
    if not condition:
        raise ValueError(message)


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def save(path, value, replace=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
    if replace:
        pending = path.with_name(path.name + '.writing')
        with pending.open('xb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        pending.replace(path)
    else:
        with path.open('xb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())


def load(path):
    return json.loads(Path(path).read_bytes())


def emit(work, event, **fields):
    row = dict(utc=utc(), event=event, **fields)
    with (Path(work) / 'events.jsonl').open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(row, sort_keys=True) + '\n')
        stream.flush(); os.fsync(stream.fileno())
    print(json.dumps(row, sort_keys=True), flush=True)


def parent_death(parent=None):
    parent = os.getppid() if parent is None else parent
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'PR_SET_PDEATHSIG')
    if os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGKILL)


def process_table():
    rows, errors = {}, []
    for directory in Path('/proc').iterdir():
        if not directory.name.isdigit():
            continue
        try:
            raw = (directory / 'stat').read_text()
            left, right = raw.index('('), raw.rindex(')')
            fields = raw[right + 2:].split()
            rows[int(directory.name)] = dict(
                ppid=int(fields[1]), comm=raw[left + 1:right],
                ticks=int(fields[11]) + int(fields[12]), birth=int(fields[19]))
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (OSError, ValueError, IndexError) as error:
            if directory.exists():
                errors.append(dict(pid=int(directory.name), error=repr(error)))
    return rows, errors


def own_tree(rows):
    excluded, current = set(), os.getpid()
    while current in rows and current not in excluded:
        excluded.add(current); current = rows[current]['ppid']
    excluded.add(current)
    descendants = {os.getpid()}
    while True:
        extra = {pid for pid, row in rows.items() if row['ppid'] in descendants}
        if extra <= descendants:
            break
        descendants |= extra
    return excluded | descendants


def foreign_cpu():
    begin_ns = time.monotonic_ns()
    first, errors_a = process_table()
    time.sleep(1)
    second, errors_b = process_table()
    interval = time.monotonic_ns() - begin_ns
    hz = os.sysconf('SC_CLK_TCK')
    excluded = own_tree(first) | own_tree(second)
    exceeded = []
    for pid, row in second.items():
        if pid in excluded:
            continue
        old = first.get(pid)
        same = old is not None and old['birth'] == row['birth']
        ticks = row['ticks'] - (old['ticks'] if same else 0)
        need(ticks >= 0 and interval >= 1000000000, 'invalid process CPU delta')
        if 10 * ticks * 1000000000 > hz * interval:
            exceeded.append(dict(pid=pid, comm=row['comm'], ticks=ticks,
                                 percent_one_cpu=str(Decimal(100) * ticks * 1000000000 / hz / interval)))
    return dict(interval_ns=interval, hz=hz, excluded=sorted(excluded),
                exceeded=exceeded, errors=errors_a + errors_b)


def ps_top():
    result = subprocess.run(['ps', '-eo', 'pid,user,pcpu,comm', '--sort=-pcpu'],
                            capture_output=True, text=True, check=True)
    return '\n'.join(result.stdout.splitlines()[:8]) + '\n'


def boundary():
    loadavg = Path('/proc/loadavg').read_text().strip()
    load1 = Decimal(loadavg.split()[0])
    need(load1.is_finite() and load1 >= 0, 'invalid load1')
    cpu = next(line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines()
               if line.startswith('model name'))
    governor = Path('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor')
    disk = os.statvfs(ROOT)
    return dict(utc=utc(), date_u=subprocess.check_output(['date', '-u'], text=True).strip(),
                loadavg=loadavg, load1=str(load1),
                nproc=int(subprocess.check_output(['nproc'], text=True)),
                logical_cpus=os.cpu_count(), cpu=cpu, kernel=platform.release(),
                hostname=platform.node(), governor=governor.read_text().strip() if governor.exists() else 'unavailable',
                pinned_core=0, timed_threads=1, controller_core=15,
                controller_nice=os.getpriority(os.PRIO_PROCESS, 0),
                disk_available_bytes=disk.f_bavail * disk.f_frsize,
                meminfo=Path('/proc/meminfo').read_text(),
                proc_stat=Path('/proc/stat').read_text(), ps_top8=ps_top())


def other_cores(start, end):
    def parse(raw):
        return {p[0]: list(map(int, p[1:9])) for p in map(str.split, raw.splitlines())
                if p and re.fullmatch('cpu[0-9]+', p[0])}
    before, after = parse(start['proc_stat']), parse(end['proc_stat'])
    need(before.keys() == after.keys(), 'CPU set changed')
    result = {}
    for cpu in before:
        delta = [b - a for a, b in zip(before[cpu], after[cpu])]
        # Linux iowait can regress; retain the raw vector rather than turn
        # observational accounting into a timing-dependent admission rule.
        total = sum(delta)
        result[cpu] = dict(delta_jiffies=delta, observational_only=True,
                           busy_percent=str(Decimal(100) * (total - delta[3] - delta[4]) / total)
                           if total > 0 and min(delta) >= 0 else None)
    return dict(pinned_core=0, other_cpus={k: v for k, v in result.items() if k != 'cpu0'})


def admission():
    cpu = foreign_cpu()
    edge = boundary()
    return dict(pass_admission=not cpu['errors'] and not cpu['exceeded'] and Decimal(edge['load1']) <= 1,
                cpu=cpu, boundary=edge)


def safe_extract(archive, destination):
    destination.mkdir(exist_ok=False)
    total, names = 0, set()
    with tarfile.open(archive, 'r:gz') as tar:
        for member in tar:
            relative = PurePosixPath(member.name)
            need(not relative.is_absolute() and relative.parts and
                 all(p not in ('..', '') for p in relative.parts), 'unsafe archive path')
            need(relative.parts[0] in ('evidence', 'prepared', 'bin'), 'unexpected artifact root')
            if relative.parts[0] == 'bin' and member.isfile():
                need(len(relative.parts) == 2 and relative.parts[1] in
                     ('crown2_probe', 'libcrown2_baseline.so', 'compile_commands.json'),
                     'unexpected sibling binary/library in artifact')
            need(member.name not in names and (member.isfile() or member.isdir()),
                 'duplicate/link/device artifact entry')
            names.add(member.name)
            target = destination.joinpath(*relative.parts)
            need(target.resolve().is_relative_to(destination.resolve()), 'artifact escaped destination')
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            total += member.size
            need(0 <= member.size <= 512 * 1024 * 1024 and total <= 2 * 1024 * 1024 * 1024,
                 'artifact extraction size budget exceeded')
            target.parent.mkdir(parents=True, exist_ok=True)
            source = tar.extractfile(member)
            need(source is not None, 'artifact file unreadable')
            remaining = member.size
            with target.open('xb') as out:
                while remaining:
                    block = source.read(min(4 * 1024 * 1024, remaining))
                    need(bool(block), 'short artifact entry')
                    out.write(block); remaining -= len(block)
            target.chmod(0o755 if relative.parts[0] == 'bin' and target.name == 'crown2_probe' else 0o644)


def validated_artifacts(archive, work, cloud_sha):
    lock = load(HERE / 'LOCK.json')
    inputs = lock['selection_set']['inputs']
    need(set(inputs) == set(PIECES) and sum(v['bytes'] for v in inputs.values()) == 41943040,
         'wrong DEV-2 lock')
    extracted = work / 'artifacts'
    safe_extract(archive, extracted)
    result = load(extracted / 'evidence/cloud-result.json')
    need(result['status'] == 'PASS' and result['source_sha'] == cloud_sha,
         'cloud method did not PASS on the frozen source')
    need(result['inputs']['source_sha'] == cloud_sha and result['inputs']['inputs'] == inputs,
         'cloud input manifest differs from DEV-2 LOCK')
    binaries = result['binaries']
    need(set(binaries) == {'crown2_probe', 'libcrown2_baseline.so'}, 'wrong binary set')
    for name, rec in binaries.items():
        target = extracted / 'bin' / name
        need(target.is_file() and target.stat().st_size == rec['bytes'] and sha(target) == rec['sha256'],
             'cloud binary hash mismatch: ' + name)
        with target.open('rb') as stream:
            need(stream.read(4) == b'\x7fELF', 'non-ELF cloud binary')
    expected = {'prepared/' + piece + '/' + stem + '.packet'
                for piece in PIECES for stem in ('bsc', *('own-k' + str(k) for k in KS))}
    observed = set()
    for rec in result['representations']:
        packet_name, restored_name, piece = rec['packet'], rec['restored'], rec['piece']
        need(packet_name in expected and packet_name not in observed and piece in inputs,
             'unexpected/duplicate representation')
        need(packet_name.startswith('prepared/' + piece + '/') and
             restored_name == packet_name[:-7] + '.restored.bin', 'wrong restored binding')
        packet, restored = extracted / packet_name, extracted / restored_name
        need(rec['byte_equal'] is True and packet.stat().st_size == rec['bytes'] and sha(packet) == rec['sha256'],
             'packet SHA/size mismatch')
        need(restored.stat().st_size == inputs[piece]['bytes'] and
             sha(restored) == rec['restored_sha256'] == inputs[piece]['sha256'],
             'actual restored bytes differ from locked input')
        observed.add(packet_name)
    need(observed == expected and len(observed) == 42, 'incomplete cloud packet grid')
    for piece, rec in inputs.items():
        original = extracted / 'prepared' / piece / 'original.bin'
        need(original.stat().st_size == rec['bytes'] and sha(original) == rec['sha256'],
             'actual original bytes differ from DEV-2 LOCK')
    for command in result['commands']:
        need(re.fullmatch('[a-z0-9-]+', command['label']) is not None,
             'unsafe cloud command-log label')
        for suffix in ('stdout', 'stderr'):
            path = extracted / 'evidence' / (command['label'] + '.' + suffix)
            need(sha(path) == command[suffix + '_sha256'], 'cloud command log changed')
    need(TB.is_file() and sha(TB) == TB_SHA, 'retained TurboBench binary differs')
    need(SILESIA.is_file() and SILESIA.stat().st_size == SILESIA_N and sha(SILESIA) == SILESIA_SHA,
         'known-answer-only Silesia input differs')
    return dict(extracted=str(extracted), probe=str(extracted / 'bin/crown2_probe'),
                inputs=inputs, cloud_result_sha256=sha(extracted / 'evidence/cloud-result.json'),
                artifact_sha256=sha(archive), binaries=binaries, cloud_source_sha=cloud_sha)


def parse_tb(path):
    lines = path.read_text().splitlines()
    need(len(lines) == 2 and lines[0] == HEADER, 'wrong fresh TurboBench native header/row count')
    fields = lines[1].split('\t')
    need(len(fields) == 14, 'wrong native TurboBench field count')
    row = dict(zip(HEADER.split('\t'), fields))
    need((row['dataset'], row['size'], row['codec'], row['level'], row['param'], row['err']) ==
         ('silesia.ref.tar', str(SILESIA_N), 'bsc', '0', 'e0', ''), 'TurboBench known-answer identity/roundtrip differs')
    need(re.fullmatch('[0-9]+', row['csize']) is not None and int(row['csize']) == KNOWN_BYTES,
         'bsc known-answer archive bytes differ')
    for field in ('dtime', 'ctime'):
        need(re.fullmatch(r'[0-9]+\.[0-9]{6}', row[field]) is not None and Decimal(row[field]) > 0,
             'TurboBench native time is not positive six-decimal seconds')
    return dict(native=row, compressed_bytes=int(row['csize']), roundtrip=True,
                dtime_seconds=row['dtime'], decompression_MBps=str(Decimal(SILESIA_N) / Decimal(row['dtime']) / 1000000))


def execute_attempt(cell, folder):
    folder.mkdir(parents=True, exist_ok=False)
    cwd = folder / 'cwd'; cwd.mkdir()
    record = dict(schema='crown2-h21-host-attempt-v1', cell=cell, status='ERROR',
                  command_started=False, command=cell['command'], start_utc=utc())
    try:
        record['admission'] = admission()
        if not record['admission']['pass_admission']:
            record['status'] = 'WAITING'
            return record
        record['start'] = boundary()
        if Decimal(record['start']['load1']) > 1:
            record.update(status='WAITING', reason='load changed after admission')
            return record
        env = dict(os.environ, OMP_NUM_THREADS='1', OPENBLAS_NUM_THREADS='1',
                   MKL_NUM_THREADS='1', GOMAXPROCS='1', OVH_BENCH_LOCK_HELD=OVH_LOCK)
        parent = os.getpid()
        with (folder / 'stdout').open('xb') as out, (folder / 'stderr').open('xb') as err:
            process = subprocess.Popen(cell['command'], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                       stdout=out, stderr=err, start_new_session=True,
                                       preexec_fn=lambda: parent_death(parent))
            record.update(command_started=True, worker_pid=process.pid)
            save(folder / 'started.json', dict(utc=utc(), pid=process.pid, command=cell['command']))
            try:
                record['returncode'] = process.wait(timeout=3600)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
                record.update(returncode=process.returncode, timeout=True)
        record['end'] = boundary()
        record['other_core_utilization'] = other_cores(record['start'], record['end'])
        record['loaded'] = any(Decimal(record[edge]['load1']) > 2 for edge in ('start', 'end'))
        if record['returncode'] != 0:
            raise RuntimeError('native worker failed; not eligible for LOADED retry')
        if cell['kind'] == 'known-answer':
            record['result'] = parse_tb(cwd / 'silesia.ref.tar.tbb')
            record['native_tbb_sha256'] = sha(cwd / 'silesia.ref.tar.tbb')
        else:
            lines = (folder / 'stdout').read_text().splitlines()
            need(len(lines) == 1, 'phase command did not produce exactly one JSON row')
            row = json.loads(lines[0])
            need(row['event'] == 'phase_cell' and row['roundtrip'] is True and
                 row['bytes'] == cell['bytes'] and row['repeats'] == cell['repeats'] and
                 row['prefetch'] == cell['prefetch'] and row['k'] == cell['k'] and
                 row['kind'] == cell['packet_kind'] and row['untimed_warmups'] == 1 and
                 type(row['inverse_ns']) is int and row['inverse_ns'] > 0,
                 'phase result differs from frozen cell identity')
            record['result'] = row
        record['status'] = 'LOADED' if record['loaded'] else 'CLEAN'
    except BaseException as error:
        record.update(status='ERROR', error=repr(error))
    finally:
        record['end_utc'] = utc()
        for suffix in ('stdout', 'stderr'):
            path = folder / suffix
            if not path.exists():
                path.write_bytes(b'')
            with path.open('rb') as stream:
                os.fsync(stream.fileno())
            record[suffix + '_sha256'] = sha(path)
        save(folder / 'receipt.json', record)
    return record


def locked_pair(request_path):
    need(sys.platform == 'linux' and Path('/proc', str(os.getppid()), 'comm').read_text().strip() == 'flock',
         'private pair worker must be the external flock child')
    parent_death()
    os.sched_setaffinity(0, {15})
    need(os.getpriority(os.PRIO_PROCESS, 0) == 0, 'timed children must inherit nice0')
    request = load(request_path)
    need(request['controller_sha256'] == sha(__file__), 'pair controller source changed')
    need(request['lock'] == OVH_LOCK, 'pair lock path differs')
    inode = Path(OVH_LOCK).stat().st_ino
    held = []
    for line in Path('/proc/locks').read_text().splitlines():
        fields = line.split()
        if (len(fields) >= 6 and fields[1:4] == ['FLOCK', 'ADVISORY', 'WRITE']
                and fields[4] == str(os.getppid())
                and int(fields[5].rsplit(':', 1)[-1]) == inode):
            held.append(line)
    need(len(held) == 1, 'external flock does not hold the registered OVH lock')
    work = Path(request['work']); pair = work / 'pairs' / request['id']
    emit(work, 'pair_lock_acquired', pair=request['id'], proc_lock_record=held[0])
    for cell in request['cells']:
        target = pair / cell['id']
        attempts = sorted(target.glob('attempt-*/receipt.json')) if target.exists() else []
        receipts = [load(p) for p in attempts]
        need(all(r['cell'] == cell for r in receipts), 'retained cell identity differs')
        if receipts and receipts[-1]['status'] == 'CLEAN':
            continue
        if any(r['status'] == 'ERROR' for r in receipts):
            return 2
        actual = sum(r['command_started'] for r in receipts)
        if actual >= 3:
            emit(work, 'blocked_load', pair=request['id'], cell=cell['id'], attempts=actual)
            return 77
        number = len(attempts) + 1
        record = execute_attempt(cell, target / ('attempt-%04d' % number))
        emit(work, 'cell_finished', pair=request['id'], cell=cell['id'], status=record['status'],
             receipt=str(target / ('attempt-%04d' % number) / 'receipt.json'))
        if record['status'] == 'ERROR':
            return 2
        if record['status'] in ('WAITING', 'LOADED'):
            emit(work, 'pair_interrupted', pair=request['id'], pending_cell=cell['id'], reason=record['status'])
            return 77 if record['status'] == 'LOADED' and actual + 1 >= 3 else 75
    return 0


def run_pair(work, identifier, cells, max_wait_seconds):
    need(re.fullmatch('[a-zA-Z0-9-]+', identifier) is not None, 'unsafe pair ID')
    pair = work / 'pairs' / identifier; pair.mkdir(parents=True)
    request = dict(id=identifier, work=str(work), cells=cells, controller_sha256=sha(__file__), lock=OVH_LOCK)
    request_path = pair / 'request.json'; save(request_path, request)
    deadline = time.monotonic() + max_wait_seconds
    interruptions = 0
    while True:
        observation = admission()
        emit(work, 'admission', pair=identifier, observation=observation)
        if not observation['pass_admission']:
            if time.monotonic() + WAIT_SECONDS >= deadline:
                raise Blocked('quiet admission wait budget exhausted: ' + identifier)
            time.sleep(WAIT_SECONDS)
            continue
        command = ['flock', OVH_LOCK, sys.executable, '-B', str(Path(__file__).resolve()),
                   '_locked-pair', str(request_path)]
        emit(work, 'pair_lock_wait', pair=identifier, command=command)
        parent = os.getpid()
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   preexec_fn=lambda: parent_death(parent))
        try:
            code = process.wait(timeout=max(1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
            raise Blocked('pair lock/wait budget exhausted: ' + identifier)
        if code == 0:
            selected = []
            for cell in cells:
                paths = sorted((pair / cell['id']).glob('attempt-*/receipt.json'))
                path = next(p for p in paths if load(p)['status'] == 'CLEAN')
                row = load(path)
                need(row['cell'] == cell and row['command_started'], 'CLEAN cell identity mismatch')
                for suffix in ('stdout', 'stderr'):
                    need(sha(path.parent / suffix) == row[suffix + '_sha256'], 'retained native stream changed')
                selected.append(dict(cell=cell, receipt=str(path), receipt_sha256=sha(path), result=row['result']))
            result = dict(id=identifier, status='CLEAN', interruptions=interruptions, selected=selected)
            save(pair / 'result.json', result)
            return result
        if code == 77:
            raise Blocked('three LOADED attempts: ' + identifier)
        if code != 75:
            raise RuntimeError('pair worker failed; no retiming: ' + identifier)
        interruptions += 1
        if time.monotonic() + WAIT_SECONDS >= deadline:
            raise Blocked('interrupted pair wait budget exhausted: ' + identifier)
        time.sleep(WAIT_SECONDS)


def phase_cell(context, piece, k, prefetch, identifier, lane):
    prepared = Path(context['extracted']) / 'prepared' / piece
    packet = prepared / ('bsc.packet' if lane == 'reference' else 'own-k%d.packet' % k)
    n = context['inputs'][piece]['bytes']
    need(BYTE_BUDGET % n == 0, 'nonintegral fixed repeat budget')
    repeats = BYTE_BUDGET // n
    return dict(id=identifier, kind='phase', piece=piece, lane=lane, bytes=n,
                k=0 if lane == 'reference' else k, packet_kind=1 if lane == 'reference' else 0,
                prefetch=0 if lane == 'reference' else prefetch, repeats=repeats,
                packet_sha256=sha(packet), original_sha256=context['inputs'][piece]['sha256'],
                command=['taskset', '-c', '0', context['probe'], 'bench', str(packet),
                         str(prepared / 'original.bin'), str(0 if lane == 'reference' else prefetch),
                         str(repeats), 'ace-core'])


def known_answer(work, max_wait_seconds):
    trials = []
    for trial in (1, 2):
        passes = []
        for number in (1, 2, 3):
            cell = dict(id='bsc', kind='known-answer', command=[
                'taskset', '-c', '0', str(TB), '-ebsc,0e0', '-b1073741824B',
                '-B211947520B', '-i0,0', '-C3', '-D', '-V0', '-v0', str(SILESIA)])
            pair = run_pair(work, 'known-t%d-p%d' % (trial, number), [cell], max_wait_seconds)
            passes.append(pair['selected'][0])
        speeds = [Decimal(p['result']['decompression_MBps']) for p in passes]
        median = statistics.median(speeds)
        accepted = Decimal(70) <= median <= Decimal(82)
        value = dict(trial=trial, passes=passes, median_MBps=str(median),
                     accepted=accepted, archive_bytes=KNOWN_BYTES,
                     repeats_previous_clean_trial=trial == 2,
                     permitted_reason='registered known-answer corridor' if trial == 2 else None)
        trials.append(value); save(work / ('known-answer-trial-%d.json' % trial), value)
        if accepted:
            result = dict(status='PASS', trials=trials, selected_trial=trial)
            save(work / 'known-answer.json', result)
            return result
    raise Blocked('reference drift: bsc median outside [70,82] after one permitted full repeat')


def aa_control(context, work, max_wait_seconds):
    result = []
    for piece in PIECES:
        lanes = {'a': [], 'b': []}
        for number in (1, 2, 3):
            cells = [phase_cell(context, piece, 0, 0, lane, 'reference') for lane in ('a', 'b')]
            if number % 2 == 0:
                cells.reverse()
            pair = run_pair(work, 'aa-%s-p%d' % (piece.replace('_', '-'), number), cells, max_wait_seconds)
            for selected in pair['selected']:
                lanes[selected['cell']['id']].append(selected['result']['inverse_ns'])
        medians = {k: statistics.median(v) for k, v in lanes.items()}
        difference = Decimal(max(medians.values())) / Decimal(min(medians.values())) - 1
        row = dict(piece=piece, lane_ns=lanes, medians_ns=medians,
                   relative_difference=str(difference), formula='max(medianA,medianB)/min(medianA,medianB)-1',
                   passed=difference < Decimal('0.05'))
        result.append(row)
        save(work / ('aa-' + piece + '.json'), row)
        need(row['passed'], 'A/A control >=5%; method invalid; no primary timings')
    save(work / 'aa-control.json', dict(status='PASS', pieces=result))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '_locked-pair':
        return locked_pair(Path(sys.argv[2]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--cloud-source-sha', default=CLOUD_SOURCE)
    parser.add_argument('--artifacts-sha256', help='optional expected transport SHA from the cloud receipt')
    parser.add_argument('--max-admission-wait-seconds', type=int, default=7200)
    args = parser.parse_args()
    need(sys.platform == 'linux' and platform.node() == 'ace-core', 'speed is restricted to ace-core')
    need(not os.environ.get('OVH_BENCH_LOCK_HELD'), 'start controller outside timing lock')
    need(not any(os.environ.get(k) for k in ('LD_PRELOAD', 'LD_AUDIT', 'LD_LIBRARY_PATH')),
         'dynamic-loader overrides must be absent')
    os.sched_setaffinity(0, {15})
    need(os.getpriority(os.PRIO_PROCESS, 0) == 0, 'start with nice0; do not inherit a nice15 inspection shell')
    need(re.fullmatch('[0-9a-f]{40}', args.cloud_source_sha) is not None, 'full cloud source SHA required')
    need(300 <= args.max_admission_wait_seconds <= 86400, 'invalid bounded admission wait')
    need(args.artifacts.is_file() and not args.artifacts.is_symlink(), 'regular cloud archive required')
    if args.artifacts_sha256:
        need(sha(args.artifacts) == args.artifacts_sha256, 'artifact transport SHA mismatch')
    work = args.work.absolute()
    need(not work.exists() and work.parent.is_dir() and work.parent.resolve() == work.parent,
         'work must be a fresh path under an existing nonsymlink parent')
    need(work != ROOT and not work.is_relative_to(Path('/home/ubuntu/ACE_TRINITY_EVO/LAB/DEV2')),
         'work cannot overwrite source or DEV-2')
    git = lambda *a: subprocess.check_output(['git', '-C', str(ROOT), *a], text=True).strip()
    source = git('rev-parse', 'HEAD')
    need(not git('status', '--porcelain'), 'timing harness must be committed and clean')
    subprocess.run(['git', '-C', str(ROOT), 'merge-base', '--is-ancestor', CAL_FIRST, source], check=True)
    subprocess.run(['git', '-C', str(ROOT), 'merge-base', '--is-ancestor', args.cloud_source_sha, source], check=True)
    work.mkdir()
    started = utc()
    identity = dict(harness_source_sha=source, run_host_sha256=sha(__file__),
                    calibration_sha256=sha(HERE / 'CALIBRATION.md'), lock_sha256=sha(HERE / 'LOCK.json'),
                    preregistration_commit=CAL_FIRST, cloud_source_sha=args.cloud_source_sha)
    status = dict(status='STARTED', utc_start=started, identity=identity,
                  no_candidate_silesia=True, benchmark_lock=OVH_LOCK, own_work=str(work))
    save(work / 'status.json', status)
    try:
        context = validated_artifacts(args.artifacts, work, args.cloud_source_sha)
        save(work / 'artifact-validation.json', {**context, **identity, 'status': 'PASS'})
        host = boundary()
        need('AMD EPYC 4344P' in host['cpu'], 'unexpected benchmark CPU')
        need(host['disk_available_bytes'] >= 30_000_000_000, 'DEV-2 requires at least 30 GB free before timings')
        save(work / 'host-start.json', host)
        known_answer(work, args.max_admission_wait_seconds)
        aa_control(context, work, args.max_admission_wait_seconds)
        grid = [(piece, k, pf) for piece in PIECES for k in KS for pf in (0, 1)]
        selected_pairs = []
        for number in (1, 2, 3):
            order = grid if number == 1 else list(reversed(grid)) if number == 2 else grid[len(grid) // 2:] + grid[:len(grid) // 2]
            for index, (piece, k, pf) in enumerate(order):
                identifier = 'main-p%d-%s-k%d-f%d' % (number, piece.replace('_', '-'), k, pf)
                reference = phase_cell(context, piece, 0, 0, 'reference', 'reference')
                own = phase_cell(context, piece, k, pf, 'candidate', 'candidate')
                cells = [reference, own] if (number + index) % 2 else [own, reference]
                pair = run_pair(work, identifier, cells, args.max_admission_wait_seconds)
                selected_pairs.append(dict(id=identifier, pass_number=number, piece=piece, k=k, prefetch=pf,
                                           interruptions=pair['interruptions'], result=str(work / 'pairs' / identifier / 'result.json')))
                save(work / 'primary-progress.json', dict(status='IN_PROGRESS', pairs=selected_pairs), replace=True)
        save(work / 'primary-grid.json', dict(status='COMPLETE', pairs=selected_pairs,
                                            order_rule='pass1 forward, pass2 reverse, pass3 rotate-half; pair order parity',
                                            fixed_decoded_bytes_per_cell=BYTE_BUDGET))
        save(work / 'host-end.json', boundary())
        status.update(status='COMPLETE', primary_pairs=len(selected_pairs),
                      interrupted_pairs=sum(p['interruptions'] > 0 for p in selected_pairs))
    except Blocked as error:
        status.update(status='BLOCKED', reason=str(error))
    except BaseException as error:
        status.update(status='ERROR', reason=repr(error))
    finally:
        status['utc_end'] = utc()
        save(work / 'status.json', status, replace=True)
        emit(work, 'host_run_finished', **status)
    return 0 if status['status'] == 'COMPLETE' else 77 if status['status'] == 'BLOCKED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
