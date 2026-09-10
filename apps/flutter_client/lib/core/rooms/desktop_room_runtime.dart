import '../api/diagnostics_api.dart';
import '../daemon/daemon_controller.dart';
import '../daemon/diagnostics_auth.dart';
import '../models/diagnostics_models.dart';
import 'parallel_rooms.dart';
import 'room_api.dart';

class DesktopRoomRuntime implements RoomRuntime {
  DesktopRoomRuntime(
    this.plan, {
    DiagnosticsApi? diagnosticsApi,
    DaemonController? daemonController,
    this._hasCredentials,
    this._checkRoutes,
  }) {
    _api =
        diagnosticsApi ??
        DiagnosticsApi(
          authTokenReader: () => readRoomDiagnosticsAuthToken(plan.profileId),
        );
    _daemon =
        daemonController ??
        DaemonController(diagnosticsApi: _api, roomInstanceId: plan.profileId);
  }

  final ParallelRoomPlan plan;
  late final DiagnosticsApi _api;
  late final DaemonController _daemon;
  final Future<bool> Function()? _hasCredentials;
  final Future<String?> Function(String)? _checkRoutes;

  Future<bool> _credentialsExist() async => _hasCredentials != null
      ? await _hasCredentials()
      : await readRoomDiagnosticsAuthToken(plan.profileId) != null;

  @override
  Future<bool> exists() => _daemon.hasRoomRuntime();

  @override
  Future<DaemonCommandResult> start() async {
    if (await _api.fetchHealth(plan.settings.diagnosticsUrl) &&
        !await _credentialsExist()) {
      return const DaemonCommandResult(
        ok: false,
        message: '房间诊断端口被其他进程占用，未停止任何进程。',
      );
    }
    if (await _credentialsExist() || await exists()) {
      try {
        final snapshot = await _api.fetchStatus(plan.settings.diagnosticsUrl);
        if (snapshot.networkId != plan.room.id) {
          return const DaemonCommandResult(
            ok: false,
            message: '房间诊断实例身份不匹配，未修改现有连接',
          );
        }
      } catch (_) {
        // stop() also verifies the per-profile PID and exact process arguments.
      }
      final stopped = await _daemon.stop(plan.settings.diagnosticsUrl);
      if (!stopped.ok) {
        return DaemonCommandResult(
          ok: false,
          message: '此房间的旧连接未能退出：${stopped.message}',
        );
      }
    }
    final conflict = _checkRoutes != null
        ? await _checkRoutes(plan.room.cidr)
        : await _daemon.roomRouteConflict(plan.room.cidr);
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
