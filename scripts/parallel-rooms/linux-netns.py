#!/usr/bin/env python3
"""Exercise real room daemons and TUNs inside disposable Linux namespaces."""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any


HTTP_HELPER = r'''
import json, sys, urllib.request, urllib.error
p = json.load(sys.stdin)
headers = {"Content-Type": "application/json"}
if p["token"]: headers["Authorization"] = "Bearer " + p["token"]
data = None if p["body"] is None else json.dumps(p["body"]).encode()
r = urllib.request.Request(p["url"], data=data, headers=headers, method=p["method"])
try:
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(r, timeout=3) as response:
        text = response.read(1048576).decode()
        try: body = json.loads(text)
        except ValueError: body = text
        print(json.dumps({"status": response.status, "body": body}))
except urllib.error.HTTPError as error:
    print(json.dumps({"status": error.code, "body": None}))
'''


def run(args: list[str], *, check: bool = True, **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, capture_output=True, check=check, timeout=20, **kwargs)


class Lab:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.prefix = 'pr' + secrets.token_hex(4)
        self.bridge = self.prefix + 'br'
        self.namespaces: list[str] = []
        self.links: list[str] = []
        self.processes: list[subprocess.Popen[str]] = []
        self.temp = tempfile.TemporaryDirectory(prefix='p2wlan-parallel-')
        self.root = Path(self.temp.name)
        os.chmod(self.root, 0o700)
        self.logs: list[Any] = []
        self.daemons: dict[str, dict[str, Any]] = {}
        self.evidence: dict[str, Any] = {
            'source_commit': args.head,
            'transport': 'direct',
            'uses_real_tun': True,
            'same_host_namespaces': True,
            'checks': {},
            'passed': False,
        }

    def ns(self, label: str) -> str:
        return self.prefix + '-' + label

    def setup(self) -> None:
        run(['ip', 'link', 'add', self.bridge, 'type', 'bridge'])
        self.links.append(self.bridge)
        run(['ip', 'link', 'set', self.bridge, 'up'])
        for index, label in enumerate(['control', 'a', 'b', 'c'], start=2):
            name = self.ns(label)
            run(['ip', 'netns', 'add', name])
            self.namespaces.append(name)
            host, peer = self.prefix + str(index) + 'h', self.prefix + str(index) + 'n'
            run(['ip', 'link', 'add', host, 'type', 'veth', 'peer', 'name', peer])
            self.links.append(host)
            run(['ip', 'link', 'set', peer, 'netns', name])
            run(['ip', 'link', 'set', host, 'master', self.bridge])
            run(['ip', 'link', 'set', host, 'up'])
            self.cmd(label, ['ip', 'link', 'set', 'lo', 'up'])
            self.cmd(label, ['ip', 'link', 'set', peer, 'name', 'eth0'])
            self.cmd(label, ['ip', 'addr', 'add', f'192.0.2.{index}/24', 'dev', 'eth0'])
            self.cmd(label, ['ip', 'link', 'set', 'eth0', 'up'])

    def cmd(self, label: str, command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        return run(['ip', 'netns', 'exec', self.ns(label), *command], **kwargs)

    def spawn(self, label: str, name: str, command: list[str], *, env: dict[str, str] | None = None, token: str | None = None) -> subprocess.Popen[str]:
        log = (self.root / (name + '.console')).open('w')
        self.logs.append(log)
        clean = {key: value for key, value in os.environ.items() if not key.startswith('P2WLAN_')}
        clean.update({'RUST_LOG': 'info', 'RUST_BACKTRACE': '0'})
        clean.update(env or {})
        process = subprocess.Popen(
            ['ip', 'netns', 'exec', self.ns(label), *command],
            text=True, stdin=subprocess.PIPE, stdout=log, stderr=log, env=clean,
        )
        self.processes.append(process)
        if token is not None:
            assert process.stdin is not None
            process.stdin.write(token + '\n')
            process.stdin.flush()
        if process.stdin is not None:
            process.stdin.close()
        return process

    def http(self, label: str, path: str, *, token: str = '', method: str = 'GET', body: Any = None, port: int | None = None) -> Any:
        url = f'http://127.0.0.1:{port}{path}' if port else 'http://192.0.2.2:8080' + path
        result = self.cmd(label, [sys.executable, '-c', HTTP_HELPER], input=json.dumps({
            'url': url, 'method': method, 'token': token, 'body': body,
        }))
        response = json.loads(result.stdout)
        if not 200 <= response['status'] < 300:
            raise RuntimeError(f'HTTP {response["status"]} at {method} {path}')
        return response['body']

    def wait(self, label: str, predicate: Any, timeout: float = 90) -> Any:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except (RuntimeError, subprocess.SubprocessError, OSError, ValueError):
                pass
            time.sleep(0.5)
        raise RuntimeError(f'Timed out: {label}')

    def daemon(self, name: str, label: str, room: dict[str, Any], token: str, port: int) -> dict[str, Any]:
        directory = self.root / name
        directory.mkdir(exist_ok=True)
        interface = 'p2r' + name
        command = [
            str(self.args.daemon), '--config', str(directory / 'config.json'),
            '--control', 'http://192.0.2.2:8080', '--network', room['id'],
            '--interface', interface, '--diagnostics-bind', f'127.0.0.1:{port}',
            '--log-file', str(directory / 'p2wlan-daemon.log'),
            '--device-name', name, '--udp-bind', '0.0.0.0:0',
            '--stun', '', '--heartbeat-interval', '1', '--managed', '--token-stdin',
        ]
        process = self.spawn(label, name, command, token=token)
        entry = dict(process=process, namespace=label, directory=directory, port=port, interface=interface, room=room)
        self.daemons[name] = entry
        return entry

    def status(self, name: str) -> dict[str, Any]:
        entry = self.daemons[name]
        token = (entry['directory'] / 'p2wlan-daemon.diag-auth').read_text().strip()
        status = self.http(entry['namespace'], '/status', token=token, port=entry['port'])
        if status.get('network_id') != entry['room']['id'] or not status.get('virtual_ip'):
            raise RuntimeError('Room diagnostics identity mismatch')
        return status

    def ping(self, label: str, address: str, count: int = 2) -> bool:
        return self.cmd(label, ['ping', '-n', '-c', str(count), '-i', '0.2', '-W', '1', address], check=False).returncode == 0

    def check(self, name: str, condition: bool) -> None:
        self.evidence['checks'][name] = bool(condition)
        if not condition:
            raise RuntimeError('Check failed: ' + name)
        print('PASS ' + name, flush=True)

    def exercise(self) -> None:
        identity = json.loads(run([str(self.args.daemon), '--build-info']).stdout)
        self.check('binary_matches_source', identity.get('git_commit') == self.args.head)
        self.setup()
        self.spawn('control', 'control', [str(self.args.control)], env={
            'PORT': '8080', 'DB_PATH': str(self.root / 'control.db'), 'JWT_SECRET': secrets.token_hex(32),
        })
        self.wait('control readiness', lambda: self.http('control', '/health'), 20)
        users = {}
        password = secrets.token_urlsafe(24)
        for label in ['a', 'b', 'c']:
            users[label] = self.http('control', '/api/v1/register', method='POST', body={
                'email': label + '@parallel.example', 'password': password,
            })
        rooms = {}
        for number, owner in [(1, 'b'), (2, 'c')]:
            rooms[number] = self.http('control', '/api/v1/rooms', method='POST', token=users[owner]['token'], body={
                'name': f'Parallel Room {number}', 'password': password,
            })['room']
            self.http('control', '/api/v1/rooms/join', method='POST', token=users['a']['token'], body={
                'room_code': rooms[number]['room_code'], 'password': password,
            })
        self.check('distinct_room_cidrs', rooms[1]['cidr'] != rooms[2]['cidr'])
        for name, namespace, number, port in [('a1', 'a', 1, 41001), ('a2', 'a', 2, 41002), ('b1', 'b', 1, 41001), ('c2', 'c', 2, 41001)]:
            self.daemon(name, namespace, rooms[number], users[namespace]['token'], port)
        snapshots = {name: self.wait(name + ' readiness', lambda name=name: self.status(name)) for name in self.daemons}
        ips = {name: snapshot['virtual_ip'] for name, snapshot in snapshots.items()}
        self.evidence['assigned_ips'] = ips
        for name in ['a1', 'a2', 'b1', 'c2']:
            routes = json.loads(self.cmd(self.daemons[name]['namespace'], ['ip', '-j', '-4', 'route', 'show', 'exact', self.daemons[name]['room']['cidr']]).stdout)
            self.check(name + '_real_tun_route', any(row.get('dev') == self.daemons[name]['interface'] for row in routes))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(self.wait, 'bidirectional ' + name, lambda namespace=namespace, peer=peer: self.ping(namespace, ips[peer]))
                       for name, namespace, peer in [('a1', 'a', 'b1'), ('a2', 'a', 'c2'), ('b1', 'b', 'a1'), ('c2', 'c', 'a2')]]
            self.check('both_rooms_bidirectional_parallel', all(future.result() for future in futures))
        self.check('independent_node_ids', snapshots['a1']['node_id'] != snapshots['a2']['node_id'])
        other = self.daemons['a2']['process']
        first = self.daemons['a1']
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            uninterrupted = pool.submit(self.ping, 'a', ips['c2'], 40)
            auth = (first['directory'] / 'p2wlan-daemon.diag-auth').read_text().strip()
            self.http('a', '/shutdown', token=auth, method='POST', port=41001)
            first['process'].wait(timeout=15)
            self.check('one_room_stop_preserves_other_traffic', uninterrupted.result())
        self.check('other_process_unchanged', other.poll() is None and self.status('a2')['process_id'] == snapshots['a2']['process_id'])
        routes = json.loads(self.cmd('a', ['ip', '-j', '-4', 'route', 'show', 'exact', rooms[1]['cidr']]).stdout)
        self.check('stopped_room_route_removed', not routes)
        self.daemon('a1', 'a', rooms[1], users['a']['token'], 41001)
        self.wait('restarted a1', lambda: self.status('a1'))
        self.wait('restarted room traffic', lambda: self.ping('a', ips['b1']))
        self.check('room_restart_preserves_other', self.ping('a', ips['c2']))
        started = time.monotonic()
        self.http('control', f'/api/v1/rooms/{rooms[1]["id"]}/members/{users["a"]["user"]["id"]}',
                  method='DELETE', token=users['b']['token'])
        time.sleep(max(0, 31 - (time.monotonic() - started)))
        self.check('revoked_room_cannot_send_after_lease', not self.ping('a', ips['b1']))
        self.check('revoked_room_cannot_receive_after_lease', not self.ping('b', ips['a1']))
        self.check('other_room_survives_revocation', self.ping('a', ips['c2']) and self.ping('c', ips['a2']))
        self.evidence['passed'] = True

    def close(self) -> None:
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
        for process in reversed(self.processes):
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        for namespace in reversed(self.namespaces):
            run(['ip', 'netns', 'delete', namespace], check=False)
        for link in reversed(self.links):
            run(['ip', 'link', 'delete', link], check=False)
        for log in self.logs:
            log.close()
        self.temp.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--daemon', type=lambda value: Path(value).resolve(), required=True)
    parser.add_argument('--control', type=lambda value: Path(value).resolve(), required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0 or not Path('/dev/net/tun').exists():
        parser.error('Linux root and /dev/net/tun are required; mock TUN is not accepted')
    if not shutil.which('ip') or not shutil.which('ping'):
        parser.error('iproute2 and iputils-ping are required')
    for binary in [args.daemon, args.control]:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            parser.error('Missing executable: ' + str(binary))
    lab = Lab(args)
    try:
        lab.exercise()
        return 0
    except Exception as error:
        lab.evidence['failure_type'] = type(error).__name__
        if isinstance(error, RuntimeError):
            lab.evidence['failure_detail'] = str(error)[:300]
            print(str(error), file=sys.stderr)
        for name, entry in lab.daemons.items():
            log_path = entry['directory'] / 'p2wlan-daemon.log'
            if log_path.exists():
                lines = log_path.read_text().splitlines()[-120:]
                print(f"=== {name} daemon log tail ===", file=sys.stderr)
                print("\n".join(lines), file=sys.stderr)
            console_path = lab.root / (name + '.console')
            if console_path.exists():
                lines = console_path.read_text().splitlines()[-120:]
                if lines:
                    print(f"=== {name} console tail ===", file=sys.stderr)
                    print("\n".join(lines), file=sys.stderr)
        print('FAIL real TUN parallel rooms: ' + type(error).__name__, file=sys.stderr)
        return 1
    finally:
        try:
            lab.close()
            lab.evidence['cleanup_completed'] = True
        except Exception as error:
            lab.evidence['cleanup_completed'] = False
            lab.evidence['passed'] = False
            lab.evidence['cleanup_error_type'] = type(error).__name__
            raise
        finally:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(lab.evidence, indent=2) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())
