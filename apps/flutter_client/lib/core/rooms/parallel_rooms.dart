import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../daemon/daemon_controller.dart';
import '../models/diagnostics_models.dart';
import 'room_api.dart';
import 'room_profiles.dart';

enum RoomConnectionPhase { starting, running, unavailable, stopping, failed }

class ParallelRoomPlan {
  ParallelRoomPlan(AppSettings account, this.room) {
    final selected = selectRoomSettings(account, room);
    profileId = roomProfileId(selected);
    final port =
        40000 + int.parse(profileId.substring(0, 8), radix: 16) % 20000;
    settings = selected.copyWith(
      diagnosticsUrl: 'http://127.0.0.1:$port/status',
      tunInterface: 'p2r${profileId.substring(0, 12)}',
      udpBind: '0.0.0.0:0',
      udpAdvertise: '',
    );
  }

  final FriendRoom room;
  late final String profileId;
  late final AppSettings settings;
}

abstract interface class RoomRuntime {
  Future<bool> exists();
  Future<DaemonCommandResult> start();
  Future<DaemonCommandResult> stop();
  Future<DiagnosticsSnapshot> status();
  void close();
}

class ParallelRoomSession {
  ParallelRoomSession(this.plan, this.runtime);
  final ParallelRoomPlan plan;
  final RoomRuntime runtime;
  RoomConnectionPhase phase = RoomConnectionPhase.starting;
  DiagnosticsSnapshot? snapshot;
  String? message;
  bool refreshing = false;
  int revision = 0;
}

typedef RoomRuntimeFactory = RoomRuntime Function(ParallelRoomPlan plan);

class ParallelRooms extends ChangeNotifier {
  ParallelRooms({
    required this.readSettings,
    required this.runtimeFactory,
    bool? supported,
    this.maxConnections = 8,
    this.refreshInterval = const Duration(seconds: 5),
  }) : supported = supported ?? platformSupported {
    if (maxConnections < 1 || maxConnections > 32) {
      throw ArgumentError.value(maxConnections, 'maxConnections');
    }
    _credentials = _credentialKey(readSettings());
  }

  static bool get platformSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  final AppSettings Function() readSettings;
  final RoomRuntimeFactory runtimeFactory;
  final bool supported;
  final int maxConnections;
  final Duration refreshInterval;
  final _sessions = <String, ParallelRoomSession>{};
  final _operations = <String, Future<DaemonCommandResult>>{};
  final _recovering = <String>{};
  Timer? _timer;
  var _credentials = '';
  var _epoch = 0;
  var _admissionPauses = 0;
  var _disposed = false;
  Future<DaemonCommandResult>? _stoppingAll;
  String? lastError;

  Map<String, ParallelRoomSession> get sessions => Map.unmodifiable(_sessions);
  bool get hasSessions =>
      _sessions.isNotEmpty || _operations.isNotEmpty || _recovering.isNotEmpty;
  int get activeConnections => _sessions.length;
  bool get connectionsPaused => _admissionPauses > 0;
  bool get stoppingAll => _stoppingAll != null;
  bool get busy =>
      _operations.isNotEmpty || _stoppingAll != null || connectionsPaused;
  ParallelRoomSession? session(String roomId) => _sessions[roomId];

  String _credentialKey(AppSettings value) =>
      '${value.controlServer}\n${value.authToken}';

  Future<DaemonCommandResult> credentialsChanged() {
    _credentials = _credentialKey(readSettings());
    _epoch++;
    return stopAll();
  }

  Future<T> withConnectionsPaused<T>(Future<T> Function() action) {
    _admissionPauses++;
    _epoch++;
    _notify();
    try {
      final future = action();
      return future.whenComplete(() {
        _admissionPauses--;
        _notify();
      });
    } catch (_) {
      _admissionPauses--;
      _notify();
      rethrow;
    }
  }

  Future<DaemonCommandResult> connect(FriendRoom room) {
    if (!supported) return Future.value(_fail('当前平台尚未接入多房间并行运行时'));
    if (_disposed || _stoppingAll != null || connectionsPaused) {
      return Future.value(_fail('网络正在关闭，未启动房间'));
    }
    if (_credentialKey(readSettings()) != _credentials) {
      return credentialsChanged().then(
        (result) => result.ok ? connect(room) : result,
      );
    }
    final epoch = _epoch;
    final credentials = _credentialKey(readSettings());
    return _enqueue(room.id, () => _connect(room, epoch, credentials));
  }

  Future<DaemonCommandResult> disconnect(String roomId) =>
      _stoppingAll ?? _enqueue(roomId, () => _disconnect(roomId));

  Future<DaemonCommandResult> _enqueue(
    String id,
    Future<DaemonCommandResult> Function() action,
  ) {
    if (_disposed) return Future.value(_fail('房间管理器已经关闭'));
    final previous = _operations[id];
    final future = (previous ?? Future.value(_ok())).then((_) async {
      try {
        return await action();
      } catch (_) {
        return _fail('房间操作失败，请检查本地服务和控制服务器');
      }
    });
    _operations[id] = future;
    unawaited(
      future.then((_) {
        if (identical(_operations[id], future)) _operations.remove(id);
        _notify();
      }),
    );
    return future;
  }

  bool _accepts(int epoch, String credentials) =>
      !_disposed &&
      _stoppingAll == null &&
      !connectionsPaused &&
      epoch == _epoch &&
      credentials == _credentialKey(readSettings());

  Future<DaemonCommandResult> _connect(
    FriendRoom room,
    int epoch,
    String credentials,
  ) async {
    if (!_accepts(epoch, credentials)) return _fail('登录状态已变化，已取消连接');
    if (_sessions.values.any(
      (entry) => _credentialKey(entry.plan.settings) != credentials,
    )) {
      return _fail('上一个登录会话仍有未停止的房间，请先全部断开');
    }
    final existing = _sessions[room.id];
    if (existing != null) {
      if (existing.phase == RoomConnectionPhase.running) return _ok();
      return _fail('房间已有运行时，请先断开后重连');
    }
    if (_sessions.length >= maxConnections) {
      return _fail('已达到并行房间上限 $maxConnections');
    }
    final account = readSettings();
    final plan = ParallelRoomPlan(account, room);
    final conflict = _conflict(plan, account);
    if (conflict != null) return _fail(conflict);
    final entry = ParallelRoomSession(plan, runtimeFactory(plan));
    _sessions[room.id] = entry;
    _notify();
    DaemonCommandResult started;
    try {
      started = await entry.runtime.start();
    } catch (_) {
      started = _fail('房间启动失败，需要清理本地运行时');
    }
    if (!started.ok || !_accepts(epoch, credentials)) {
      final cleanup = await _disconnect(room.id);
      return cleanup.ok
          ? (started.ok ? _fail('登录状态已变化，连接已取消') : started)
          : cleanup;
    }
    await _refresh(entry);
    _ensureTimer();
    if (entry.phase != RoomConnectionPhase.running) {
      return _fail('房间进程已启动，但地址或路由尚未就绪；可重试状态检查或断开');
    }
    return started;
  }

  String? _conflict(ParallelRoomPlan plan, AppSettings account) {
    if (account.networkId == plan.room.id) return '此房间仍被主网络使用，请先切回个人网络';
    if (cidrsOverlap(account.overlayCidr, plan.room.cidr)) {
      return '房间网段与主网络配置重叠';
    }
    if (Uri.tryParse(account.diagnosticsUrl)?.port ==
        Uri.parse(plan.settings.diagnosticsUrl).port) {
      return '房间诊断端口与主网络配置冲突';
    }
    for (final session in _sessions.values) {
      final other = session.plan;
      if (cidrsOverlap(other.room.cidr, plan.room.cidr)) return '房间网段与已连接房间重叠';
      if (other.settings.diagnosticsUrl == plan.settings.diagnosticsUrl ||
          other.settings.tunInterface == plan.settings.tunInterface) {
        return '房间运行时资源标识冲突，未修改其他房间';
      }
    }
    return null;
  }

  Future<DaemonCommandResult> _disconnect(String id) async {
    final entry = _sessions[id];
    if (entry == null) return _ok();
    entry.revision++;
    entry.phase = RoomConnectionPhase.stopping;
    entry.snapshot = null;
    _notify();
    DaemonCommandResult result;
    try {
      result = await entry.runtime.stop();
    } catch (_) {
      result = _fail('无法确认房间运行时已停止');
    }
    if (result.ok) {
      _sessions.remove(id);
      entry.runtime.close();
    } else {
      entry.phase = RoomConnectionPhase.failed;
      entry.message = '停止失败，运行时仍被保留，请重试断开';
      lastError = entry.message;
    }
    if (_sessions.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
    _notify();
    return result;
  }

  Future<DaemonCommandResult> stopAll() {
    final pending = _stoppingAll;
    if (pending != null) return pending;
    final completer = Completer<DaemonCommandResult>();
    _stoppingAll = completer.future;
    _epoch++;
    unawaited(() async {
      try {
        await Future.wait(_operations.values.toList());
        final results = await Future.wait(
          _sessions.keys.toList().map(_disconnect),
        );
        final failed = results.any((result) => !result.ok);
        final forced = results.any((result) => result.forcedTermination);
        completer.complete(
          DaemonCommandResult(
            ok: !failed,
            message: failed ? '部分房间未能停止，请重试；尚未清除运行时记录' : '所有并行房间已停止',
            graceful:
                !failed &&
                !forced &&
                results.every((result) => result.graceful),
            forcedTermination: forced,
          ),
        );
      } catch (_) {
        completer.complete(_fail('关闭房间失败，尚未确认资源释放'));
      } finally {
        _stoppingAll = null;
        _notify();
      }
    }());
    return completer.future;
  }

  Future<void> recoverJoinedRooms() async {
    if (!supported || _disposed || _stoppingAll != null || connectionsPaused) {
      return;
    }
    final account = readSettings();
    if (account.authToken.trim().isEmpty) return;
    RoomApi? api;
    try {
      api = RoomApi(server: account.controlServer, token: account.authToken);
      final rooms = await api.list();
      if (_credentialKey(account) != _credentialKey(readSettings())) return;
      for (final room in rooms) {
        await recover(room);
      }
    } catch (_) {
      lastError = '无法恢复房间运行时，请检查登录和控制服务器';
      _notify();
    } finally {
      api?.close();
    }
  }

  Future<void> recover(FriendRoom room) async {
    if (!supported ||
        _disposed ||
        _stoppingAll != null ||
        connectionsPaused ||
        _sessions.containsKey(room.id) ||
        !_recovering.add(room.id)) {
      return;
    }
    try {
      await _enqueue(room.id, () async {
        if (_sessions.containsKey(room.id) ||
            _stoppingAll != null ||
            connectionsPaused) {
          return _ok();
        }
        final account = readSettings();
        final plan = ParallelRoomPlan(account, room);
        if (_conflict(plan, account) != null ||
            _sessions.length >= maxConnections) {
          return _ok();
        }
        final runtime = runtimeFactory(plan);
        final entry = ParallelRoomSession(plan, runtime);
        _sessions[room.id] = entry;
        try {
          if (!await runtime.exists()) {
            _sessions.remove(room.id);
            runtime.close();
            return _ok();
          }
        } catch (_) {
          entry.phase = RoomConnectionPhase.failed;
          entry.message = '无法确认房间进程状态，请重试断开';
          return _fail(entry.message!);
        }
        if (_credentialKey(account) != _credentialKey(readSettings()) ||
            _stoppingAll != null) {
          return _disconnect(room.id);
        }
        await _refresh(entry);
        _ensureTimer();
        return _ok();
      });
    } finally {
      _recovering.remove(room.id);
      _notify();
    }
  }

  Future<void> _refresh(ParallelRoomSession entry) async {
    if (entry.refreshing || entry.phase == RoomConnectionPhase.stopping) return;
    entry.refreshing = true;
    final revision = entry.revision;
    try {
      final snapshot = await entry.runtime.status();
      if (_disposed ||
          revision != entry.revision ||
          !identical(_sessions[entry.plan.room.id], entry)) {
        return;
      }
      if (snapshot.networkId != entry.plan.room.id ||
          !validRoomIp(snapshot.virtualIp, entry.plan.room.cidr)) {
        throw const RoomException('房间运行时身份不匹配');
      }
      entry.snapshot = snapshot;
      entry.phase = RoomConnectionPhase.running;
      entry.message = null;
    } catch (_) {
      if (!_disposed &&
          revision == entry.revision &&
          identical(_sessions[entry.plan.room.id], entry)) {
        entry.snapshot = null;
        entry.phase = RoomConnectionPhase.unavailable;
        entry.message = '运行时或路由不可用；未显示过期的在线状态';
      }
    } finally {
      entry.refreshing = false;
      _notify();
    }
  }

  void _ensureTimer() {
    if (_disposed || refreshInterval <= Duration.zero || _timer != null) return;
    _timer = Timer.periodic(refreshInterval, (_) {
      for (final entry in _sessions.values.toList()) {
        if (entry.phase != RoomConnectionPhase.starting &&
            entry.phase != RoomConnectionPhase.stopping &&
            entry.phase != RoomConnectionPhase.failed) {
          unawaited(_refresh(entry));
        }
      }
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    unawaited(stopAll());
    super.dispose();
  }

  static DaemonCommandResult _ok() =>
      const DaemonCommandResult(ok: true, message: '完成', graceful: true);
  static DaemonCommandResult _fail(String message) =>
      DaemonCommandResult(ok: false, message: message);
}

bool cidrsOverlap(String left, String right) {
  (int, int)? range(String text) {
    final parts = text.split('/');
    if (parts.length != 2) return null;
    final ip = InternetAddress.tryParse(parts[0]);
    final prefix = int.tryParse(parts[1]);
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        prefix == null ||
        prefix < 0 ||
        prefix > 32) {
      return null;
    }
    final address = ip.rawAddress.fold<int>(
      0,
      (value, byte) => (value << 8) | byte,
    );
    final mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
    final start = address & mask;
    return (start, start | (0xffffffff ^ mask));
  }

  final a = range(left);
  final b = range(right);
  return a == null || b == null || (a.$1 <= b.$2 && b.$1 <= a.$2);
}
