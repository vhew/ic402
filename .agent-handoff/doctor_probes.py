#!/usr/bin/env python3
"""[verified by execution] Hermetic broken-input probes; no real network/keys/deploy.
Fixtures are not evidence that the operator's machine is ready. Run doctor separately.
"""
import contextlib
import importlib.util
import io
import gzip
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('doctor', Path(__file__).with_name('doctor.py'))
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def put(path, value, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)
    if mode is not None:
        path.chmod(mode)


class Fixture:
    def __init__(self, base):
        self.base = base
        self.repo = base / 'repo'
        self.bin = base / 'bin'
        self.cache = base / 'cache'
        self.repo.mkdir()
        self.bin.mkdir()
        self.calls = []
        self.mutations = {}
        self.pnpm_home = ''
        self.der = b'test-fixture-public-DER-not-a-real-private-key'
        self.payer = d.public_key_principal(self.der)
        self.controller = d.public_key_principal(b'controller-DER')
        self.example = d.public_key_principal(b'example-principal-fixture')
        self.ledger = d.public_key_principal(b'ledger-principal-fixture')
        self.pkg = dict(engines={'node': '>=22.22.1'}, packageManager='pnpm@10.34.9',
                        devDependencies={'@icp-sdk/icp-cli': '1.7.0'})
        put(self.repo / 'package.json', json.dumps(self.pkg))
        put(self.repo / 'pnpm-workspace.yaml', 'packages:\n')
        lock = "lockfileVersion: '9.0'\nimporters:\n  .:\n    devDependencies:\n      '@icp-sdk/icp-cli':\n        specifier: 1.7.0\n        version: 1.7.0\n"
        put(self.repo / 'pnpm-lock.yaml', lock)
        put(self.repo / 'node_modules/.pnpm/lock.yaml', lock)
        put(self.repo / 'node_modules/@icp-sdk/icp-cli/package.json', '{"version":"1.7.0"}')
        put(self.repo / 'mops.toml', '[package]\nrepository="https://github.com/example/ic402"\n[dependencies]\ncore="1.0.0"\n[toolchain]\nmoc="2.1.0"\nwasmtime="50.0.0"\n')
        put(self.repo / 'mops.lock', json.dumps({'deps': {'core': '1.0.0', 'iterext': 'https://github.com/example/motoko-iterext#v2.0.0'}}))
        put(self.repo / '.mops/core@1.0.0/mops.toml', '[package]\nname="core"\nversion="1.0.0"\n')
        put(self.repo / '.mops/core@1.0.0/src/lib.mo', 'module {};\n')
        put(self.repo / '.mops/_github/iterext#v2.0.0/src/lib.mo', 'module {};\n')
        put(self.repo / '.github/workflows/ci.yml', '  mops-version: 3.5.1\n  run: npm install -g @icp-sdk/icp-cli@1.7.0\n')
        put(self.repo / '.github/workflows/release.yml', '  mops-version: 3.5.1\nid-token: write\nenvironment: release\nMOPS_IDENTITY_PEM\nnpm publish\nmops publish\n')
        for path in ('packages/client/package.json', 'integrations/mcp/package.json', 'example/client/package.json'):
            put(self.repo / path, '{}')
        put(self.repo / 'scripts/fetch-binaryen.sh', 'BINARYEN_VERSION="version_130"\n')
        target = d.platform.system() + '/' + d.platform.machine()
        put(self.repo / 'scripts/check-candid-mirrors.sh', 'DIDC_TAG="didc-v0.6.2"\n' + target + ')\nDIDC_TARGET="fixture-target"\n')
        for name in ('node', 'pnpm', 'icp', 'mops', 'moc', 'wasmtime', 'openssl', 'gh', 'git'):
            put(self.bin / name, '#!/bin/sh\nexit 0\n', 0o700)
        for name, pin in [('moc', '2.1.0'), ('wasmtime', '50.0.0')]:
            put(self.cache / 'mops' / name / pin / name, '#!/bin/sh\n', 0o700)
        put(self.repo / '.icp/tools/binaryen-version_130/bin/wasm-opt', '#!/bin/sh\n', 0o700)
        put(self.cache / 'ic402/didc-v0.6.2/fixture-target/didc', '#!/bin/sh\n', 0o700)
        put(self.repo / '.icp/fixture.wasm', 'fixture artifact')
        sha = d.hashlib.sha256(b'fixture artifact').hexdigest()
        put(self.repo / 'scripts/prebuilt.sha256', sha + ' fixture.wasm\n')
        put(self.repo / 'scripts/predemo.sh', 'amount = 100_000_000 : nat; fee = null; memo = null\n')
        put(self.repo / '.env.development', 'EXAMPLE=value\n', 0o600)
        put(self.repo / '.local/test-payer.pem', 'not-a-key: fixture runner returns public DER only', 0o600)
        self.profile = self.repo / 'doctor-target.json'
        put(self.profile, json.dumps(dict(environment='ic', identity='controller', principal=self.controller,
                                         canisters={'example': self.example}, authority='fixture source only', env_files=['.env.development'])))
        self.committed_profile = self.profile.read_bytes()
        zk = self.repo / 'example/zk-verifier/prebuilt/zk_verifier.wasm.gz'
        zk.parent.mkdir(parents=True, exist_ok=True)
        zk.write_bytes(gzip.compress(b'\x00asm\x01\x00\x00\x00'))
        put(self.repo / 'icp.yaml', 'canisters:\n  - name: zk_verifier\n    path: example/zk-verifier/prebuilt/zk_verifier.wasm.gz\nenvironments:\n  - name: ic\n    network: mainnet\n    canisters: [example]\n')

    def run(self, args, binary=False):
        self.calls.append(args)
        tool = Path(args[0]).name
        full = (tool, *args[1:])
        if full in self.mutations:
            value = self.mutations[full]
            if isinstance(value, Exception):
                raise value
            return value
        if tool == 'git':
            if args[1] == 'show':
                return self.committed_profile
            if args[1:3] == ['ls-files', '--error-unmatch']:
                return args[-1]
            if args[1:] == ['config', '--name-only', '--list']:
                return ''
            if args[1:3] == ['config', '--get-regexp']:
                return ''
        if args[1:] == ['--version']:
            return {'node': 'v22.22.1', 'pnpm': '10.34.9', 'icp': 'icp-cli 1.7.0', 'mops': 'CLI 3.5.1',
                    'moc': 'Motoko 2.1.0', 'wasmtime': 'wasmtime 50.0.0', 'wasm-opt': 'wasm-opt version 130',
                    'didc': 'didc 0.6.2'}[tool]
        if full[:3] == ('icp', 'identity', 'principal'):
            return self.payer if args[-1] == 'test-payer' else self.controller
        if tool == 'openssl':
            return self.der
        if full[:3] == ('icp', 'canister', 'status'):
            if args[-1] == '--id-only':
                return self.example if args[3] == 'example' else self.ledger
            who = self.payer if 'local' in args else self.controller
            return json.dumps({'canister_id': self.example, 'controllers': [who], 'cycles': '1000000000000'})
        if full[:3] == ('icp', 'canister', 'call'):
            if args[4] == 'icrc1_minting_account':
                return '(opt record { owner = principal "' + self.controller + '"; subaccount = null })'
            if args[4] == 'icrc1_balance_of':
                return '(100_000_000 : nat)'
        if tool == 'gh':
            return '1234' if args[2] == 'user' else 'true'
        raise AssertionError('Unanticipated command: ' + repr(args))

    def execute(self, level):
        with patch.dict(os.environ, {'PATH': str(self.bin), 'XDG_CACHE_HOME': str(self.cache), 'PNPM_HOME': self.pnpm_home}):
            instance = d.Doctor(self.repo, level, self.profile, self)
            return {row['id']: row for row in instance.execute()}


def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix='ic402-doctor-probes-') as tmp:
        base = Path(tmp)
        def fresh():
            folder = base / str(len(list(base.iterdir())))
            folder.mkdir()
            return Fixture(folder)
        control = fresh()
        known = set()
        for level in ('tools', 'integration', 'deploy', 'release'):
            rows = control.execute(level)
            failed = [row for row in rows.values() if row['status'] == 'FAIL']
            assert [row['id'] for row in failed] == (['release-runtime'] if level == 'release' else []), (level, failed)
            known.update(rows)
        def probe(ident, level, mutate, label=None):
            f = fresh()
            mutate(f)
            row = f.execute(level)[ident]
            assert row['status'] == 'FAIL' and row['fix'], (ident, row)
            checks.append(ident)
            print('PASS mutation: ' + (label or ident) + ' -> ✗ with fix')
        def response(f, args, value):
            f.mutations[tuple(args)] = value
        fail = d.Unchecked('could not check: fixture API rejected login')
        probe('repo-pins', 'tools', lambda f: put(f.repo / 'package.json', '{'))
        for tool in ('node', 'pnpm', 'icp', 'mops'):
            probe(tool, 'tools', lambda f, tool=tool: response(f, [tool, '--version'], '0.0.1'))
        probe('icp', 'tools', lambda f: response(f, ['icp', '--version'], 'icp 1.7.0-beta.1'), 'prerelease does not satisfy stable pin')
        def foreign(f):
            fake = f.base / 'other/node_modules/.bin'
            put(fake / 'icp', '#!/bin/sh\n', 0o700)
            (f.bin / 'icp').unlink()
            # Exact PATH lookup path matters; patch fixture bin pathname to foreign tree plus existing bin.
            f.bin = Path(str(fake) + ':' + str(f.bin))
        probe('path', 'tools', foreign, 'foreign PATH shadow')
        pnpm_control = fresh()
        foreign(pnpm_control)
        pnpm_control.pnpm_home = str(pnpm_control.bin).split(':')[0]
        assert pnpm_control.execute('tools')['path']['status'] == 'PASS'
        print('PASS control: explicit PNPM_HOME is retained like scripts/lib/toolchain-path.sh')
        probe('dependencies', 'tools', lambda f: put(f.repo / 'node_modules/@icp-sdk/icp-cli/package.json', '{"version":"0.0.0"}'))
        probe('dependencies', 'tools', lambda f: put(f.repo / 'node_modules/.pnpm/lock.yaml', 'stale'), 'stale installed lockfile')
        probe('mops-dependencies', 'tools', lambda f: (f.repo / '.mops/core@1.0.0/mops.toml').unlink())
        probe('mops-dependencies', 'tools', lambda f: (f.repo / '.mops/core@1.0.0/src/lib.mo').unlink(), 'registry package manifest without source')
        probe('mops-dependencies', 'tools', lambda f: put(f.repo / '.mops/core@1.0.0/mops.toml', '[package]\nversion="0.0.0"\n'), 'installed mops version differs from lock')
        probe('mops-dependencies', 'tools', lambda f: (f.repo / '.mops/_github/iterext#v2.0.0/src/lib.mo').unlink(), 'empty Git dependency')
        for tool in ('moc', 'wasmtime'):
            probe(tool, 'tools', lambda f, tool=tool: response(f, [tool, '--version'], '0.0.1'))
        probe('binaryen', 'tools', lambda f: response(f, ['wasm-opt', '--version'], 'wasm-opt version 0'))
        probe('didc', 'tools', lambda f: (f.cache / 'ic402/didc-v0.6.2/fixture-target/didc').unlink())
        probe('prebuilt', 'tools', lambda f: put(f.repo / '.icp/fixture.wasm', 'corrupt'))
        probe('prebuilt', 'tools', lambda f: (f.repo / 'example/zk-verifier/prebuilt/zk_verifier.wasm.gz').unlink(), 'zk prebuilt missing before Rust fallback')
        def browser(f):
            f.pkg['devDependencies']['@playwright/test'] = '1.0.0'
            put(f.repo / 'package.json', json.dumps(f.pkg))
        probe('browsers', 'tools', browser)
        probe('env', 'tools', lambda f: (f.repo / '.env.development').chmod(0o644))
        probe('env', 'deploy', lambda f: (f.repo / '.env.development').unlink(), 'required env missing')
        probe('env', 'tools', lambda f: put(f.repo / '.env.development', 'touch /tmp/DO-NOT-EXECUTE\n', 0o600), 'env never sourced')
        probe('payer-key', 'integration', lambda f: response(f, ['icp', 'identity', 'principal', '--identity', 'test-payer'], f.controller))
        probe('payer-key', 'integration', lambda f: (f.repo / '.local/test-payer.pem').chmod(0o644), 'unsafe key permissions')
        probe('local-links', 'integration', lambda f: response(f, ['icp', 'canister', 'status', 'example', '-e', 'local', '--id-only'], fail))
        probe('local-signing', 'integration', lambda f: response(f, ['icp', 'canister', 'status', 'example', '-e', 'local', '--identity', 'test-payer', '--json'], '{"public":true}'))
        probe('minter', 'integration', lambda f: response(f, ['icp', 'canister', 'call', 'ckusdc_ledger', 'icrc1_minting_account', '()', '-e', 'local', '--query', '--identity', 'local-dev'], '(null)'))
        probe('minter', 'integration', lambda f: response(f, ['icp', 'canister', 'call', 'ckusdc_ledger', 'icrc1_minting_account', '()', '-e', 'local', '--query', '--identity', 'local-dev'], '(opt record { owner = principal "' + f.controller + '"; subaccount = opt blob "nonzero" })'), 'same minter owner with non-default subaccount')
        def funds(f, output):
            response(f, ['icp', 'canister', 'call', 'ckusdc_ledger', 'icrc1_balance_of', '(record { owner = principal "' + f.payer + '"; subaccount = null })', '-e', 'local', '--query', '--identity', 'local-dev'], output)
        probe('funding', 'integration', lambda f: funds(f, '(0 : nat)'))
        probe('funding', 'integration', lambda f: funds(f, '(variant { Err = "not funded" })'), 'exit-zero error response')
        probe('deploy-profile', 'deploy', lambda f: put(f.profile, '{}'))
        probe('deploy-link', 'deploy', lambda f: response(f, ['icp', 'canister', 'status', 'example', '-e', 'ic', '--id-only'], f.ledger))
        probe('deploy-identity', 'deploy', lambda f: response(f, ['icp', 'identity', 'principal', '--identity', 'controller'], f.payer))
        probe('deploy-status', 'deploy', lambda f: response(f, ['icp', 'canister', 'status', 'example', '-e', 'ic', '--identity', 'controller', '--json'], fail))
        probe('gh-auth', 'release', lambda f: response(f, ['gh', 'api', 'user', '--jq', '.id'], fail), 'dead login despite saved configuration')
        probe('release-config', 'release', lambda f: put(f.repo / '.github/workflows/release.yml', '  mops-version: 3.5.1\n'))
        probe('release-secret', 'release', lambda f: response(f, ['gh', 'api', 'repos/example/ic402/environments/release/secrets', '--jq', 'any(.secrets[]; .name == "MOPS_IDENTITY_PEM")'], 'false'))
        def signing(f):
            response(f, ['git', 'config', '--name-only', '--list'], 'tag.gpgsign')
            response(f, ['git', 'config', '--bool', '--get', 'tag.gpgsign'], 'true')
        probe('signing', 'release', signing, 'explicit or valueless true signing requires owner terminal')
        def invalid_signing(f):
            signing(f)
            response(f, ['git', 'config', '--bool', '--get', 'tag.gpgsign'], fail)
        probe('signing', 'release', invalid_signing, 'invalid signing boolean is uncheckable')
        probe('release-runtime', 'release', lambda f: None, 'unavailable CI-held publish credentials remain uncheckable')
        probe('deploy-profile', 'deploy', lambda f: put(f.profile, f.profile.read_text().replace('fixture source only', 'uncommitted change')), 'dirty profile remains rejected')
        def changed_manifest(f):
            f.pkg['devDependencies']['@icp-sdk/icp-cli'] = '1.7.1'
            put(f.repo / 'package.json', json.dumps(f.pkg))
        probe('dependencies', 'tools', changed_manifest, 'manifest changed without lockfile')
        def symlink_key(f):
            source = f.repo / '.local'
            source.rename(f.repo / 'deploy')
            source.symlink_to('deploy')
        probe('payer-key', 'integration', symlink_key, 'parent symlink into deploy rejected before key read')
        bad_tool = fresh()
        bad_tool.mutations[('icp', '--version')] = 'icp 0.0.0'
        bad_tool.execute('integration')
        assert not any(Path(call[0]).name == 'icp' and call[1:] != ['--version'] for call in bad_tool.calls), 'wrong-version icp was used for API probes'
        print('PASS dependency guard: mismatched icp is never used for identity/API checks')
        assert known <= set(checks), ('unprobed checks', known - set(checks))
        env_runner = d.Runner(base)
        for inherited in ('1', '0'):
            with patch.dict(os.environ, {'COREPACK_ENABLE_NETWORK': inherited, 'COREPACK_ENABLE_AUTO_PIN': inherited}):
                corepack_guard = env_runner.run([sys.executable, '-c', 'import os; print(os.environ["COREPACK_ENABLE_NETWORK"] + os.environ["COREPACK_ENABLE_AUTO_PIN"])'])
                assert corepack_guard == '00', 'version probes could bootstrap Corepack downloads or auto-pin manifests'
        print('PASS read-only guard: Corepack network and auto-pin disabled regardless of inherited settings')
        # Real process deadline test: timeout is failure and descendant process group is killed.
        runner = d.Runner(base, budget=1, timeout=0.1)
        started = time.monotonic()
        try:
            runner.run([sys.executable, '-c', 'import time; time.sleep(10)'])
            raise AssertionError('timeout falsely passed')
        except d.Unchecked as error:
            assert 'timed out' in str(error)
        assert time.monotonic() - started < 2
        print('PASS mutation: hanging real subprocess -> could not check')
        helper = Path(__file__).with_name('handoff.sh')
        for shell in ('bash', 'zsh'):
            binary = shutil.which(shell)
            assert binary, 'required caller shell unavailable: ' + shell
            # CLI unknown/missing repo must fail, never produce a false ready result.
            result = subprocess.run([binary, str(helper), 'doctor', '--repo', str(base / 'missing'), '--json'],
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
            parsed = json.loads(result.stdout)
            assert result.returncode != 0 and parsed['verdict'] == 'NOT READY'
            print('PASS shell: ' + shell + ' wrapper fails closed with missing repo')
            for missing in (True, False):
                runtime_bin = base / ('missing-python-' + shell if missing else 'old-python-' + shell)
                runtime_bin.mkdir()
                if not missing:
                    put(runtime_bin / 'python3', '#!/bin/sh\nexit 1\n', 0o700)
                result = subprocess.run([binary, str(helper), 'doctor', '--repo', str(control.repo)],
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=5,
                                        env=dict(os.environ, PATH=str(runtime_bin)))
                assert result.returncode != 0 and b'helper-runtime' in result.stderr and b'Fix:' in result.stderr
            print('PASS shell: ' + shell + ' unavailable/old Python fail with fixes')
        print(f'{len(checks)} broken-input probes cover all {len(known)} check IDs; three full fixture level controls pass; release control explicitly fails on CI-only runtime check; subprocess deadline and bash/zsh wrappers pass.')
        print('Fixture controls are not a green result for the real machine. Run doctor in each agent shell.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
