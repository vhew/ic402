#!/usr/bin/env python3
"""[approved 2026-11-08] Fail-closed, read-only checks for the implementation checkout.
[assumed] Python >=3.11 is the helper runtime, not a product toolchain requirement.
No shell evaluation, installs, key export, deploy/, writes, or interactive prompts.
"""
import argparse
import base64
import hashlib
import gzip
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import tomllib
import zlib


class Unchecked(Exception):
    """Safe, authored diagnostic. Never include raw subprocess/secret output."""


def need(condition, message):
    if not condition:
        raise Unchecked(message)


def version(value):
    match = re.search(r'(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)', value)
    need(match is not None, 'could not parse semantic version')
    need(re.match(r'-[0-9A-Za-z]', value[match.end():]) is None, 'prerelease version does not satisfy the stable repository pin')
    return tuple(map(int, match.groups()))


def text(path):
    return Path(path).read_text()


def secure_file(path, root=None):
    p = Path(path)
    resolved = p.resolve()
    if root is not None:
        root = Path(root).resolve()
        need(resolved.is_relative_to(root) and 'deploy' not in resolved.relative_to(root).parts,
             'file resolves outside allowed checkout or into forbidden deploy/')
    need(p.is_file() and not p.is_symlink(), 'required regular file missing (or is a symlink)')
    mode = p.stat().st_mode
    need(not mode & 0o077, 'file is readable/writable by group or others; use mode 0600')
    need(p.stat().st_uid == os.getuid(), 'file is not owned by the current user')
    return p


def principal(raw):
    compact = raw.strip().replace('-', '').upper()
    try:
        decoded = base64.b32decode(compact + '=' * (-len(compact) % 8))
    except Exception:
        raise Unchecked('could not parse principal') from None
    need(5 <= len(decoded) <= 33, 'invalid principal length')
    need(decoded[:4] == zlib.crc32(decoded[4:]).to_bytes(4, 'big'), 'invalid principal checksum')
    need(raw.strip() != '2vxsx-fae', 'anonymous identity is not ready')
    return raw.strip()


def public_key_principal(der):
    body = hashlib.sha224(der).digest() + b'\x02'
    encoded = base64.b32encode(zlib.crc32(body).to_bytes(4, 'big') + body).decode().lower().rstrip('=')
    return '-'.join(encoded[i:i + 5] for i in range(0, len(encoded), 5))


class Runner:
    def __init__(self, repo, budget=55, timeout=6):
        self.repo = repo
        self.deadline = time.monotonic() + budget
        self.timeout = timeout

    def run(self, args, binary=False):
        remaining = self.deadline - time.monotonic()
        need(remaining > 0, 'could not check: doctor time budget exhausted')
        env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GH_PROMPT_DISABLED='1', CI='true',
                   COREPACK_ENABLE_NETWORK='0', COREPACK_ENABLE_AUTO_PIN='0')
        # Do not silently change PATH or honor inherited ICP network/project overrides.
        for key in ('ICP_NETWORK', 'ICP_ENVIRONMENT', 'ICP_PROJECT_ROOT'):
            env.pop(key, None)
        try:
            process = subprocess.Popen(args, cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                out, _ = process.communicate(timeout=min(remaining, self.timeout))
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                raise Unchecked('could not check: command timed out; prompts are disabled') from None
        except OSError:
            raise Unchecked('could not check: command missing or could not start') from None
        need(process.returncode == 0, 'could not check: command failed (output suppressed)')
        return out if binary else out.decode('utf-8', errors='strict').strip()


class Doctor:
    def __init__(self, repo, level='tools', profile=None, runner=None):
        self.repo = Path(repo).resolve()
        self.level = level
        self.profile = profile
        self.runner = runner or Runner(self.repo)
        self.rows = []
        self.pins = {}
        self.cache = {}

    def run(self, args, **kw):
        return self.runner.run(args, **kw)

    def check(self, ident, fix, fn):
        try:
            prerequisites = {
                'node': ['repo-pins'], 'pnpm': ['repo-pins'], 'icp': ['repo-pins'], 'mops': ['repo-pins'],
                'payer-key': ['icp', 'path'], 'local-links': ['icp', 'path'],
                'local-signing': ['payer-key', 'local-links'], 'minter': ['local-links'],
                'funding': ['payer-key', 'local-links', 'minter'],
                'deploy-link': ['deploy-profile', 'icp', 'path'],
                'deploy-identity': ['deploy-profile', 'icp', 'path'],
                'deploy-status': ['deploy-link', 'deploy-identity'],
                'release-secret': ['gh-auth', 'release-config'],
            }.get(ident, [])
            verdicts = {row['id']: row['status'] for row in self.rows}
            need(all(verdicts.get(item) == 'PASS' for item in prerequisites),
                 'could not check: prerequisite failed: ' + ', '.join(item for item in prerequisites if verdicts.get(item) != 'PASS'))
            detail = fn()
            status = 'NA' if str(detail).startswith('N/A:') else 'PASS'
        except Unchecked as error:
            status, detail = 'FAIL', str(error)
        except Exception:
            status, detail = 'FAIL', 'could not check: absent/malformed input (details suppressed)'
        self.rows.append(dict(id=ident, status=status, detail=detail, fix=fix if status == 'FAIL' else ''))

    def load_pins(self):
        pkg = json.loads(text(self.repo / 'package.json'))
        mops = tomllib.loads(text(self.repo / 'mops.toml'))
        ci = text(self.repo / '.github/workflows/ci.yml')
        release = text(self.repo / '.github/workflows/release.yml')
        npm = pkg['packageManager'].split('@')
        need(npm[0] == 'pnpm' and len(npm) == 2, 'packageManager is not an exact pnpm pin')
        minimum = re.fullmatch(r'>=(\d+\.\d+\.\d+)', pkg['engines']['node'])
        need(minimum is not None, 'unsupported Node constraint; update doctor parser rather than guess')
        mops_pins = set(re.findall(r'^\s+mops-version:\s*[\'"]?(\d+\.\d+\.\d+)', ci + '\n' + release, re.M))
        icp_pins = set(re.findall(r'npm install -g @icp-sdk/icp-cli@(\d+\.\d+\.\d+)', ci))
        need(len(mops_pins) == 1, 'CI/release mops pins absent or inconsistent')
        need(icp_pins == {pkg['devDependencies']['@icp-sdk/icp-cli']}, 'CI/package icp pins disagree')
        need(set(mops['toolchain']) == {'moc', 'wasmtime'}, 'toolchain set changed; add explicit readiness checks for new tools')
        self.pins = dict(node=minimum.group(1), pnpm=npm[1], icp=next(iter(icp_pins)),
                         mops=next(iter(mops_pins)), **mops['toolchain'])
        self.cache.update(pkg=pkg, mops=mops, ci=ci, release=release)
        for pin in self.pins.values():
            version(pin)
        return 'pins parsed from package.json, mops.toml and CI/release workflows'

    def check_tool(self, name):
        expected = self.pins[name]
        binary = shutil.which(name)
        need(binary is not None, 'binary not found on PATH')
        try:
            actual = version(self.run([binary, '--version']))
        except Unchecked as error:
            raise Unchecked(str(error) + '; first on PATH: ' + binary) from None
        need(actual >= version(expected) if name == 'node' else actual == version(expected),
             f'{name} version does not meet repository pin {expected}; first on PATH: {binary}')
        return f'{name} {".".join(map(str, actual))}; first on PATH: {binary}'

    def check_path(self):
        foreign = []
        for name in ('node', 'pnpm', 'icp', 'mops'):
            resolved = shutil.which(name)
            need(resolved is not None, f'{name} missing from PATH')
            path = Path(resolved)
            # Do not resolve symlinks: .bin is the shadowing path the shell selects.
            pnpm_home = os.environ.get('PNPM_HOME')
            allowed_pnpm_home = bool(pnpm_home) and path.parent.absolute() == Path(pnpm_home).absolute()
            if '/node_modules/.bin/' in str(path) and not path.is_relative_to(self.repo) and not allowed_pnpm_home:
                foreign.append(name)
        need(not foreign, 'foreign node_modules/.bin shadows: ' + ', '.join(foreign))
        return 'first PATH binaries use project/global locations or the explicit PNPM_HOME exception from toolchain-path.sh'

    def dependencies(self):
        wanted = text(self.repo / 'pnpm-lock.yaml')
        installed = text(self.repo / 'node_modules/.pnpm/lock.yaml')
        need(wanted == installed, 'installed pnpm lock snapshot differs from repository lockfile')
        # Only the narrow importer subset is consumed; unknown shapes fail closed.
        importer = dep = None
        locked = {}
        specifiers = {}
        for line in wanted.splitlines():
            m = re.match(r'^  ([^ ].*):$', line)
            if m:
                importer = m.group(1).strip("'\"")
            m = re.match(r'^      ([^ ].*):$', line)
            if m:
                dep = m.group(1).strip("'\"")
            m = re.match(r'^        specifier: (.+)$', line)
            if m and importer and dep:
                specifiers[(importer, dep)] = m.group(1).strip("'\"")
            m = re.match(r'^        version: (.+)$', line)
            if m and importer and dep:
                locked[(importer, dep)] = m.group(1).strip("'\"").split('(')[0]
        need(locked, 'could not parse pnpm lockfile importers')
        workspace = text(self.repo / 'pnpm-workspace.yaml')
        paths = [self.repo / 'package.json']
        for pattern in re.findall(r'^  - [\'\"]?([^\'\"\n]+)', workspace, re.M):
            paths += list(self.repo.glob(pattern + '/package.json'))
        checked = 0
        for manifest in paths:
            pkg = json.loads(text(manifest))
            importer = manifest.parent.relative_to(self.repo).as_posix()
            for group in ('dependencies', 'devDependencies'):
                for name in pkg.get(group, {}):
                    expected = locked[(importer, name)]
                    need(pkg[group][name] == specifiers[(importer, name)], 'manifest specifier differs from lockfile')
                    installed_pkg = json.loads(text(manifest.parent / 'node_modules' / name / 'package.json'))
                    if expected.startswith('link:'):
                        linked = (manifest.parent / expected.removeprefix('link:')).resolve()
                        need((manifest.parent / 'node_modules' / name).resolve() == linked,
                             'workspace dependency link points elsewhere')
                    else:
                        need(installed_pkg['version'] == expected, 'installed package version differs from lockfile')
                    checked += 1
        need(checked > 0, 'no dependency entries checked')
        return f'{checked} direct workspace dependencies and installed lock snapshot match'

    def mops_dependencies(self):
        lock = json.loads(text(self.repo / 'mops.lock'))
        need(isinstance(lock['deps'], dict) and lock['deps'], 'empty mops dependency lock')
        for name, pinned in lock['deps'].items():
            if pinned.startswith('https://github.com/'):
                url, ref = pinned.rsplit('#', 1)
                slug = url.rsplit('/', 1)[1].removeprefix('motoko-')
                target = self.repo / '.mops/_github' / (slug + '#' + ref)
            else:
                target = self.repo / '.mops' / (name.split('@')[0] + '@' + pinned)
            need(target.is_dir(), 'mops locked dependency directory missing')
            if pinned.startswith('https://github.com/'):
                need(any(target.rglob('*.mo')), 'mops Git dependency has no Motoko source')
            else:
                need((target / 'mops.toml').is_file(), 'mops locked dependency manifest missing')
                metadata = tomllib.loads(text(target / 'mops.toml'))['package']
                need(metadata.get('version') == pinned, 'installed mops package version differs from lockfile')
                source_dir = (target / metadata.get('baseDir', 'src')).resolve()
                need(source_dir.is_relative_to(target.resolve()) and any(source_dir.rglob('*.mo')),
                     'mops locked dependency has no source in its declared/default baseDir')
        for group in ('dependencies', 'dev-dependencies'):
            for name, pinned in self.cache['mops'].get(group, {}).items():
                need(lock['deps'].get(name) == pinned, 'mops.toml dependency and mops.lock disagree')
        return 'mops locked dependencies have matching manifests and Motoko sources; direct pins agree'

    def toolchain(self, name):
        # mops toolchain bin may download. Read the installed cache directly instead.
        # Layout verified against ic-mops dist/mops.js + commands/toolchain/index.js.
        base = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() /
                    ('Library/Caches' if platform.system() == 'Darwin' else '.cache')))) / 'mops'
        binary = base / name / self.pins[name] / name
        need(binary.is_file() and os.access(binary, os.X_OK), 'mops toolchain binary absent or non-executable')
        actual = version(self.run([str(binary), '--version']))
        need(actual == version(self.pins[name]), f'{name} does not match mops.toml')
        return f'{name} pin matches mops.toml; binary: {binary}'

    def binaryen(self):
        source = text(self.repo / 'scripts/fetch-binaryen.sh')
        match = re.search(r'^BINARYEN_VERSION="version_(\d+)"', source, re.M)
        need(match is not None, 'could not read binaryen pin')
        pin = match.group(1)
        binary = self.repo / '.icp/tools' / ('binaryen-version_' + pin) / 'bin/wasm-opt'
        need(binary.is_file() and os.access(binary, os.X_OK), 'pinned wasm-opt has not been downloaded')
        out = self.run([str(binary), '--version'])
        need(re.search(r'\bversion\s+' + re.escape(pin) + r'(?:\s|$)', out), 'wasm-opt version mismatch')
        return 'cached wasm-opt matches scripts/fetch-binaryen.sh version (archive no longer retained)'

    def didc(self):
        source = text(self.repo / 'scripts/check-candid-mirrors.sh')
        tag = re.search(r'^DIDC_TAG="([^"]+)"', source, re.M)
        need(tag is not None, 'could not read didc tag')
        target_match = re.search(re.escape(platform.system() + '/' + platform.machine()) +
                                 r'\)\s+DIDC_TARGET="([^"]+)"', source)
        need(target_match is not None, 'platform has no repository-pinned didc target')
        cache = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache')))
        binary = cache / 'ic402' / tag.group(1) / target_match.group(1) / 'didc'
        need(binary.is_file() and os.access(binary, os.X_OK), 'pinned didc has not been downloaded')
        need(version(self.run([str(binary), '--version'])) == version(tag.group(1)), 'didc version mismatch')
        return 'cached didc matches repository tag (archive no longer retained)'

    def prebuilt(self):
        hashes = []
        for line in text(self.repo / 'scripts/prebuilt.sha256').splitlines():
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            sha, name = line.split()
            need(re.fullmatch(r'[0-9a-f]{64}', sha) is not None and '/' not in name,
                 'malformed prebuilt checksum entry')
            hashes.append((sha, name))
        need(hashes, 'no prebuilt artifact checksums')
        for sha, name in hashes:
            need(hashlib.sha256((self.repo / '.icp' / name).read_bytes()).hexdigest() == sha,
                 'prebuilt artifact missing/corrupt')
        manifest = text(self.repo / 'icp.yaml')
        zk_match = re.search(r'path:\s*(example/zk-verifier/prebuilt/[^\s]+\.wasm\.gz)', manifest)
        need(zk_match is not None, 'could not derive zk-verifier prebuilt path from icp.yaml')
        with gzip.open(self.repo / zk_match.group(1), 'rb') as stream:
            need(stream.read(4) == b'\x00asm', 'zk-verifier prebuilt is missing/corrupt, so setup would require a Rust build')
        return f'{len(hashes)} prebuilt artifacts match SHA256 pins; zk-verifier gzip contains Wasm (no checksum pin claimed)'

    def browsers(self):
        # Optional Vitest peer strings in the lockfile are not installed test browsers.
        manifests = [self.cache['pkg']]
        for pattern in re.findall(r'^  - [\'\"]?([^\'\"\n]+)', text(self.repo / 'pnpm-workspace.yaml'), re.M):
            for path in self.repo.glob(pattern + '/package.json'):
                manifests.append(json.loads(text(path)))
        names = {name for pkg in manifests for group in ('dependencies', 'devDependencies') for name in pkg.get(group, {})}
        requires = any(any(token in name for token in ('playwright', 'puppeteer', 'webdriver')) for name in names)
        requires |= bool(re.search(r'playwright (install|test)|puppeteer', self.cache['ci']))
        need(not requires, 'browser dependency detected; implement/check its pinned downloaded runtime before gates')
        return 'N/A: no browser runner in workspace package manifests or CI; Vitest optional peers are not a requirement'

    def env_files(self):
        requested = self.cache.get('profile', {}).get('env_files', [])
        need(isinstance(requested, list), 'env_files profile entry must be a list')
        selected = set(requested)
        for name in ('.env.development', '.env.production'):
            if (self.repo / name).exists():
                selected.add(name)
        for name in selected:
            need(name in ('.env.development', '.env.production'), 'unsupported env filename; never inspect deploy/')
            p = secure_file(self.repo / name, self.repo)
            # Parse assignment syntax only. Values remain data and are never printed/evaluated.
            for line in text(p).splitlines():
                if not line.strip() or line.lstrip().startswith('#'):
                    continue
                need(re.match(r'^\s*(export\s+)?[A-Za-z_][A-Za-z_0-9]*\s*=', line) is not None,
                     'env file contains unsupported non-assignment syntax')
        if not selected:
            return 'N/A: no optional .env files present/required; setup/tests do not require one'
        return f'{len(selected)} env files present, owner-only, parsed as data without sourcing'

    def payer(self):
        key = secure_file(self.repo / '.local/test-payer.pem', self.repo)
        expected = principal(self.run(['icp', 'identity', 'principal', '--identity', 'test-payer']))
        der = self.run(['openssl', 'pkey', '-in', str(key), '-passin', 'pass:', '-pubout', '-outform', 'DER'], binary=True)
        need(public_key_principal(der) == expected, 'exported test-payer key does not match CLI identity')
        self.cache['payer'] = expected
        return 'exported test-payer public-key principal matches CLI identity (no secret emitted)'

    def local_links(self):
        ids = {}
        for name in ('example', 'ckusdc_ledger'):
            ids[name] = principal(self.run(['icp', 'canister', 'status', name, '-e', 'local', '--id-only']))
        need(ids['example'] != ids['ckusdc_ledger'], 'example and ledger map to the same canister')
        self.cache['local_ids'] = ids
        return 'example and ckusdc_ledger local mappings resolve to distinct principals'

    def query(self, name, method, args, identity='local-dev'):
        return self.run(['icp', 'canister', 'call', name, method, args, '-e', 'local', '--query', '--identity', identity])

    def status_entry(self, value, expected_id, expected_controller):
        # Do not accept a controller name found elsewhere in an arbitrary JSON blob.
        entries = [value] if isinstance(value, dict) else value if isinstance(value, list) else []
        if isinstance(value, dict):
            entries.extend(v for v in value.values() if isinstance(v, dict))
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            actual_id = next((entry[k] for k in ('canister_id', 'canisterId', 'id') if k in entry), None)
            controllers = entry.get('controllers')
            # Public-state fallback does not expose canister cycle balance; require the
            # authenticated management-canister status response, not just public metadata.
            cycles = entry.get('cycles', entry.get('cycles_balance'))
            if actual_id == expected_id and isinstance(controllers, list) and expected_controller in controllers:
                need(cycles is not None and re.fullmatch(r'[0-9_]+', str(cycles)) is not None,
                     'status may be public fallback: authenticated cycles field unavailable')
                return
        raise Unchecked('status did not establish exact expected canister/controller fields')

    def local_signing(self):
        payer = self.cache['payer']
        result = self.run(['icp', 'canister', 'status', 'example', '-e', 'local', '--identity', 'test-payer', '--json'])
        self.status_entry(json.loads(result), self.cache['local_ids']['example'], payer)
        return 'real authenticated status API call verifies test-payer controller membership'

    def minter(self):
        expected = principal(self.run(['icp', 'identity', 'principal', '--identity', 'local-dev']))
        out = self.query('ckusdc_ledger', 'icrc1_minting_account', '()')
        matches = re.findall(r'principal\s+"([a-z0-9-]+)"', out)
        need(matches == [expected], 'local-dev principal does not match queried ledger minter')
        need(re.search(r'subaccount\s*=\s*null\s*[;}]', out) is not None,
             'ledger minter uses a non-default or unparseable subaccount; predemo mints from null')
        return 'local-dev and null subaccount match the live ledger minting account'

    def funding(self):
        payer = self.cache['payer']
        out = self.query('ckusdc_ledger', 'icrc1_balance_of', '(record { owner = principal "' + payer + '"; subaccount = null })')
        match = re.fullmatch(r'\(\s*([0-9_]+)\s*:\s*nat\s*\)', out)
        need(match is not None, 'balance API did not return a numeric nat')
        # Minimum comes from predemo's documented fixture top-up, not a copied amount.
        source = text(self.repo / 'scripts/predemo.sh')
        amount = re.search(r'amount = ([0-9_]+) : nat; fee = null; memo = null', source)
        need(amount is not None, 'could not read integration funding target')
        need(int(match.group(1).replace('_', '')) >= int(amount.group(1).replace('_', '')),
             'test-payer balance is below predemo fixture funding target')
        return 'queried payer balance covers the funding target in scripts/predemo.sh'

    def load_profile(self):
        need(self.profile is not None, 'no authoritative deployed-target profile supplied; icp.yaml has names but no live IDs')
        p = Path(self.profile).resolve()
        need(p.is_relative_to(self.repo) and 'deploy' not in p.relative_to(self.repo).parts,
             'profile must be a public-safe file inside repo, outside deploy/')
        self.run(['git', 'ls-files', '--error-unmatch', '--', p.relative_to(self.repo).as_posix()])
        contents = text(p)
        committed = self.run(['git', 'show', 'HEAD:' + p.relative_to(self.repo).as_posix()], binary=True)
        need(committed == p.read_bytes(), 'deployment profile is uncommitted or differs from HEAD')
        profile = json.loads(contents)
        need(set(profile) <= {'environment', 'identity', 'principal', 'canisters', 'env_files', 'authority'},
             'unsupported profile fields; never include credentials')
        manifest = text(self.repo / 'icp.yaml')
        need(re.search(r'- name: ic\s+network: mainnet\s+canisters: \[example\]', manifest) is not None,
             'deployment environment shape changed; reconcile doctor with icp.yaml')
        need(profile['environment'] == 'ic', 'deploy profile must target the repository ic environment')
        need(isinstance(profile['identity'], str) and re.fullmatch(r'[\w.-]+', profile['identity']), 'invalid identity name')
        principal(profile['principal'])
        need(isinstance(profile['authority'], str) and profile['authority'].strip(), 'profile requires recorded authority')
        need(isinstance(profile['canisters'], dict) and set(profile['canisters']) == {'example'},
             'icp.yaml deploy environment requires exactly example')
        principal(profile['canisters']['example'])
        self.cache['profile'] = profile
        return 'tracked deployed-target profile parsed; recorded authority must be reviewed by the owner'

    def deploy_link(self):
        p = self.cache['profile']
        actual = principal(self.run(['icp', 'canister', 'status', 'example', '-e', p['environment'], '--id-only']))
        need(actual == p['canisters']['example'], 'local deployment link is missing or differs from recorded deployed ID')
        return 'local example mapping matches tracked deployment profile'

    def deploy_identity(self):
        p = self.cache['profile']
        actual = principal(self.run(['icp', 'identity', 'principal', '--identity', p['identity']]))
        need(actual == p['principal'], 'selected deployment identity differs from recorded principal')
        return 'deployment identity principal matches tracked profile'

    def deploy_status(self):
        p = self.cache['profile']
        value = json.loads(self.run(['icp', 'canister', 'status', 'example', '-e', 'ic', '--identity', p['identity'], '--json']))
        self.status_entry(value, p['canisters']['example'], p['principal'])
        return 'real status API confirms expected canister and controller (no create/install/deploy)'

    def gh_auth(self):
        repository = self.cache['mops']['package']['repository']
        match = re.fullmatch(r'https://github.com/([\w.-]+/[\w.-]+)', repository)
        need(match is not None, 'could not derive GitHub repository from mops.toml')
        self.cache['slug'] = match.group(1)
        identifier = self.run(['gh', 'api', 'user', '--jq', '.id'])
        need(identifier.isdigit(), 'GitHub user API did not validate login')
        permissions = self.run(['gh', 'api', 'repos/' + self.cache['slug'], '--jq', '.permissions.push'])
        need(permissions == 'true', 'GitHub login has no repository push permission')
        return 'real GitHub user/repository API calls validate login and push permission'

    def release_config(self):
        workflow = self.cache['release']
        need('id-token: write' in workflow and 'environment: release' in workflow and 'MOPS_IDENTITY_PEM' in workflow,
             'release authentication contract changed; inspect workflow before release')
        need('npm publish' in workflow and 'mops publish' in workflow, 'release publish phases not recognized')
        return 'release workflow uses npm OIDC and environment-scoped mops identity; local npm login is not used'

    def release_secret(self):
        found = self.run(['gh', 'api', 'repos/' + self.cache['slug'] + '/environments/release/secrets',
                          '--jq', 'any(.secrets[]; .name == "MOPS_IDENTITY_PEM")'])
        need(found == 'true', 'release environment publishing secret absent or API inaccessible')
        return 'GitHub API confirms publishing secret exists; its contents/usability remain CI-only, not locally verified'

    def release_runtime(self):
        raise Unchecked('could not check CI-only OIDC exchange or usability of the stored mops signing secret from this shell')

    def signing(self):
        # Let Git normalize booleans: an empty/valueless gpgsign setting means true.
        names = self.run(['git', 'config', '--name-only', '--list']).splitlines()
        keys = [key for key in ('tag.gpgsign', 'commit.gpgsign') if key in names]
        if not keys:
            return 'N/A: no configured signed tags/commits; no signing requirement inferred'
        for key in keys:
            value = self.run(['git', 'config', '--bool', '--get', key])
            need(value in ('true', 'false'), 'could not normalize Git signing boolean')
            need(value != 'true', 'signing is enabled: owner must verify signing in their terminal; doctor will not prompt or sign')
        return 'N/A: configured signing is explicitly disabled; no signing requirement inferred'

    def execute(self):
        self.check('repo-pins', 'Restore/inspect repository manifests and CI pins; update parser for deliberate format changes.', self.load_pins)
        for tool in ('node', 'pnpm', 'icp', 'mops'):
            self.check(tool, f'Install the {tool} version declared by repository pins and put it first on this shell PATH.', lambda tool=tool: self.check_tool(tool))
        self.check('path', 'Remove foreign node_modules/.bin entries from this agent shell PATH; restart the session if needed.', self.check_path)
        self.check('dependencies', 'Run pnpm install --frozen-lockfile in the implementation checkout, then rerun doctor.', self.dependencies)
        self.check('mops-dependencies', 'Run the repository-pinned mops install in the implementation checkout.', self.mops_dependencies)
        for name in ('moc', 'wasmtime'):
            self.check(name, 'Install mops.toml toolchain via pinned mops install; do not use global substitutes.', lambda name=name: self.toolchain(name))
        self.check('binaryen', 'Run scripts/fetch-binaryen.sh explicitly, then rerun doctor; doctor never downloads.', self.binaryen)
        self.check('didc', 'Install the script-pinned didc asset using its recorded SHA256; doctor never runs the gate to install it.', self.didc)
        self.check('prebuilt', 'Restore/download artifacts using scripts/fetch-prebuilt.sh and scripts/prebuilt.sha256.', self.prebuilt)
        self.check('browsers', 'Inspect new browser runner requirements and extend doctor with its pinned runtime check.', self.browsers)
        if self.level == 'deploy':
            self.check('deploy-profile', 'Record owner-approved existing example ID, controller principal and identity in a public-safe tracked JSON profile; supply --profile.', self.load_profile)
        self.check('env', 'Create only required env files with mode 0600; fix assignment syntax without sourcing them.', self.env_files)
        if self.level == 'integration':
            self.check('payer-key', 'In owner terminal run the documented predemo setup, protect .local/test-payer.pem with chmod 600; never export deploy keys here.', self.payer)
            self.check('local-links', 'Run documented local setup intentionally; verify example/ledger name mappings before integration gates.', self.local_links)
            self.check('local-signing', 'Verify test-payer login/key unlock and controller assignment in owner terminal; rerun doctor in the agent shell.', self.local_signing)
            self.check('minter', 'Reconcile local-dev against the ledger minter using documented local fixture setup; do not mint until identities match.', self.minter)
            self.check('funding', 'Use documented local predemo funding; inspect the ledger result variant, then rerun doctor.', self.funding)
        if self.level == 'deploy':
            self.check('deploy-link', 'Restore the recorded icp canister link; never run a first deploy to recreate an existing canister.', self.deploy_link)
            self.check('deploy-identity', 'Restore the approved deployment identity in owner terminal; verify its principal without displaying keys.', self.deploy_identity)
            self.check('deploy-status', 'Verify network/login/controller access in owner terminal; do not plan or create resources while uncheckable.', self.deploy_status)
        if self.level == 'release':
            self.check('gh-auth', 'Run gh auth login in owner terminal for an account with repository push access; rerun the real API check.', self.gh_auth)
            self.check('release-config', 'Reconcile release workflow auth changes with doctor; npm login is not a substitute for OIDC.', self.release_config)
            self.check('release-secret', 'Owner verifies the release environment MOPS_IDENTITY_PEM secret through GitHub; do not print/export it.', self.release_secret)
            self.check('release-runtime', 'Owner must verify authenticated publishing in the authorized release CI context; local doctor cannot certify CI-held secrets. Keep gate/publish verification owed.', self.release_runtime)
            self.check('signing', 'Perform any prompted signing preflight in owner terminal and record evidence; do not create a tag without release authorization.', self.signing)
        return self.rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, type=Path)
    parser.add_argument('--level', choices=['tools', 'integration', 'deploy', 'release'], default='tools')
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    doctor = Doctor(args.repo, args.level, args.profile)
    rows = doctor.execute()
    passed = all(row['status'] != 'FAIL' for row in rows)
    result = dict(verdict='READY' if passed else 'NOT READY', level=args.level, checks=rows,
                  limitation='Readiness is not release/deploy authorization. CI-only secret contents and OIDC exchange are not locally verified.')
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        for row in rows:
            mark = {'PASS': '✓', 'FAIL': '✗', 'NA': '–'}[row['status']]
            print(f"{mark} {row['id']}: {row['detail']}")
            if row['fix']:
                print('  Fix: ' + row['fix'])
        print(f"Doctor {args.level}: {result['verdict']}")
        print(result['limitation'])
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
