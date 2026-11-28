#!/usr/bin/env python3
"""Audit and summarize saved CROWN-2 H2.1 evidence; never run a codec or timer."""
import argparse
import csv
from decimal import Decimal, localcontext
from fractions import Fraction
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import statistics
import subprocess


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PIECES = ('d2_text_en', 'd2_text_src', 'd2_x86', 'd2_table_sdf',
          'd2_table_db', 'd2_image', 'd2_xml')
KS = (1, 4, 8, 16, 32)
BUDGET = 64 * 1024 * 1024
SIGNATURE = "[written by ChatGPT (AI) at the author's request; checked by the author]"
TB_HEADER = 'dataset\tsize\tcsize\tdtime\tctime\tcodec\tlevel\tparam\tcmem\tdmem\tcstack\tdstack\ttime\terr'
LOCK_PATH = '/run/lock/ovh-bench.lock'


class InvalidEvidence(ValueError):
    pass


class MissingEvidence(ValueError):
    pass


def need(condition, reason):
    if not condition:
        raise InvalidEvidence(reason)


def integer(value, reason, positive=False):
    need(type(value) is int and (value > 0 if positive else value >= 0), reason)
    return value


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def exact(value):
    value = Fraction(value)
    return dict(numerator=str(value.numerator), denominator=str(value.denominator))


def fraction(value):
    return Fraction(int(value['numerator']), int(value['denominator']))


def presentation(value, places=6):
    value = Fraction(value)
    with localcontext() as context:
        context.prec = 80
        return format(Decimal(value.numerator) / Decimal(value.denominator), '.' + str(places) + 'f')


def geometric_presentation(product):
    with localcontext() as context:
        context.prec = 80
        value = Decimal(product.numerator) / Decimal(product.denominator)
        return format((value.ln() / Decimal(7)).exp(), '.9f')


class Audit:
    def __init__(self, work):
        self.work = work
        self.original = None
        self.inventory = {}
        self.missing = []
        self.sources = []
        self.attempts = []
        self.interrupted_attempts = []
        self.pairs = {}
        self.events = []
        self.inputs = {}
        self.packet_records = {}

    def path(self, relative):
        parts = PurePosixPath(relative)
        need(not parts.is_absolute() and '..' not in parts.parts, 'unsafe relative evidence path')
        path = self.work.joinpath(*parts.parts)
        need(path.absolute() == path.resolve() and path.resolve().is_relative_to(self.work),
             'symlink or escape in evidence path: ' + str(path))
        return path

    def saved_relative(self, saved):
        path, original = PurePosixPath(saved), PurePosixPath(self.original)
        try:
            relative = path.relative_to(original)
        except ValueError:
            raise InvalidEvidence('saved evidence path escapes its recorded work root: ' + str(saved))
        return relative.as_posix()

    def read(self, relative, required=True):
        path = self.path(relative)
        if not path.is_file():
            if relative not in self.missing:
                self.missing.append(relative)
            if required:
                raise MissingEvidence('missing saved evidence: ' + relative)
            return None
        before = path.stat()
        data = path.read_bytes()
        after = path.stat()
        need((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
             (after.st_size, after.st_mtime_ns, after.st_ctime_ns),
             'evidence changed while being read: ' + relative)
        self.inventory[relative] = dict(bytes=len(data), sha256=digest_bytes(data))
        return data

    def json(self, relative, required=True):
        data = self.read(relative, required)
        if data is None:
            return None
        try:
            return json.loads(data)
        except (ValueError, UnicodeError) as error:
            raise InvalidEvidence('invalid JSON ' + relative + ': ' + str(error))

    def file_record(self, relative, expected):
        data = self.read(relative)
        rec = self.inventory[relative]
        need(rec['sha256'] == expected['sha256'] and rec['bytes'] == expected['bytes'],
             'saved file hash/length mismatch: ' + relative)
        return data

    def source_blob(self, revision, name, expected=None):
        need(re.fullmatch('[0-9a-f]{40}', revision) is not None, 'source commit must be full SHA')
        spec = revision + ':research/crown2-bwt/' + name
        result = subprocess.run(['git', '-C', str(ROOT), 'show', spec],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            self.missing.append('git:' + spec)
            return None
        record = dict(commit=revision, path='research/crown2-bwt/' + name,
                      bytes=len(result.stdout), sha256=digest_bytes(result.stdout))
        if expected is not None:
            need(record['sha256'] == expected, 'source blob differs from recorded hash: ' + spec)
        self.sources.append(record)
        return result.stdout

    def validate_sources(self, identity):
        source = identity['harness_source_sha']
        for name, key in [('run_host.py', 'run_host_sha256'), ('CALIBRATION.md', 'calibration_sha256'),
                          ('LOCK.json', 'lock_sha256')]:
            data = self.source_blob(source, name, identity[key])
            if name == 'LOCK.json' and data is not None:
                locked = json.loads(data)
                self.inputs = locked['selection_set']['inputs']
                need(set(self.inputs) == set(PIECES), 'source LOCK does not contain seven DEV-2 pieces')
                need(sum(v['bytes'] for v in self.inputs.values()) == 41943040,
                     'source LOCK DEV-2 byte total differs')
        cloud_source = identity['cloud_source_sha']
        for name in ('core.hpp', 'core.cpp', 'baseline.hpp', 'baseline.cpp', 'cli.cpp',
                     'CMakeLists.txt', 'cloud_job.py'):
            self.source_blob(cloud_source, name)

    def cloud(self, identity):
        validation = self.json('artifact-validation.json', required=False)
        result = self.json('artifacts/evidence/cloud-result.json', required=False)
        if validation is None or result is None or not self.inputs:
            return dict(status='PENDING')
        need(validation['status'] == 'PASS', 'artifact validation is not PASS')
        for key, value in identity.items():
            need(validation.get(key) == value, 'artifact-validation identity differs: ' + key)
        need(self.inventory['artifacts/evidence/cloud-result.json']['sha256'] ==
             validation['cloud_result_sha256'], 'cloud result changed after host validation')
        need(result['status'] == 'PASS' and result['source_sha'] == identity['cloud_source_sha'],
             'cloud method did not PASS on recorded source')
        need(result['inputs']['inputs'] == self.inputs and
             result['inputs']['source_sha'] == identity['cloud_source_sha'], 'cloud inputs differ from LOCK')
        for name, rec in result['binaries'].items():
            need(name in ('crown2_probe', 'libcrown2_baseline.so'), 'unexpected cloud binary')
            self.file_record('artifacts/bin/' + name, rec)
        need(set(result['binaries']) == {'crown2_probe', 'libcrown2_baseline.so'}, 'missing cloud binary')
        for name, rec in self.inputs.items():
            self.file_record('artifacts/prepared/' + name + '/original.bin', rec)
        expected = {'prepared/' + p + '/' + s + '.packet'
                    for p in PIECES for s in ('bsc', *('own-k' + str(k) for k in KS))}
        for rec in result['representations']:
            packet = rec['packet']
            need(packet in expected and packet not in self.packet_records,
                 'unexpected or duplicate cloud representation')
            piece = rec['piece']
            need(piece in self.inputs and packet.startswith('prepared/' + piece + '/'),
                 'cloud representation piece binding differs')
            need(rec['restored'] == packet[:-7] + '.restored.bin' and rec['byte_equal'] is True,
                 'cloud representation lacks byte-equal roundtrip')
            self.file_record('artifacts/' + packet, rec)
            self.file_record('artifacts/' + rec['restored'],
                             dict(bytes=self.inputs[piece]['bytes'], sha256=rec['restored_sha256']))
            need(rec['restored_sha256'] == self.inputs[piece]['sha256'], 'restored input SHA differs')
            self.packet_records[packet] = rec
        need(set(self.packet_records) == expected, 'cloud packet grid incomplete')
        commands = {c['label']: c for c in result['commands']}
        need('selftest' in commands and 'prepare' in commands, 'missing cloud method controls')
        for command in result['commands']:
            label = command['label']
            need(re.fullmatch('[a-z0-9-]+', label) is not None, 'unsafe cloud log label')
            if label != 'instructions':
                need(command['returncode'] == 0, 'cloud correctness/build command failed')
            for suffix in ('stdout', 'stderr'):
                rel = 'artifacts/evidence/' + label + '.' + suffix
                self.read(rel)
                need(self.inventory[rel]['sha256'] == command[suffix + '_sha256'],
                     'cloud command stream hash mismatch')
        selftest = json.loads(self.read('artifacts/evidence/selftest.stdout'))
        need(selftest['event'] == 'selftest_pass' and selftest['negative_controls'] is True and
             selftest['own_cases'] > 0, 'negative/positive selftest did not PASS')
        return dict(status='PASS', source_sha=result['source_sha'],
                    cloud_result_sha256=validation['cloud_result_sha256'],
                    artifact_sha256=validation['artifact_sha256'],
                    instruction_counter=result.get('instruction_counter'),
                    utc_start=result.get('utc_start'), utc_end=result.get('utc_end'),
                    packet_count=len(self.packet_records), binary_hashes=result['binaries'])

    def expected_pairs(self):
        result = {}
        grid = [(p, k, pf) for p in PIECES for k in KS for pf in (0, 1)]
        for number in (1, 2, 3):
            order = grid if number == 1 else list(reversed(grid)) if number == 2 else grid[len(grid)//2:] + grid[:len(grid)//2]
            for index, (piece, k, pf) in enumerate(order):
                key = 'main-p%d-%s-k%d-f%d' % (number, piece.replace('_', '-'), k, pf)
                lanes = ['reference', 'candidate'] if (number + index) % 2 else ['candidate', 'reference']
                result[key] = dict(kind='main', piece=piece, k=k, prefetch=pf, pass_number=number, lanes=lanes)
        for piece in PIECES:
            for number in (1, 2, 3):
                key = 'aa-%s-p%d' % (piece.replace('_', '-'), number)
                result[key] = dict(kind='aa', piece=piece, pass_number=number,
                                   lanes=['a', 'b'] if number % 2 else ['b', 'a'])
        for trial in (1, 2):
            for number in (1, 2, 3):
                result['known-t%d-p%d' % (trial, number)] = dict(
                    kind='known', trial=trial, pass_number=number, lanes=['bsc'])
        return result

    def validate_cell(self, cell, spec):
        need(cell['id'] in spec['lanes'], 'unexpected cell lane')
        if spec['kind'] == 'known':
            need(cell['kind'] == 'known-answer' and cell['id'] == 'bsc', 'wrong known-answer cell')
            command = cell['command']
            need(command[:3] == ['taskset', '-c', '0'] and
                 command[4:-1] == ['-ebsc,0e0', '-b1073741824B', '-B211947520B',
                                  '-i0,0', '-C3', '-D', '-V0', '-v0'] and
                 PurePosixPath(command[-1]).name == 'silesia.ref.tar', 'known-answer command differs')
            return
        need(cell['kind'] == 'phase' and cell['piece'] == spec['piece'], 'phase cell identity differs')
        reference = spec['kind'] == 'aa' or cell['id'] == 'reference'
        k, pf = (0, 0) if reference else (spec['k'], spec['prefetch'])
        need(cell['k'] == k and cell['prefetch'] == pf and
             cell['packet_kind'] == (1 if reference else 0) and
             cell['lane'] == ('reference' if reference else 'candidate'), 'phase lane/grid differs')
        n = integer(cell['bytes'], 'invalid cell bytes', True)
        repeats = integer(cell['repeats'], 'invalid cell repeats', True)
        need(n * repeats == BUDGET, 'cell does not decode fixed 64 MiB')
        if self.inputs:
            need(n == self.inputs[spec['piece']]['bytes'] and
                 cell['original_sha256'] == self.inputs[spec['piece']]['sha256'], 'cell input differs from LOCK')
        stem = 'bsc' if reference else 'own-k' + str(k)
        packet = 'prepared/' + spec['piece'] + '/' + stem + '.packet'
        if self.packet_records:
            need(cell['packet_sha256'] == self.packet_records[packet]['sha256'], 'cell packet differs from cloud')
        command = cell['command']
        need(command[:3] == ['taskset', '-c', '0'] and len(command) == 10 and
             command[4] == 'bench' and command[7:] == [str(pf), str(repeats), 'ace-core'],
             'phase command differs from registered scope')
        need(self.saved_relative(command[3]) == 'artifacts/bin/crown2_probe' and
             self.saved_relative(command[5]) == 'artifacts/' + packet and
             self.saved_relative(command[6]) == 'artifacts/prepared/' + spec['piece'] + '/original.bin',
             'phase command path differs from selected representation')

    def phase_result(self, row, cell):
        need(row['event'] == 'phase_cell' and row['roundtrip'] is True and row['untimed_warmups'] == 1,
             'native phase row lacks roundtrip/warmup')
        for left, right in [('bytes', 'bytes'), ('repeats', 'repeats'), ('k', 'k'),
                            ('prefetch', 'prefetch'), ('kind', 'packet_kind')]:
            need(type(row[left]) is int and row[left] == cell[right], 'native cell identity differs: ' + left)
        for key in ('inverse_ns', 'table_ns', 'walk_ns', 'representation_bytes'):
            integer(row[key], 'invalid native ' + key, key in ('inverse_ns', 'representation_bytes'))
        need(row['table_ns'] + row['walk_ns'] <= row['inverse_ns'], 'diagnostic subdivisions exceed full inverse')
        if cell['lane'] == 'reference':
            need(row['table_ns'] == row['walk_ns'] == 0, 'reference diagnostic time unexpectedly nonzero')
        packet = self.saved_relative(cell['command'][5])[len('artifacts/'):]
        if self.packet_records:
            need(row['representation_bytes'] == self.packet_records[packet]['bytes'], 'native packet byte count differs')

    def known_result(self, attempt, receipt):
        native_path = attempt + '/cwd/silesia.ref.tar.tbb'
        data = self.read(native_path)
        need(self.inventory[native_path]['sha256'] == receipt['native_tbb_sha256'], 'native TB log changed')
        lines = data.decode().splitlines()
        need(len(lines) == 2 and lines[0] == TB_HEADER, 'unexpected TurboBench native format')
        values = lines[1].split('\t')
        need(len(values) == 14, 'TurboBench native field count differs')
        row = dict(zip(TB_HEADER.split('\t'), values))
        need((row['dataset'], row['size'], row['codec'], row['level'], row['param'], row['err']) ==
             ('silesia.ref.tar', '211947520', 'bsc', '0', 'e0', ''), 'known-answer identity/roundtrip differs')
        need(row['csize'] == '50266774', 'known-answer archive size drift')
        need(re.fullmatch(r'[0-9]+\.[0-9]{6}', row['dtime']) is not None and Fraction(row['dtime']) > 0,
             'invalid native TB decompression seconds')
        need(receipt['result']['native'] == row and receipt['result']['roundtrip'] is True,
             'known-answer receipt differs from native log')
        return Fraction(211947520, 1000000) / Fraction(row['dtime'])

    def receipt(self, rel, cell):
        rec = self.json(rel)
        need(rec['schema'] == 'crown2-h21-host-attempt-v1' and rec['cell'] == cell and
             rec['command'] == cell['command'], 'attempt cell/command binding differs')
        need(rec['status'] in ('CLEAN', 'LOADED', 'WAITING', 'ERROR'), 'unknown attempt status')
        need(type(rec['command_started']) is bool, 'invalid command_started flag')
        folder = str(PurePosixPath(rel).parent)
        for suffix in ('stdout', 'stderr'):
            self.read(folder + '/' + suffix)
            need(self.inventory[folder + '/' + suffix]['sha256'] == rec[suffix + '_sha256'],
                 'native stream SHA mismatch: ' + rel)
        if rec['status'] in ('CLEAN', 'LOADED'):
            need(rec['command_started'] is True and rec['returncode'] == 0,
                 'accepted/excluded timing did not complete successfully')
            need(rec['admission']['pass_admission'] is True and
                 not rec['admission']['cpu']['errors'] and not rec['admission']['cpu']['exceeded'] and
                 Fraction(rec['admission']['boundary']['load1']) <= 1 and
                 Fraction(rec['start']['load1']) <= 1, 'timed attempt failed quiet admission')
            for edge in ('start', 'end'):
                host = rec[edge]
                need(host['hostname'] == 'ace-core' and 'AMD EPYC 4344P' in host['cpu'] and
                     host['pinned_core'] == 0 and host['timed_threads'] == 1,
                     'timed attempt host/core/thread identity differs')
                need(Fraction(host['load1']) >= 0, 'negative load1')
            loaded = any(Fraction(rec[e]['load1']) > 2 for e in ('start', 'end'))
            need(rec['loaded'] is loaded and rec['status'] == ('LOADED' if loaded else 'CLEAN'),
                 'attempt CLEAN/LOADED decision differs from registered load rule')
            if cell['kind'] == 'phase':
                lines = self.read(folder + '/stdout').splitlines()
                need(len(lines) == 1, 'phase worker emitted multiple/missing native rows')
                row = json.loads(lines[0])
                need(row == rec['result'], 'receipt phase result differs from native stdout')
                self.phase_result(row, cell)
            else:
                rec['_known_speed'] = self.known_result(folder, rec)
        elif rec['status'] == 'WAITING':
            need(rec['command_started'] is False, 'WAITING receipt started a timed command')
        self.attempts.append(dict(path=rel, status=rec['status'], command_started=rec['command_started'],
                                  pair=PurePosixPath(rel).parts[1], cell=cell['id']))
        return rec

    def read_pairs(self, identity):
        expected = self.expected_pairs()
        directory = self.path('pairs')
        if not directory.exists():
            self.missing.append('pairs/')
            return
        for pair_path in sorted(directory.iterdir()):
            need(pair_path.is_dir() and not pair_path.is_symlink() and pair_path.name in expected,
                 'unexpected pair directory: ' + pair_path.name)
            key, spec = pair_path.name, expected[pair_path.name]
            prefix = 'pairs/' + key
            request = self.json(prefix + '/request.json', required=False)
            if request is None:
                continue
            need(request['id'] == key and request['work'] == self.original and
                 request['controller_sha256'] == identity['run_host_sha256'] and
                 request['lock'] == LOCK_PATH, 'pair request identity differs')
            need([c['id'] for c in request['cells']] == spec['lanes'], 'round-robin lane order differs')
            accepted = {}
            for cell in request['cells']:
                self.validate_cell(cell, spec)
                target = pair_path / cell['id']
                attempts = sorted(target.glob('attempt-*')) if target.exists() else []
                seen = []
                for number, attempt in enumerate(attempts, 1):
                    need(attempt.name == 'attempt-%04d' % number and attempt.is_dir() and
                         not attempt.is_symlink(), 'attempt numbering/path differs')
                    rel = prefix + '/' + cell['id'] + '/' + attempt.name
                    if not (attempt / 'receipt.json').is_file():
                        self.missing.append(rel + '/receipt.json')
                        started = self.json(rel + '/started.json', required=False)
                        if started is not None:
                            need(started['command'] == cell['command'], 'interrupted command differs')
                        self.interrupted_attempts.append(dict(pair=key, cell=cell['id'], path=rel,
                                                             command_started=started is not None))
                        continue
                    need(not seen or seen[-1]['status'] not in ('CLEAN', 'ERROR'),
                         'attempt repeated after CLEAN or ERROR')
                    rec = self.receipt(rel + '/receipt.json', cell)
                    seen.append(rec)
                    if rec['status'] == 'CLEAN':
                        accepted[cell['id']] = dict(path=rel + '/receipt.json', record=rec)
                need(sum(r['command_started'] for r in seen) <= 3, 'timed-attempt budget exceeded')
            result = self.json(prefix + '/result.json', required=False)
            if result is not None:
                need(result['id'] == key and result['status'] == 'CLEAN' and
                     [s['cell'] for s in result['selected']] == request['cells'], 'pair result differs from request')
                need(len(accepted) == len(request['cells']), 'pair selected without all CLEAN receipts')
                for selected in result['selected']:
                    chosen = accepted[selected['cell']['id']]
                    rel = chosen['path']
                    need(self.saved_relative(selected['receipt']) == rel and
                         selected['receipt_sha256'] == self.inventory[rel]['sha256'] and
                         selected['result'] == chosen['record']['result'], 'selected receipt SHA/result differs')
                integer(result['interruptions'], 'invalid pair interruption count')
            self.pairs[key] = dict(spec=spec, accepted=accepted, result=result)

    def method_controls(self):
        known = self.json('known-answer.json', required=False)
        aa = self.json('aa-control.json', required=False)
        answer = dict(known_answer=dict(status='PENDING'), aa=dict(status='PENDING'))
        if known is not None:
            need(known['status'] == 'PASS' and known['selected_trial'] in (1, 2), 'known-answer gate is not PASS')
            need(len(known['trials']) == known['selected_trial'], 'known-answer repeat count differs')
            trials = []
            for number, saved in enumerate(known['trials'], 1):
                native = self.json('known-answer-trial-%d.json' % number)
                need(native == saved and saved['trial'] == number, 'known-answer trial record changed')
                speeds = []
                for p in (1, 2, 3):
                    pair = self.pairs.get('known-t%d-p%d' % (number, p))
                    need(pair is not None and pair['result'] is not None, 'known-answer trial pair incomplete')
                    need(saved['passes'][p - 1] == pair['result']['selected'][0], 'known-answer selected pass differs')
                    speeds.append(pair['accepted']['bsc']['record']['_known_speed'])
                median = statistics.median(speeds)
                passed = Fraction(70) <= median <= Fraction(82)
                need(saved['accepted'] is passed and passed is (number == known['selected_trial']),
                     'known-answer repeat/acceptance differs from registered corridor')
                trials.append(dict(trial=number, median_MBps=exact(median), accepted=passed,
                                   archive_bytes=50266774))
            answer['known_answer'] = dict(status='PASS', selected_trial=known['selected_trial'], trials=trials)
        if aa is not None:
            need(aa['status'] == 'PASS' and {r['piece'] for r in aa['pieces']} == set(PIECES) and
                 len(aa['pieces']) == 7, 'A/A gate lacks seven pieces')
            rows = []
            for piece in PIECES:
                lanes = {'a': [], 'b': []}
                for p in (1, 2, 3):
                    pair = self.pairs.get('aa-%s-p%d' % (piece.replace('_', '-'), p))
                    need(pair is not None and pair['result'] is not None, 'A/A pair incomplete')
                    for lane in lanes:
                        lanes[lane].append(pair['accepted'][lane]['record']['result']['inverse_ns'])
                medians = {lane: statistics.median(times) for lane, times in lanes.items()}
                difference = Fraction(max(medians.values()), min(medians.values())) - 1
                saved = next(r for r in aa['pieces'] if r['piece'] == piece)
                need(saved['lane_ns'] == lanes and saved['medians_ns'] == medians and
                     saved['passed'] is True and difference < Fraction(1, 20), 'A/A >=5% or saved A/A differs')
                rows.append(dict(piece=piece, lane_ns=lanes, medians_ns=medians,
                                 relative_difference=exact(difference), passed=True))
            answer['aa'] = dict(status='PASS', pieces=rows)
        return answer

    def rows(self):
        rows = []
        for k in KS:
            for pf in (0, 1):
                for piece in PIECES:
                    row = dict(piece=piece, k=k, prefetch=pf, status='PENDING', passes=[])
                    for number in (1, 2, 3):
                        key = 'main-p%d-%s-k%d-f%d' % (number, piece.replace('_', '-'), k, pf)
                        pair = self.pairs.get(key)
                        if pair is not None and pair['result'] is not None:
                            row['passes'].append(dict(pass_number=number,
                                reference=pair['accepted']['reference']['record']['result'],
                                own=pair['accepted']['candidate']['record']['result'], pair=key))
                    if len(row['passes']) == 3:
                        ref = [p['reference'] for p in row['passes']]
                        own = [p['own'] for p in row['passes']]
                        ref_ns = statistics.median(r['inverse_ns'] for r in ref)
                        own_ns = statistics.median(r['inverse_ns'] for r in own)
                        need(len({r['representation_bytes'] for r in ref}) == 1 and
                             len({r['representation_bytes'] for r in own}) == 1, 'packet size changed across passes')
                        repeats = own[0]['repeats']
                        row.update(status='COMPLETE', reference_median_ns=ref_ns, own_median_ns=own_ns,
                            phase_speedup=exact(Fraction(ref_ns, own_ns)),
                            reference_MBps=exact(Fraction(BUDGET * 1000, ref_ns)),
                            own_MBps=exact(Fraction(BUDGET * 1000, own_ns)),
                            reference_packet_bytes=ref[0]['representation_bytes'],
                            own_packet_bytes=own[0]['representation_bytes'], repeats=repeats,
                            own_table_us=exact(Fraction(statistics.median(r['table_ns'] for r in own), repeats * 1000)),
                            own_walk_us=exact(Fraction(statistics.median(r['walk_ns'] for r in own), repeats * 1000)))
                    rows.append(row)
        return rows

    def counts(self):
        counts = {key: sum(r['status'] == key for r in self.attempts)
                  for key in ('CLEAN', 'LOADED', 'WAITING', 'ERROR')}
        grouped = {}
        for rec in self.attempts:
            key = rec['pair'] + '/' + rec['cell']
            row = grouped.setdefault(key, dict(cell=key, attempts=0, timed_attempts=0,
                                               CLEAN=0, LOADED=0, WAITING=0, ERROR=0))
            row['attempts'] += 1
            row['timed_attempts'] += int(rec['command_started'])
            row[rec['status']] += 1
        interruption_events = [r for r in self.events if r.get('event') == 'pair_interrupted']
        return dict(receipted_attempts=len(self.attempts), statuses=counts,
                    timed_attempts=sum(r['command_started'] for r in self.attempts) +
                                   sum(r['command_started'] for r in self.interrupted_attempts),
                    unreceipted_attempts=self.interrupted_attempts,
                    loaded_timed_attempts=counts['LOADED'],
                    retaken_timed_cells=sum(r['timed_attempts'] > 1 for r in grouped.values()),
                    retaken_loaded_attempts=sum(max(0, r['timed_attempts'] - 1) for r in grouped.values()),
                    admission_wait_observations=sum(r.get('event') == 'admission' and
                        r.get('observation', {}).get('pass_admission') is False for r in self.events),
                    interrupted_pair_events=len(interruption_events),
                    interrupted_pairs=len({r['pair'] for r in interruption_events}),
                    per_cell=[grouped[k] for k in sorted(grouped)])

    def run(self):
        status = self.json('status.json')
        identity = status['identity']
        self.original = status['own_work']
        need(status['benchmark_lock'] == LOCK_PATH and status['no_candidate_silesia'] is True,
             'run status scope differs')
        self.validate_sources(identity)
        cloud = self.cloud(identity)
        events = self.read('events.jsonl', required=False)
        if events is not None:
            for line in events.splitlines():
                if line.strip():
                    self.events.append(json.loads(line))
        self.read_pairs(identity)
        controls = self.method_controls()
        rows = self.rows()
        grid = self.json('primary-grid.json', required=False)
        if grid is not None:
            need(grid['status'] == 'COMPLETE' and grid['fixed_decoded_bytes_per_cell'] == BUDGET,
                 'primary-grid completion/scope differs')
            expected = {k for k, v in self.expected_pairs().items() if v['kind'] == 'main'}
            need({p['id'] for p in grid['pairs']} == expected and len(grid['pairs']) == 210,
                 'primary-grid does not contain exact 210-pair grid')
            for saved in grid['pairs']:
                pair = self.pairs.get(saved['id'])
                need(pair is not None and pair['result'] is not None, 'primary-grid references incomplete pair')
                spec = pair['spec']
                for key in ('piece', 'k', 'prefetch', 'pass_number'):
                    need(saved[key] == spec[key], 'primary-grid pair identity differs')
                need(self.saved_relative(saved['result']) == 'pairs/' + saved['id'] + '/result.json' and
                     saved['interruptions'] == pair['result']['interruptions'], 'primary-grid result binding differs')
        configurations = []
        for k in KS:
            for pf in (0, 1):
                selected = [r for r in rows if r['k'] == k and r['prefetch'] == pf]
                config = dict(k=k, prefetch=pf, status='PENDING')
                if self.inputs and all(r['status'] == 'COMPLETE' for r in selected):
                    product = Fraction(1)
                    for row in selected:
                        product *= fraction(row['phase_speedup'])
                    minimum = min(fraction(r['phase_speedup']) for r in selected)
                    config.update(status='COMPLETE', ratio_product=exact(product),
                        geometric_mean_display=geometric_presentation(product),
                        minimum_piece_speedup=exact(minimum),
                        reference_packet_bytes=sum(r['reference_packet_bytes'] for r in selected),
                        own_packet_bytes=sum(r['own_packet_bytes'] for r in selected),
                        reference_aggregate_MBps=exact(Fraction(7 * BUDGET * 1000,
                            sum(r['reference_median_ns'] for r in selected))),
                        own_aggregate_MBps=exact(Fraction(7 * BUDGET * 1000,
                            sum(r['own_median_ns'] for r in selected))),
                        original_volume_bytes=sum(self.inputs[p]['bytes'] for p in PIECES),
                        reference_original_volume_MBps=exact(Fraction(
                            sum(self.inputs[p]['bytes'] for p in PIECES) * 1000,
                            sum((Fraction(r['reference_median_ns'], r['repeats'])
                                 for r in selected), Fraction(0)))),
                        own_original_volume_MBps=exact(Fraction(
                            sum(self.inputs[p]['bytes'] for p in PIECES) * 1000,
                            sum((Fraction(r['own_median_ns'], r['repeats'])
                                 for r in selected), Fraction(0)))),
                        h21_threshold_pass=product >= Fraction(3, 2)**7 and minimum >= Fraction(19, 20))
                configurations.append(config)
        counts = self.counts()
        complete = (status['status'] == 'COMPLETE' and grid is not None and not self.missing and
                    cloud['status'] == controls['known_answer']['status'] == controls['aa']['status'] == 'PASS' and
                    all(c['status'] == 'COMPLETE' for c in configurations) and
                    counts['statuses']['ERROR'] == 0 and not self.interrupted_attempts)
        selected = None
        if complete:
            selected = min(configurations, key=lambda c: (-fraction(c['ratio_product']),
                c['own_packet_bytes'], c['k'], c['prefetch']))
        return dict(schema='crown2-h21-saved-analysis-v1', status='COMPLETE' if complete else 'PENDING',
                    identity=identity, host_run_status=status, cloud=cloud, method_controls=controls,
                    rows=rows, configurations=configurations, selected=selected,
                    h21_verdict=('HIT' if selected['h21_threshold_pass'] else 'MISS') if selected else 'PENDING',
                    h22='NOT RUN', h23='NOT RUN', crown='NOT ESTABLISHED', attempts=counts,
                    missing_evidence=self.missing, source_inventory=self.sources,
                    selection_rule='exact product of seven ratios of three-pass lane medians; '
                                   'ties: fewer complete packet bytes, lower K, prefetch off',
                    threshold=dict(ratio_product_at_least=exact(Fraction(3, 2)**7),
                                   every_piece_at_least=exact(Fraction(19, 20))),
                    caveat='Packets contain uncompressed BWT plus all side information. '
                           'Inverse-phase MB/s is not complete-codec decompression MB/s.',
                    aggregate_definitions=dict(
                        fixed_batch='7*64MiB / sum(seven lane median batch times)',
                        original_volume='41,943,040B / sum(seven median batch times / per-piece repeats)',
                        selection='Neither aggregate changes the equal-piece geometric-mean selection.'))


def csv_text(rows):
    fields = ['piece', 'k', 'prefetch', 'status', 'reference_packet_bytes', 'own_packet_bytes',
              'reference_median_ns_64MiB', 'own_median_ns_64MiB', 'reference_MBps', 'own_MBps',
              'phase_speedup', 'own_table_us_per_piece', 'own_walk_us_per_piece',
              'speedup_numerator', 'speedup_denominator', 'reference_pass_ns', 'own_pass_ns']
    stream = io.StringIO(newline='')
    writer = csv.DictWriter(stream, fields)
    writer.writeheader()
    for r in rows:
        out = {k: r[k] for k in ('piece', 'k', 'prefetch', 'status')}
        if r['status'] == 'COMPLETE':
            out.update(reference_packet_bytes=r['reference_packet_bytes'], own_packet_bytes=r['own_packet_bytes'],
                reference_median_ns_64MiB=r['reference_median_ns'], own_median_ns_64MiB=r['own_median_ns'],
                reference_MBps=presentation(fraction(r['reference_MBps'])), own_MBps=presentation(fraction(r['own_MBps'])),
                phase_speedup=presentation(fraction(r['phase_speedup']), 9),
                own_table_us_per_piece=presentation(fraction(r['own_table_us'])),
                own_walk_us_per_piece=presentation(fraction(r['own_walk_us'])),
                speedup_numerator=r['phase_speedup']['numerator'], speedup_denominator=r['phase_speedup']['denominator'],
                reference_pass_ns=';'.join(str(p['reference']['inverse_ns']) for p in r['passes']),
                own_pass_ns=';'.join(str(p['own']['inverse_ns']) for p in r['passes']))
        writer.writerow(out)
    return stream.getvalue()


def markdown(result):
    lines = [SIGNATURE, '', '# CROWN-2 H2.1 saved-data report', '',
             '| Scope | Status |', '|---|---|',
             '| Saved-data audit | ' + result['status'] + ' |',
             '| H2.1 inverse BWT | ' + result['h21_verdict'] + ' |',
             '| H2.2 entropy | NOT RUN |', '| H2.3 block/chain tuning | NOT RUN |',
             '| Whole-codec crown | NOT ESTABLISHED |', '',
             'Measured scope: ace-core EPYC 4344P, one pinned CPU, RAM inputs; complete inverse phase. '
             'BWT packet bytes include the container and side indices, but contain an **uncompressed** BWT. '
             'These are neither final compressed-archive bytes nor whole-codec speeds.', '',
             'Selection uses exact fractions before rounding: product of the seven ratios of '
             'three-pass reference/candidate lane medians. Threshold: product ≥ (3/2)^7 and '
             'every piece ≥ 0.95. Exact ties use total packet bytes, then K, then prefetch off.', '']
    if result.get('error'):
        lines += ['Evidence error: `' + result['error'].replace('`', "'") + '`.', '']
    controls = result.get('method_controls', {})
    if controls:
        lines += ['Method gates: cloud ' + result.get('cloud', {}).get('status', 'PENDING') +
                  '; known-answer ' + controls['known_answer']['status'] +
                  '; A/A ' + controls['aa']['status'] + '.', '']
        if controls['known_answer']['status'] == 'PASS':
            for trial in controls['known_answer']['trials']:
                lines += ['Known-answer trial %d: %d B; median %s MB/s; accepted=%s.' % (
                    trial['trial'], trial['archive_bytes'], presentation(fraction(trial['median_MBps'])),
                    str(trial['accepted']).lower()), '']
        if controls['aa']['status'] == 'PASS':
            largest = max(fraction(r['relative_difference']) for r in controls['aa']['pieces'])
            lines += ['Maximum A/A relative difference: ' + presentation(largest * 100) + '%.', '']
    configs = result.get('configurations', [])
    if configs:
        lines += ['| K | Prefetch | BWT packet B: own / bsc | Fixed-batch MB/s: own / bsc | '
                  'Geometric phase ratio | Minimum piece ratio |',
                  '|---:|---:|---:|---:|---:|---:|']
        for c in configs:
            if c['status'] != 'COMPLETE':
                lines.append('| %d | %d | PENDING | PENDING | PENDING | PENDING |' % (c['k'], c['prefetch']))
                continue
            lines.append('| %d | %d | %d / %d | %s / %s | %s | %s |' % (
                c['k'], c['prefetch'], c['own_packet_bytes'], c['reference_packet_bytes'],
                presentation(fraction(c['own_aggregate_MBps'])),
                presentation(fraction(c['reference_aggregate_MBps'])), c['geometric_mean_display'],
                presentation(fraction(c['minimum_piece_speedup']))))
        lines += ['', 'Aggregate MB/s = (7 × 64 MiB) / sum of the seven lane median times. '
                  'All 70 piece/configuration rows and native pass times are in `TABLE.csv`.', '']
        lines += ['| K | Prefetch | Original DEV-2 volume MB/s: own / bsc |',
                  '|---:|---:|---:|']
        for c in configs:
            if c['status'] != 'COMPLETE':
                lines.append('| %d | %d | PENDING |' % (c['k'], c['prefetch']))
            else:
                lines.append('| %d | %d | %s / %s |' % (c['k'], c['prefetch'],
                    presentation(fraction(c['own_original_volume_MBps'])),
                    presentation(fraction(c['reference_original_volume_MBps']))))
        lines += ['', 'Original-volume aggregate = 41,943,040 B / sum of the seven median '
                  'batch times divided by their repeat counts. This retains the original '
                  '8/4 MiB piece weights. Neither aggregate changes primary equal-piece '
                  'geometric-mean selection.', '']
    best = result.get('selected')
    if best is not None:
        lines += ['Selected K=%d, prefetch=%d. H2.1 forecast: Claude 55%%, ChatGPT 20%%; '
                  'fact: geometric ratio %s, minimum piece %s, **%s**.' % (
                      best['k'], best['prefetch'], best['geometric_mean_display'],
                      presentation(fraction(best['minimum_piece_speedup'])), result['h21_verdict']), '',
                  '| Piece | BWT packet B: own / bsc | MB/s: own / bsc | Phase ratio | '
                  'Own table / walk µs per piece |', '|---|---:|---:|---:|---:|']
        for r in result['rows']:
            if (r['k'], r['prefetch']) != (best['k'], best['prefetch']):
                continue
            lines.append('| %s | %d / %d | %s / %s | %s | %s / %s |' % (
                r['piece'], r['own_packet_bytes'], r['reference_packet_bytes'],
                presentation(fraction(r['own_MBps'])), presentation(fraction(r['reference_MBps'])),
                presentation(fraction(r['phase_speedup'])), presentation(fraction(r['own_table_us'])),
                presentation(fraction(r['own_walk_us']))))
        lines += ['', 'Own table/walk subdivisions are diagnostic medians normalized by each '
                  'cell’s fixed repeat count. They are not compared with the complete bsc phase.', '']
    else:
        lines += ['No configuration is finally selected while evidence or method gates are incomplete. '
                  'H2.1 remains PENDING; partial rows do not change its forecast.', '']
    counts = result.get('attempts', {})
    if counts:
        lines += ['Attempts: %d timed commands; %d receipted attempts; CLEAN %d, LOADED %d, '
                  'WAITING %d, ERROR %d. %d cells had timed retakes; %d timed repetitions '
                  'were retaken. %d pair interruptions across %d pairs; %d admission-wait '
                  'observations. %d attempt folders lack final receipts.' % (
                      counts['timed_attempts'], counts['receipted_attempts'],
                      *(counts['statuses'][s] for s in ('CLEAN', 'LOADED', 'WAITING', 'ERROR')),
                      counts['retaken_timed_cells'], counts['retaken_loaded_attempts'],
                      counts['interrupted_pair_events'], counts['interrupted_pairs'],
                      counts['admission_wait_observations'], len(counts['unreceipted_attempts'])), '',
                  'Every LOADED/WAITING/ERROR record is retained and counted. ERROR is never '
                  'reinterpreted as load or accepted data. Per-cell counts are in `analysis.json`.', '']
    identity = result.get('identity', {})
    if identity:
        lines += ['Source: harness `' + identity['harness_source_sha'] + '`, cloud `' +
                  identity['cloud_source_sha'] + '`, preregistration `' + identity['preregistration_commit'] + '`.',
                  'Source blob hashes, binary/input/packet hashes and the full saved-file SHA inventory '
                  'are in `analysis.json` and `SHA256SUMS.txt`.', '']
    if result.get('missing_evidence'):
        lines += ['Missing evidence: ' + ', '.join('`' + p + '`' for p in result['missing_evidence']) + '.', '']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    work, output = args.work.absolute(), args.output.absolute()
    need(work.is_dir() and work.resolve() == work, 'work must be an existing nonsymlink directory')
    need(not output.exists() and output != work, 'output must be a fresh report directory')
    audit = Audit(work)
    try:
        result = audit.run()
    except MissingEvidence as error:
        result = dict(schema='crown2-h21-saved-analysis-v1', status='PENDING', h21_verdict='PENDING',
                      h22='NOT RUN', h23='NOT RUN', crown='NOT ESTABLISHED', error=str(error),
                      missing_evidence=audit.missing, source_inventory=audit.sources,
                      rows=[], configurations=[], selected=None, attempts=audit.counts())
    except (InvalidEvidence, KeyError, TypeError, ValueError, ArithmeticError, OSError) as error:
        result = dict(schema='crown2-h21-saved-analysis-v1', status='ERROR', h21_verdict='PENDING',
                      h22='NOT RUN', h23='NOT RUN', crown='NOT ESTABLISHED', error=repr(error),
                      missing_evidence=audit.missing, source_inventory=audit.sources,
                      rows=[], configurations=[], selected=None, attempts=audit.counts())
    # Include all saved logs/receipts, including failed and interrupted commands,
    # without decoding a representation or starting any benchmark executable.
    try:
        for path in sorted(work.rglob('*')):
            if path.is_file():
                relative = path.relative_to(work).as_posix()
                previous = audit.inventory.get(relative)
                audit.read(relative)
                need(previous is None or previous == audit.inventory[relative],
                     'saved file changed during analysis: ' + relative)
        need(all(audit.path(p).is_file() for p in audit.inventory),
             'saved file disappeared during analysis')
    except (InvalidEvidence, OSError) as error:
        result.update(status='ERROR', h21_verdict='PENDING', selected=None,
                      rows=[], configurations=[], error=repr(error))
    result['saved_file_inventory'] = audit.inventory
    result['analyzer_sha256'] = digest_bytes(Path(__file__).read_bytes())
    output.mkdir(parents=True, exist_ok=False)
    (output / 'analysis.json').write_text(json.dumps(result, sort_keys=True, indent=2) + '\n', encoding='utf-8')
    (output / 'TABLE.csv').write_text(csv_text(result.get('rows', [])), encoding='utf-8', newline='')
    (output / 'RESULTS.md').write_text(markdown(result), encoding='utf-8')
    (output / 'SHA256SUMS.txt').write_text(''.join(
        rec['sha256'] + ' *' + path + '\n' for path, rec in sorted(audit.inventory.items())), encoding='utf-8')
    print(json.dumps(dict(status=result['status'], h21=result['h21_verdict'],
                         output=str(output), selected=result.get('selected')),
                     sort_keys=True))
    return 0 if result['status'] in ('COMPLETE', 'PENDING') else 1


if __name__ == '__main__':
    raise SystemExit(main())
