import 'package:flutter_test/flutter_test.dart';
import 'package:p2wlan_flutter_client/core/api/diagnostics_api.dart';
import 'package:p2wlan_flutter_client/core/daemon/daemon_controller.dart';
import 'package:p2wlan_flutter_client/core/models/diagnostics_models.dart';
import 'package:p2wlan_flutter_client/core/rooms/desktop_room_runtime.dart';
import 'package:p2wlan_flutter_client/core/rooms/parallel_rooms.dart';
import 'package:p2wlan_flutter_client/core/rooms/route_inventory.dart';

import 'parallel_rooms_test.dart' as fixtures;

class _RoomApi extends DiagnosticsApi {
  _RoomApi(this.plan);
  final ParallelRoomPlan plan;
  bool wrongNetwork = false;
  bool brokenStatus = true;
  @override
  Future<bool> fetchHealth(String url) async => false;
  @override
  Future<DiagnosticsSnapshot> fetchStatus(String url) async {
    if (brokenStatus) throw StateError('stale process');
    return DiagnosticsSnapshot.fromJson({
      'network_id': wrongNetwork ? 'another-room' : plan.room.id,
      'virtual_ip': '10.21.1.2',
    });
  }
}

class _RoomDaemon extends DaemonController {
  _RoomDaemon(_RoomApi api) : super(diagnosticsApi: api);
  final operations = <String>[];
  bool stopWorks = true;
  String? conflict;
  @override
  Future<DaemonCommandResult> stop(String url) async {
    operations.add('stop');
    return DaemonCommandResult(ok: stopWorks, message: 'stop');
  }

  @override
  Future<DaemonCommandResult> start(AppSettings settings) async {
    operations.add('start');
    return const DaemonCommandResult(ok: true, message: 'start');
  }
}

void main() {
  late _RoomApi api;
  late _RoomDaemon daemon;
  late DesktopRoomRuntime runtime;
  setUp(() {
    final plan = ParallelRoomPlan(
      AppSettings(
        authToken: fixtures.token('a'),
        controlServer: 'https://control.example',
      ),
      fixtures.room(1),
    );
    api = _RoomApi(plan);
    daemon = _RoomDaemon(api);
    runtime = DesktopRoomRuntime(
      plan,
      diagnosticsApi: api,
      daemonController: daemon,
      hasCredentials: () async => true,
      checkRoutes: (cidr) async {
        daemon.operations.add('routes');
        return daemon.conflict;
      },
    );
  });
  tearDown(() => runtime.close());

  test('own stale runtime is stopped before checking routes', () async {
    expect((await runtime.start()).ok, isTrue);
    expect(daemon.operations, ['stop', 'routes', 'start']);
  });
  test(
    'failed stale cleanup does not ignore overlapping routes or launch',
    () async {
      daemon.stopWorks = false;
      expect((await runtime.start()).ok, isFalse);
      expect(daemon.operations, ['stop']);
    },
  );
  test(
    'a real conflicting VPN still blocks launch after own cleanup',
    () async {
      daemon.conflict = nativeRoomConflictMessage(
        '10.21.1.0/24',
        const NativeIpv4Route('10.0.0.0/8', 'Other VPN'),
      );
      final result = await runtime.start();
      expect(result.ok, isFalse);
      expect(result.message, contains('Other VPN'));
      expect(daemon.operations, ['stop', 'routes']);
    },
  );
  test('authenticated different room is never stopped', () async {
    api.brokenStatus = false;
    api.wrongNetwork = true;
    expect((await runtime.start()).ok, isFalse);
    expect(daemon.operations, isEmpty);
  });
}
