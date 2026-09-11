import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2wlan_flutter_client/core/api/control_api.dart';
import 'package:p2wlan_flutter_client/core/build_info.dart';
import 'package:p2wlan_flutter_client/core/diagnostics/session_log_bundle.dart';
import 'package:p2wlan_flutter_client/core/models/diagnostics_models.dart';
import 'package:p2wlan_flutter_client/core/security/secure_token_repository.dart';
import 'package:p2wlan_flutter_client/core/state/settings_store.dart';

void main() {
  test(
    'profile username reads and writes authenticated account data',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final api = ControlApi();
      addTearDown(api.close);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      var name = '小林';
      server.listen((request) async {
        expect(request.uri.path, '/api/v1/profile');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer test-account',
        );
        requests.add(request.method);
        if (request.method == 'PATCH') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(body.keys, ['username']);
          name = body['username'] as String;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'user': {'username': name},
          }),
        );
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}';
      expect(
        await api.profileUsername(
          controlServer: url,
          authToken: 'test-account',
        ),
        '小林',
      );
      expect(
        await api.profileUsername(
          controlServer: url,
          authToken: 'test-account',
          username: ' 阿明 ',
        ),
        '阿明',
      );
      await expectLater(
        api.profileUsername(
          controlServer: url,
          authToken: 'test-account',
          username: '  ',
        ),
        throwsA(isA<ControlApiException>()),
      );
      expect(requests, ['GET', 'PATCH']);
    },
  );

  test('account profile exposes the login email alongside username', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = ControlApi();
    addTearDown(api.close);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.method, 'GET');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'user': {'email': 'pyu@example.test', 'username': 'pyu'},
        }),
      );
      await request.response.close();
    });

    final profile = await api.accountProfile(
      controlServer: 'http://127.0.0.1:${server.port}',
      authToken: 'test-account',
    );
    expect(profile.email, 'pyu@example.test');
    expect(profile.username, 'pyu');
  });

  test('default control server matches the desktop client default', () {
    expect(defaultControlServer, 'http://47.109.40.237:18080');
  });

  test('JWT expiry guard identifies expired tokens without rejecting opaque tokens', () {
    final now = DateTime.utc(2026, 8, 21, 16);
    String tokenFor(int exp) {
      final payload = base64Url
          .encode(utf8.encode(jsonEncode({'exp': exp})))
          .replaceAll('=', '');
      return 'header.$payload.signature';
    }

    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    expect(isAuthTokenExpired(tokenFor(nowSeconds + 3600), now: now), isFalse);
    expect(isAuthTokenExpired(tokenFor(nowSeconds - 3600), now: now), isTrue);
    expect(isAuthTokenExpired('custom-deployment-token', now: now), isFalse);
  });

  test('settings load migrates the old placeholder control host', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'p2wlan_control_migration_test_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    final settingsFile = File('${tempDir.path}/settings.json');
    await settingsFile.writeAsString('''
{
  "controlServer": "$legacyPlaceholderControlServer",
  "authToken": "",
  "manualMode": false
}
''');

    final store = SettingsStore(
      settingsFile: settingsFile,
      tokenRepository: InMemorySecureTokenRepository(),
    );
    await store.load();
    addTearDown(store.dispose);

    expect(store.settings.controlServer, defaultControlServer);
  });

  test(
    'settings load migrates the legacy host even with a stored token',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'p2wlan_control_token_migration_test_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final settingsFile = File('${tempDir.path}/settings.json');
      await settingsFile.writeAsString('''
{
  "controlServer": "$legacyControlServer",
  "authToken": "expired-or-legacy-token",
  "manualMode": false
}
''');

      final store = SettingsStore(
        settingsFile: settingsFile,
        tokenRepository: InMemorySecureTokenRepository(),
      );
      await store.load();
      addTearDown(store.dispose);

      expect(store.settings.controlServer, defaultControlServer);
    },
  );

  test('settings load replaces ip-like default device names', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'p2wlan_device_name_migration_test_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    final settingsFile = File('${tempDir.path}/settings.json');
    await settingsFile.writeAsString('''
{
  "controlServer": "$defaultControlServer",
  "authToken": "token",
  "deviceName": "192.168.2.16",
  "manualMode": false
}
''');

    final store = SettingsStore(
      settingsFile: settingsFile,
      tokenRepository: InMemorySecureTokenRepository(),
    );
    await store.load();
    addTearDown(store.dispose);

    expect(store.settings.deviceName, isNot('192.168.2.16'));
    expect(store.settings.deviceName.trim(), isNotEmpty);
  });

  test('settings load replaces localhost device names', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'p2wlan_localhost_device_name_migration_test_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    final settingsFile = File('${tempDir.path}/settings.json');
    await settingsFile.writeAsString('''
{
  "controlServer": "$defaultControlServer",
  "authToken": "token",
  "deviceName": "localhost",
  "manualMode": false
}
''');

    final store = SettingsStore(
      settingsFile: settingsFile,
      tokenRepository: InMemorySecureTokenRepository(),
    );
    await store.load();
    addTearDown(store.dispose);

    expect(store.settings.deviceName.toLowerCase(), isNot('localhost'));
    expect(store.settings.deviceName.trim(), isNotEmpty);
  });

  test(
    'authenticate wraps connection failures as user-facing errors',
    () async {
      final serverSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = serverSocket.port;
      await serverSocket.close();
      final api = ControlApi();
      addTearDown(api.close);

      expect(
        () => api.authenticate(
          mode: AuthMode.login,
          controlServer: 'http://127.0.0.1:$port',
          email: 'user@example.com',
          password: 'password',
        ),
        throwsA(
          isA<ControlApiException>().having(
            (error) => error.message,
            'message',
            contains('无法连接控制服务器'),
          ),
        ),
      );
    },
  );

  test('authenticate explains Windows sendto socket failures', () async {
    const socketError = SocketException(
      '由于套接字没有连接并且没有提供地址，发送或接收数据的请求没有被接受。sendto failed',
      osError: OSError('socket is not connected', 10057),
    );
    final api = ControlApi(client: _ThrowingHttpClient(socketError));
    addTearDown(api.close);

    await expectLater(
      () => api.authenticate(
        mode: AuthMode.login,
        controlServer: defaultControlServer,
        email: 'user@example.com',
        password: 'password',
      ),
      throwsA(
        isA<ControlApiException>().having(
          (error) => error.message,
          'message',
          allOf(contains('Windows 无法建立到控制服务器的连接'), contains('/health')),
        ),
      ),
    );
  });

  test('deleteDevice sends a bearer-authenticated DELETE request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final api = ControlApi();
    addTearDown(api.close);

    final deleteFuture = api.deleteDevice(
      controlServer: 'http://127.0.0.1:${server.port}',
      authToken: 'token-123',
      deviceId: 'node-a',
    );
    final request = await server.first.timeout(const Duration(seconds: 3));
    expect(request.method, 'DELETE');
    expect(request.uri.path, '/api/v1/devices/node-a');
    expect(
      request.headers.value(HttpHeaders.authorizationHeader),
      'Bearer token-123',
    );
    request.response.headers.contentType = ContentType.json;
    request.response.write('{"success":true}');
    await request.response.close();

    await deleteFuture;
  });

  test(
    'uploadSupportLogs sends a compressed redacted current-session bundle',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final api = ControlApi();
      addTearDown(api.close);

      final uploadFuture = api.uploadSupportLogs(
        controlServer: 'http://127.0.0.1:${server.port}',
        authToken: 'token-123',
        deviceName: 'Mini',
        clientBuild: const ClientBuildInfo(
          appVersion: '0.1.135',
          gitCommit: 'abc',
          buildId: 'build',
          dirtyValue: 'false',
          diffHash: 'none',
          profile: 'release',
        ),
        daemonBuild: null,
        files: const [
          SessionLogFile(name: 'p2wlan-daemon.log', content: 'token=secret\n'),
        ],
      );
      final request = await server.first.timeout(const Duration(seconds: 3));
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/v1/support/logs');
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer token-123',
      );
      expect(request.headers.value(HttpHeaders.contentEncodingHeader), 'gzip');
      final compressed = await request.fold<List<int>>(<int>[], (
        buffer,
        chunk,
      ) {
        buffer.addAll(chunk);
        return buffer;
      });
      final payload = jsonDecode(
        utf8.decode(GZipCodec().decode(compressed)),
      ) as Map<String, dynamic>;
      final files = payload['files'] as List<dynamic>;
      expect(
        (files.single as Map<String, dynamic>)['content'],
        'token=<redacted>\n',
      );
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"success":true,"upload_id":"upload-1"}');
      await request.response.close();

      final result = await uploadFuture;
      expect(result.uploadId, 'upload-1');
      expect(result.instances, 1);
    },
  );

  test(
    'uploadSupportLogs v2 sends manifest and includes room instances',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final api = ControlApi();
      addTearDown(api.close);

      final uploadFuture = api.uploadSupportLogs(
        controlServer: 'http://127.0.0.1:${server.port}',
        authToken: 'token-123',
        deviceName: 'Mini',
        clientBuild: const ClientBuildInfo(
          appVersion: '0.1.135',
          gitCommit: 'abc',
          buildId: 'build',
          dirtyValue: 'false',
          diffHash: 'none',
          profile: 'release',
        ),
        daemonBuild: null,
        files: const [
          SessionLogFile(name: 'p2wlan-daemon.log', content: 'daemon ok\n'),
          SessionLogFile(
            name: 'rooms/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/p2wlan-daemon.log',
            content: 'room daemon ok\n',
          ),
        ],
      );
      final request = await server.first.timeout(const Duration(seconds: 3));
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/v1/support/logs');
      final compressed = await request.fold<List<int>>(<int>[], (
        buffer,
        chunk,
      ) {
        buffer.addAll(chunk);
        return buffer;
      });
      final payload = jsonDecode(
        utf8.decode(GZipCodec().decode(compressed)),
      ) as Map<String, dynamic>;
      expect(payload['schema_version'], 2);
      final manifest = payload['manifest'] as Map<String, dynamic>;
      expect(manifest['has_room_logs'], true);
      expect(manifest['total_instances'], 2);
      final files = payload['files'] as List<dynamic>;
      expect(files.length, 2);

      request.response
        ..headers.contentType = ContentType.json
        ..write('{"success":true,"upload_id":"upload-v2","instances":2}');
      await request.response.close();

      final result = await uploadFuture;
      expect(result.uploadId, 'upload-v2');
      expect(result.instances, 2);
    },
  );

  test('uploadSupportLogs v2 does not inflate total_instances when multiple files exist per room', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final api = ControlApi();
    addTearDown(api.close);

    final uploadFuture = api.uploadSupportLogs(
      controlServer: 'http://127.0.0.1:${server.port}',
      authToken: 'token-123',
      deviceName: 'Mini',
      clientBuild: const ClientBuildInfo(
        appVersion: '0.1.135',
        gitCommit: 'abc',
        buildId: 'build',
        dirtyValue: 'false',
        diffHash: 'none',
        profile: 'release',
      ),
      daemonBuild: null,
      files: const [
        SessionLogFile(name: 'p2wlan-daemon.log', content: 'daemon ok\n'),
        SessionLogFile(
          name: 'rooms/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/p2wlan-daemon.log',
          content: 'room daemon ok\n',
        ),
        SessionLogFile(
          name: 'rooms/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/status-summary.json',
          content: '{"network_id":"r1"}\n',
        ),
      ],
    );
    final request = await server.first.timeout(const Duration(seconds: 3));
    final compressed = await request.fold<List<int>>(<int>[], (buffer, chunk) {
      buffer.addAll(chunk);
      return buffer;
    });
    final payload = jsonDecode(
      utf8.decode(GZipCodec().decode(compressed)),
    ) as Map<String, dynamic>;
    expect(payload['schema_version'], 2);
    final manifest = payload['manifest'] as Map<String, dynamic>;
    expect(manifest['has_room_logs'], true);
    // Main daemon (1) + room profile (1) = 2 instances, despite 3 files!
    expect(manifest['total_instances'], 2);

    request.response
      ..headers.contentType = ContentType.json
      ..write('{"success":true,"upload_id":"upload-v2-dedup","instances":2}');
    await request.response.close();

    final result = await uploadFuture;
    expect(result.uploadId, 'upload-v2-dedup');
    expect(result.instances, 2);
  });

  for (final roomCount in [5, 8]) {
    test(
      'uploadSupportLogs v2 sends all files for $roomCount room instances',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final api = ControlApi();
        addTearDown(api.close);
        final files = <SessionLogFile>[
          const SessionLogFile(
            name: 'p2wlan-daemon.log',
            content: 'main daemon ok\n',
          ),
          const SessionLogFile(
            name: 'p2wlan-client.log',
            content: 'client ok\n',
          ),
        ];
        for (var room = 1; room <= roomCount; room++) {
          final profileId = room.toRadixString(16).padLeft(64, '0');
          files.addAll([
            SessionLogFile(
              name: 'rooms/$profileId/p2wlan-daemon.log',
              content: 'room $room daemon ok\n',
            ),
            SessionLogFile(
              name: 'rooms/$profileId/status-summary.json',
              content: '{"phase":"unavailable","room":$room}',
            ),
          ]);
        }

        final uploadFuture = api.uploadSupportLogs(
          controlServer: 'http://127.0.0.1:${server.port}',
          authToken: 'token-123',
          deviceName: 'Mini',
          clientBuild: const ClientBuildInfo(
            appVersion: '0.1.135',
            gitCommit: 'abc',
            buildId: 'build',
            dirtyValue: 'false',
            diffHash: 'none',
            profile: 'release',
          ),
          daemonBuild: null,
          files: files,
        );
        final request = await server.first.timeout(const Duration(seconds: 3));
        final compressed = await request.fold<List<int>>(<int>[], (
          buffer,
          chunk,
        ) {
          buffer.addAll(chunk);
          return buffer;
        });
        final payload = jsonDecode(
          utf8.decode(GZipCodec().decode(compressed)),
        ) as Map<String, dynamic>;
        expect(payload['schema_version'], 2);
        expect(
          (payload['files'] as List<dynamic>),
          hasLength(2 + roomCount * 2),
        );
        expect(
          (payload['manifest'] as Map<String, dynamic>)['total_instances'],
          roomCount + 1,
        );
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'success': true,
              'upload_id': 'upload-$roomCount-rooms',
              'instances': roomCount + 1,
            }),
          );
        await request.response.close();

        final result = await uploadFuture;
        expect(result.instances, roomCount + 1);
      },
    );
  }

  test('uploadSupportLogs records the room instances omitted by the bounded collector', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final api = ControlApi();
    addTearDown(api.close);
    final files = <SessionLogFile>[
      const SessionLogFile(name: 'p2wlan-daemon.log', content: 'main\n'),
      const SessionLogFile(name: 'p2wlan-client.log', content: 'client\n'),
    ];
    for (var room = 1; room <= 8; room++) {
      final profileId = room.toRadixString(16).padLeft(64, '0');
      files.addAll([
        SessionLogFile(
          name: 'rooms/$profileId/p2wlan-daemon.log',
          content: 'room $room\n',
        ),
        SessionLogFile(
          name: 'rooms/$profileId/status-summary.json',
          content: '{"phase":"failed"}',
        ),
      ]);
    }
    final omittedProfileId = (9).toRadixString(16).padLeft(64, '0');

    final uploadFuture = api.uploadSupportLogs(
      controlServer: 'http://127.0.0.1:${server.port}',
      authToken: 'token-123',
      deviceName: 'Mini',
      clientBuild: const ClientBuildInfo(
        appVersion: '0.1.135',
        gitCommit: 'abc',
        buildId: 'build',
        dirtyValue: 'false',
        diffHash: 'none',
        profile: 'release',
      ),
      daemonBuild: null,
      files: files,
      omittedRoomProfileIds: [omittedProfileId],
    );
    final request = await server.first.timeout(const Duration(seconds: 3));
    final compressed = await request.fold<List<int>>(<int>[], (buffer, chunk) {
      buffer.addAll(chunk);
      return buffer;
    });
    final payload = jsonDecode(
      utf8.decode(GZipCodec().decode(compressed)),
    ) as Map<String, dynamic>;
    final manifest = payload['manifest'] as Map<String, dynamic>;
    expect(manifest['total_instances'], 9);
    expect(manifest['retained_room_instances'], 8);
    expect(manifest['omitted_room_instances'], 1);
    expect(manifest['omitted_reason'], 'room_instance_budget');
    request.response
      ..headers.contentType = ContentType.json
      ..write('{"success":true,"upload_id":"upload-omitted","instances":9}');
    await request.response.close();

    expect((await uploadFuture).instances, 9);
  });

  test(
    'uploadSupportLogs translates schema v2 and manifest mismatch errors',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final api = ControlApi();
      addTearDown(api.close);

      final uploadFuture = api.uploadSupportLogs(
        controlServer: 'http://127.0.0.1:${server.port}',
        authToken: 'token-123',
        deviceName: 'Mini',
        clientBuild: const ClientBuildInfo(
          appVersion: '0.1.135',
          gitCommit: 'abc',
          buildId: 'build',
          dirtyValue: 'false',
          diffHash: 'none',
          profile: 'release',
        ),
        daemonBuild: null,
        files: const [
          SessionLogFile(name: 'p2wlan-daemon.log', content: 'daemon ok\n'),
          SessionLogFile(
            name: 'rooms/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/p2wlan-daemon.log',
            content: 'room daemon ok\n',
          ),
        ],
      );
      final request = await server.first.timeout(const Duration(seconds: 3));
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write('{"error":"unsupported schema_version: 2"}');
      await request.response.close();

      await expectLater(
        uploadFuture,
        throwsA(
          isA<ControlApiException>().having(
            (error) => error.message,
            'message',
            contains('不支持多房间日志格式'),
          ),
        ),
      );
    },
  );

  test('updateDevice sends name and virtual IP in PATCH request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final api = ControlApi();
    addTearDown(api.close);

    final updateFuture = api.updateDevice(
      controlServer: 'http://127.0.0.1:${server.port}',
      authToken: 'token-123',
      deviceId: 'node-a',
      deviceName: '  Studio Mac  ',
      virtualIp: ' 10.20.0.88 ',
    );
    final request = await server.first.timeout(const Duration(seconds: 3));
    expect(request.method, 'PATCH');
    expect(request.uri.path, '/api/v1/devices/node-a');
    expect(
      request.headers.value(HttpHeaders.authorizationHeader),
      'Bearer token-123',
    );
    final payload = jsonDecode(
      await utf8.decoder.bind(request).join(),
    ) as Map<String, dynamic>;
    expect(payload['device_name'], 'Studio Mac');
    expect(payload['virtual_ip'], '10.20.0.88');
    request.response.headers.contentType = ContentType.json;
    request.response.write('''
{
  "success": true,
  "device": {
    "device_name": "Studio Mac",
    "virtual_ip": "10.20.0.88"
  }
}
''');
    await request.response.close();

    final result = await updateFuture;
    expect(result.deviceName, 'Studio Mac');
    expect(result.virtualIp, '10.20.0.88');
  });

  test('updateDevice rejects invalid virtual IP before sending', () async {
    final api = ControlApi();
    addTearDown(api.close);

    await expectLater(
      api.updateDevice(
        controlServer: defaultControlServer,
        authToken: 'token-123',
        deviceId: 'node-a',
        virtualIp: 'not-an-ip',
      ),
      throwsA(
        isA<ControlApiException>().having(
          (error) => error.message,
          'message',
          contains('虚拟 IP 格式不正确'),
        ),
      ),
    );
  });

  test(
    'deleteDevice reports expired session instead of login credentials',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final api = ControlApi();
      addTearDown(api.close);

      final deleteFuture = api.deleteDevice(
        controlServer: 'http://127.0.0.1:${server.port}',
        authToken: 'expired-token',
        deviceId: 'node-a',
      );
      final request = await server.first.timeout(const Duration(seconds: 3));
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"error":"unauthorized"}');
      await request.response.close();

      await expectLater(
        deleteFuture,
        throwsA(
          isA<ControlApiException>()
              .having((error) => error.message, 'message', contains('重新登录'))
              .having(
                (error) => error.message,
                'message',
                isNot(contains('邮箱')),
              ),
        ),
      );
    },
  );
}

class _ThrowingHttpClient implements HttpClient {
  _ThrowingHttpClient(this.error);

  final Object error;

  @override
  Duration? connectionTimeout;

  @override
  void close({bool force = false}) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    return Future<HttpClientRequest>.error(error);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
