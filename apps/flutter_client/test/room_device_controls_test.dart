import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2wlan_flutter_client/core/api/diagnostics_api.dart';
import 'package:p2wlan_flutter_client/core/daemon/daemon_controller.dart';
import 'package:p2wlan_flutter_client/core/models/diagnostics_models.dart';
import 'package:p2wlan_flutter_client/core/rooms/desktop_room_runtime.dart';
import 'package:p2wlan_flutter_client/core/rooms/parallel_rooms.dart';
import 'package:p2wlan_flutter_client/core/rooms/room_api.dart';
import 'package:p2wlan_flutter_client/core/rooms/room_connection_preferences.dart';

import 'parallel_rooms_test.dart' as fixtures;

final room = FriendRoom(
  id: fixtures.room(1).id,
  code: '12345678',
  name: 'Room',
  cidr: '10.21.1.0/24',
  ownerId: 'owner',
  role: 'member',
  locked: false,
  deviceControls: true,
);

class Control extends RoomApi {
  Control()
    : super(server: 'https://control.example', token: fixtures.token('member'));
  String state = 'allowed';
  bool? resume;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    List<String> segments, [
    Map<String, dynamic>? payload,
  ]) async {
    resume = payload?['resume'] as bool?;
    if (state == 'paused' && resume == true) state = 'allowed';
    if (state != 'allowed') {
      throw RoomException('server $state', code: 'room_device_$state');
    }
    return {};
  }

  @override
  Future<RoomRoster> roster(String id) async => RoomRoster.fromJson({
    'room': {
      'id': id,
      'room_code': '12345678',
      'name': 'Room',
      'cidr': '10.21.1.0/24',
      'owner_id': 'owner',
      'role': 'member',
      'device_controls_version': 1,
    },
    'device_access': [
      {'public_key': 'local-key', 'state': state},
    ],
  });
  @override
  void close() {}
}

class Diagnostics extends DiagnosticsApi {
  @override
  Future<bool> fetchHealth(String url) async => false;
  @override
  Future<DiagnosticsSnapshot> fetchStatus(String url) async =>
      DiagnosticsSnapshot.fromJson({
        'network_id': room.id,
        'node_id': 'local',
        'virtual_ip': '10.21.1.2',
      });
  @override
  Future<RoutesResponse> verifyRoutes(String url) async => const RoutesResponse(
    contractVersion: 1,
    interfaceName: 'test',
    mtu: 1420,
    healthy: true,
    conflictCount: 0,
    entries: [],
  );
}

class Daemon extends DaemonController {
  Daemon(Diagnostics api) : super(diagnosticsApi: api);
  int starts = 0, stops = 0;
  bool running = false;
  @override
  Future<bool> hasRoomRuntime() async => running;
  @override
  Future<Map<String, String>?> roomDeviceIdentity(AppSettings settings) async =>
      {
        'public_key': 'local-key',
        'device_name': 'A',
        'platform': 'linux',
        'node_id': 'local',
      };
  @override
  Future<DaemonCommandResult> start(AppSettings settings) async {
    starts++;
    running = true;
    return const DaemonCommandResult(ok: true, message: 'start');
  }

  @override
  Future<DaemonCommandResult> stop(String url) async {
    stops++;
    running = false;
    return const DaemonCommandResult(ok: true, message: 'stop');
  }
}

void main() {
  test(
    'local intent survives restart, serializes writes, and isolates profiles',
    () async {
      final root = await Directory.systemTemp.createTemp('room-preferences-');
      addTearDown(() => root.delete(recursive: true));
      RoomConnectionPreferences preferences() => RoomConnectionPreferences(
        persistent: true,
        directoryForProfile: (profile) => Directory('${root.path}/$profile'),
      );
      final first = preferences();
      await Future.wait([
        first.update('account-a-room-a', autoConnect: true, wanted: true),
        first.update('account-a-room-a', wanted: false),
      ]);
      final restarted = preferences();
      final saved = await restarted.read('account-a-room-a');
      expect(saved.autoConnect, isTrue);
      expect(saved.wanted, isFalse);
      expect((await restarted.read('account-b-room-a')).autoConnect, isFalse);
      expect((await restarted.read('account-a-room-b')).wanted, isFalse);
      await restarted.update('account-a-room-a', wanted: true);
      expect((await preferences().read('account-a-room-a')).wanted, isTrue);
    },
  );

  test(
    'damaged local preferences fail closed instead of auto connecting',
    () async {
      final root = await Directory.systemTemp.createTemp('room-preferences-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/connection.json').writeAsString('{broken');
      final preferences = RoomConnectionPreferences(
        persistent: true,
        directoryForProfile: (_) => root,
      );
      await expectLater(preferences.read('profile'), throwsFormatException);
    },
  );

  late Control control;
  late Diagnostics api;
  late Daemon daemon;
  late AppSettings settings;
  late RoomConnectionPreferences preferences;
  late ParallelRooms manager;
  setUp(() {
    control = Control();
    api = Diagnostics();
    daemon = Daemon(api);
    settings = AppSettings(
      authToken: fixtures.token('member'),
      controlServer: 'https://control.example',
    );
    preferences = RoomConnectionPreferences();
    manager = ParallelRooms(
      readSettings: () => settings,
      supported: true,
      preferences: preferences,
      refreshInterval: Duration.zero,
      runtimeFactory: (plan) => DesktopRoomRuntime(
        plan,
        diagnosticsApi: api,
        daemonController: daemon,
        hasCredentials: () async => false,
        checkRoutes: (_) async => null,
        controlApiFactory: () => control,
      ),
    );
  });
  tearDown(() async {
    await manager.stopAll();
    manager.dispose();
    api.close();
  });
  test(
    'new installation does not opt into automatic room connection',
    () async {
      final p = await manager.connectionPreference(room);
      expect(p.autoConnect, isFalse);
      expect(p.wanted, isFalse);
      await manager.recover(room);
      expect(manager.sessions, isEmpty);
      expect(daemon.starts, 0);
    },
  );
  test(
    'manual connect resumes one paused device; stop preserves membership',
    () async {
      control.state = 'paused';
      expect((await manager.connect(room)).ok, isTrue);
      expect(control.resume, isTrue);
      await manager.setAutoConnect(room, true);
      expect((await manager.disconnect(room.id)).ok, isTrue);
      final p = await manager.connectionPreference(room);
      expect(p.autoConnect, isTrue);
      expect(p.wanted, isFalse);
      expect(control.state, 'allowed');
      expect(daemon.running, isFalse);
    },
  );
  test(
    'automatic start cannot undo remote disconnect, approval, or device ban',
    () async {
      for (final state in ['paused', 'pending', 'blocked']) {
        control.state = state;
        await manager.setAutoConnect(room, true);
        final result = await manager.connect(room, automatic: true);
        expect(result.ok, isFalse);
        expect(control.resume, isFalse);
        expect(daemon.starts, 0);
        expect((await manager.connectionPreference(room)).wanted, isFalse);
      }
    },
  );
  test(
    'recovering remotely disconnected live process stops it and clears intent',
    () async {
      await manager.setAutoConnect(room, true);
      daemon.running = true;
      control.state = 'paused';
      await manager.recover(room);
      expect(daemon.stops, 1);
      expect(manager.sessions, isEmpty);
      expect((await manager.connectionPreference(room)).wanted, isFalse);
    },
  );
  test(
    'app shutdown preserves opt in and profile preferences are isolated',
    () async {
      await manager.setAutoConnect(room, true);
      expect((await manager.connect(room)).ok, isTrue);
      await manager.stopAll();
      expect((await manager.connectionPreference(room)).wanted, isTrue);
      settings = settings.copyWith(authToken: fixtures.token('other'));
      expect((await manager.connectionPreference(room)).autoConnect, isFalse);
      expect(
        (await manager.connectionPreference(fixtures.room(2))).wanted,
        isFalse,
      );
    },
  );
}
