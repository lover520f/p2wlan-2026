import '../api/diagnostics_api.dart';
import '../daemon/daemon_controller.dart';
import '../daemon/diagnostics_auth.dart';
import '../models/diagnostics_models.dart';
import 'parallel_rooms.dart';
import 'room_api.dart';

class DesktopRoomRuntime implements RoomRuntime {
  DesktopRoomRuntime(this.plan) {
    _api = DiagnosticsApi(
      authTokenReader: () => readRoomDiagnosticsAuthToken(plan.profileId),
    );
    _daemon = DaemonController(
      diagnosticsApi: _api,
      roomInstanceId: plan.profileId,
    );
  }

  final ParallelRoomPlan plan;
  late final DiagnosticsApi _api;
  late final DaemonController _daemon;

  @override
  Future<bool> exists() async =>
      await readRoomDiagnosticsAuthToken(plan.profileId) != null;

  @override
  Future<DaemonCommandResult> start() async {
    if (await _api.fetchHealth(plan.settings.diagnosticsUrl) &&
        !await exists()) {
      return const DaemonCommandResult(
        ok: false,
        message: '房间诊断端口被其他进程占用，未停止任何进程。',
      );
    }
    String? authenticatedInterface;
    if (await exists()) {
      try {
        final snapshot = await _api.fetchStatus(plan.settings.diagnosticsUrl);
        if (snapshot.networkId != plan.room.id) {
          return const DaemonCommandResult(ok: false, message: '房间诊断实例身份不匹配');
        }
        final routes = await _api.verifyRoutes(plan.settings.diagnosticsUrl);
        authenticatedInterface = routes.interfaceName;
      } catch (_) {
        authenticatedInterface = null;
      }
    }
    final conflict = await _daemon.roomRouteConflict(
      plan.room.cidr,
      authenticatedInterface: authenticatedInterface,
    );
    if (conflict != null) {
      return DaemonCommandResult(ok: false, message: conflict);
    }
    return _daemon.start(plan.settings);
  }

  @override
  Future<DaemonCommandResult> stop() =>
      _daemon.stop(plan.settings.diagnosticsUrl);

  @override
  Future<DiagnosticsSnapshot> status() async {
    final snapshot = await _api.fetchStatus(plan.settings.diagnosticsUrl);
    if (snapshot.networkId != plan.room.id ||
        !validRoomIp(snapshot.virtualIp, plan.room.cidr)) {
      throw const RoomException('房间运行时身份或地址不匹配');
    }
    final routes = await _api.verifyRoutes(plan.settings.diagnosticsUrl);
    if (!routes.healthy) throw const RoomException('房间路由未通过校验');
    return snapshot;
  }

  @override
  void close() => _api.close();
}
