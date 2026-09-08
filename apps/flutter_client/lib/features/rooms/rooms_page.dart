import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/capabilities/platform_capabilities.dart';
import '../../core/rooms/room_api.dart';
import '../../core/rooms/room_profiles.dart';
import '../../core/rooms/parallel_rooms.dart';
import '../../core/state/settings_store.dart';
import '../../core/state/status_store.dart';

class RoomsPage extends StatefulWidget {
  const RoomsPage({
    super.key,
    required this.settingsStore,
    required this.statusStore,
    this.initialInvitation,
    this.api,
    this.capabilities,
  });
  final SettingsStore settingsStore;
  final StatusStore statusStore;
  final Uri? initialInvitation;
  final RoomApi? api;
  final PlatformCapabilities? capabilities;
  @override
  State<RoomsPage> createState() => _RoomsPageState();
}

class _RoomsPageState extends State<RoomsPage> {
  RoomApi? _apiInstance;
  RoomApi get _api => _apiInstance!;
  List<FriendRoom> _rooms = [];
  RoomRoster? _roster;
  List<Map<String, dynamic>> _invites = [];
  String? _selectedId;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _refreshing = false;
  Timer? _timer;
  int _generation = 0;

  ParallelRooms get _parallel => widget.statusStore.parallelRooms;

  void _parallelChanged() {
    if (mounted) setState(() {});
  }

  bool get _canConnect =>
      (widget.capabilities ?? PlatformCapabilities.current())
          .canActAsLocalVpnNode;
  bool get _sameSession {
    if (_apiInstance == null) return false;
    try {
      return widget.settingsStore.settings.authToken == _api.token &&
          roomControlServer(widget.settingsStore.settings.controlServer) ==
              _api.server;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _parallel.addListener(_parallelChanged);
    final settings = widget.settingsStore.settings;
    try {
      if (settings.authToken.trim().isEmpty) {
        throw const RoomException('请先登录控制服务器后使用好友房间');
      }
      _apiInstance =
          widget.api ??
          RoomApi(server: settings.controlServer, token: settings.authToken);
    } catch (error) {
      _error = _message(error);
      _loading = false;
      return;
    }
    if (isRoomNetwork(settings.networkId)) _selectedId = settings.networkId;
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy && !_refreshing) unawaited(_refresh(silent: true));
    });
    if (widget.initialInvitation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_joinWithLink(widget.initialInvitation.toString()));
        }
      });
    }
  }

  @override
  void dispose() {
    _parallel.removeListener(_parallelChanged);
    _timer?.cancel();
    _generation++;
    if (widget.api == null) _apiInstance?.close();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!mounted || !_sameSession || _refreshing) return;
    _refreshing = true;
    final generation = ++_generation;
    final selected = _selectedId;
    try {
      final rooms = await _api.list();
      if (!_sameSession) return;
      if (_parallel.supported) {
        for (final room in rooms) {
          unawaited(_parallel.recover(room));
        }
      }
      final id = rooms.any((room) => room.id == selected)
          ? selected
          : (rooms.isEmpty ? null : rooms.first.id);
      final roster = id == null ? null : await _api.roster(id);
      final invites = roster?.room.isOwner == true
          ? (await _api.request('GET', [id!, 'invites']))['invites'] as List? ??
                const []
          : const [];
      if (!mounted || generation != _generation || !_sameSession) return;
      setState(() {
        _rooms = rooms;
        _selectedId = id;
        _roster = roster;
        _invites = invites
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = _message(error));
      }
    } finally {
      _refreshing = false;
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String _message(Object error) =>
      error is RoomException ? error.message : '操作未完成，请检查连接后重试';

  Future<void> _run(
    Future<void> Function() operation, {
    String? success,
  }) async {
    if (_busy || !mounted) return;
    if (!_sameSession) {
      setState(() => _error = '登录账号或服务器已变化，请返回后重新打开房间');
      return;
    }
    _generation++;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
      if (mounted && success != null) _notify(success);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _refresh();
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<List<String>?> _form(
    String title,
    List<_RoomField> fields, {
    String? description,
  }) async {
    if (!_sameSession) {
      setState(() => _error = '请先登录当前控制服务器后使用好友房间');
      return null;
    }
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _RoomInputDialog(
        title: title,
        fields: fields,
        description: description,
      ),
    );
  }

  _RoomField get _passwordField => _RoomField(
    '房间密码',
    secret: true,
    maxLength: 72,
    hint: '8–72 字节，不会写入分享链接',
    validate: (value) {
      final length = utf8.encode(value ?? '').length;
      return length < 8 || length > 72 ? '密码需为 8–72 字节' : null;
    },
  );
  _RoomField _nameField([String initial = '']) => _RoomField(
    '房间名称',
    initial: initial,
    maxLength: 64,
    validate: (value) =>
        value == null ||
            value.trim().isEmpty ||
            value.runes.length > 64 ||
            RegExp(r'[\r\n\x00]').hasMatch(value)
        ? '请输入 1–64 个字符的名称'
        : null,
  );

  Future<void> _create() async {
    final values = await _form('创建好友房间', [
      _nameField(),
      _passwordField,
    ], description: '每个账号可以创建一个房间。服务器会分配独立的 10.21.x.0/24 网段，不改变你的个人网络。');
    if (values == null || !mounted) return;
    await _run(() async {
      _selectedId = (await _api.create(values[0].trim(), values[1])).id;
    }, success: '房间已创建');
  }

  Future<void> _join() async {
    final values = await _form('通过房间号加入', [
      _RoomField(
        '房间号',
        maxLength: 8,
        number: true,
        validate: (value) => RegExp(r'^[0-9]{8}$').hasMatch(value?.trim() ?? '')
            ? null
            : '请输入 8 位房间号',
      ),
      _passwordField,
    ], description: '加入后可在房间列表中连接此网络。加入多个房间不会自动把不同房间桥接在一起。');
    if (values == null || !mounted) return;
    await _run(() async {
      _selectedId = (await _api.join(values[0].trim(), password: values[1])).id;
    }, success: '已加入房间');
  }

  Future<void> _joinWithLink([String initial = '']) async {
    if (!mounted || _busy) return;
    final values = await _form('通过邀请链接加入', [
      _RoomField(
        '邀请链接',
        initial: initial,
        multiline: true,
        maxLength: 4096,
        validate: (value) {
          try {
            RoomInvitation.parse(value ?? '', _api.server);
            return null;
          } catch (error) {
            return _message(error);
          }
        },
      ),
    ], description: '仅加入当前控制服务器上的房间。确认前不会发送邀请，也不会自动切换服务器。');
    if (values == null || !mounted) return;
    await _run(() async {
      final invite = RoomInvitation.parse(values[0], _api.server);
      _selectedId = (await _api.join(invite.code, invitation: invite.token)).id;
    }, success: '已通过邀请加入房间');
  }

  Future<void> _connect(FriendRoom? room) async {
    if (!_canConnect || _busy) return;
    if (_parallel.supported && room != null) {
      await _run(() async {
        if (widget.settingsStore.settings.networkId == room.id) {
          final stopped = await widget.statusStore.stopPrimaryDaemon();
          if (!stopped.ok) throw const RoomException('旧的单房间运行时未能停止');
          await widget.settingsStore.updateSettings(
            personalNetworkSettings(widget.settingsStore.settings),
          );
        }
        if (!mounted || !_sameSession) return;
        final result = await _parallel.connect(room);
        if (!result.ok) throw RoomException(result.message);
      }, success: '房间已独立启动，不影响其他并行房间');
      return;
    }
    final name = room?.name ?? '个人网络';
    if (!await _confirm(
          '连接$name',
          _parallel.supported
              ? '将启动个人网络，已连接的并行房间保持运行。'
              : '此平台仍使用单活动网络，将断开当前网络后连接$name。',
        ) ||
        !mounted) {
      return;
    }
    await _run(() async {
      final stopped = await widget.statusStore.stopPrimaryDaemon();
      if (!stopped.ok) throw const RoomException('旧网络未能停止，未切换网络');
      if (!mounted || !_sameSession) return;
      final current = widget.settingsStore.settings;
      final next = room == null
          ? (isRoomNetwork(current.networkId)
                ? personalNetworkSettings(current)
                : current)
          : selectRoomSettings(current, room);
      if (room != null) roomProfileId(next);
      await widget.settingsStore.updateSettings(next);
      if (!mounted || !_sameSession) return;
      final started = await widget.statusStore.startDaemon();
      if (!started.ok) throw RoomException(started.message);
    }, success: '网络连接已启动');
  }

  Future<void> _disconnectRoom(FriendRoom room) async {
    await _run(() async {
      final result = await _parallel.disconnect(room.id);
      if (!result.ok) throw RoomException(result.message);
    }, success: '已断开此房间，其他房间保持运行');
  }

  Future<void> _edit(FriendRoom room, bool password) async {
    final values = await _form(
      password ? '更改房间密码' : '重命名房间',
      [password ? _passwordField : _nameField(room.name)],
      description: password
          ? '更改密码会同时撤销所有现有邀请链接。已加入成员不受影响；要阻止其再次加入，请封禁账号。'
          : null,
    );
    if (values == null || !mounted) return;
    await _run(() async {
      await _api.request(
        'PATCH',
        [room.id],
        {
          password ? 'password' : 'name': password
              ? values[0]
              : values[0].trim(),
        },
      );
    }, success: '房间设置已保存');
  }

  Future<void> _issueInvite(FriendRoom room) async {
    final values = await _form('生成邀请链接', [
      _RoomField(
        '有效小时数',
        initial: '24',
        number: true,
        validate: (v) => _range(v, 1, 168),
      ),
      _RoomField(
        '最多加入账号数',
        initial: '10',
        number: true,
        validate: (v) => _range(v, 1, 1000),
      ),
    ], description: '链接持有者可免密码加入。可以随时撤销；同一账号重复加入不重复消耗次数。');
    if (values == null || !mounted) return;
    await _run(() async {
      final data = await _api.request(
        'POST',
        [room.id, 'invites'],
        {
          'ttl_seconds': int.parse(values[0].trim()) * 3600,
          'max_uses': int.parse(values[1].trim()),
        },
      );
      final token = data['invite_token'] as String? ?? '';
      final link = RoomInvitation(
        _api.server,
        room.code,
        token,
      ).toUri().toString();
      RoomInvitation.parse(link, _api.server);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('分享房间'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${room.name} · ${room.code}'),
                  const SizedBox(height: 12),
                  const Text('此链接仅在本次生成后显示。只发送给可信好友；好友可点击链接，或在 P2WLAN 中粘贴加入。'),
                  const SizedBox(height: 12),
                  SelectableText(link),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('复制邀请链接'),
            ),
          ],
        ),
      );
    });
  }

  String? _range(String? value, int min, int max) {
    final number = int.tryParse(value?.trim() ?? '');
    return number == null || number < min || number > max
        ? '请输入 $min–$max 的整数'
        : null;
  }

  Future<void> _removeMember(FriendRoom room, String user, bool ban) async {
    if (!await _confirm(
          ban ? '封禁成员' : '移除成员',
          ban
              ? '该账号的所有房间设备将断开，解除封禁前无法再次加入。'
              : '该账号的所有房间设备将断开，但持有有效密码或邀请时仍可重新加入。',
        ) ||
        !mounted) {
      return;
    }
    await _run(() async {
      await _api.request(ban ? 'PUT' : 'DELETE', [
        room.id,
        ban ? 'bans' : 'members',
        user,
      ]);
    }, success: ban ? '成员已封禁' : '成员已移除');
  }

  Future<void> _changeIp(FriendRoom room, Map<String, dynamic> device) async {
    final values = await _form('分配设备 IP', [
      _RoomField(
        '虚拟 IP',
        initial: device['virtual_ip'] as String? ?? '',
        maxLength: 15,
        validate: (value) => validRoomIp(value?.trim() ?? '', room.cidr)
            ? null
            : '请输入 ${room.cidr} 中的可用主机地址',
      ),
    ], description: 'IP 不得与其他设备重复。保存后旧连接和凭证将被撤销，该设备需要重新连接房间。');
    if (values == null || !mounted) return;
    await _run(() async {
      await _api.request(
        'PATCH',
        [room.id, 'devices', device['id'] as String],
        {'virtual_ip': values[0].trim()},
      );
    }, success: 'IP 已分配，请让该设备重新连接房间');
  }

  Future<void> _deleteDevice(
    FriendRoom room,
    Map<String, dynamic> device,
  ) async {
    if (!await _confirm('删除房间设备', '将断开该设备。其账号仍是成员，可以重新连接；要阻止重新加入，请封禁账号。') ||
        !mounted) {
      return;
    }
    await _run(() async {
      await _api.request('DELETE', [
        room.id,
        'devices',
        device['id'] as String,
      ]);
    }, success: '房间设备已删除');
  }

  Future<void> _leave(FriendRoom room) async {
    if (!await _confirm(
          room.isOwner ? '解散房间' : '退出房间',
          room.isOwner
              ? '将移除所有成员并撤销房间凭证。此操作不可恢复，重新创建会获得新房间号。'
              : '你的房间设备会被移除，个人网络和其他房间不受影响。',
        ) ||
        !mounted) {
      return;
    }
    await _run(() async {
      final result = await _parallel.disconnect(room.id);
      if (!result.ok) throw const RoomException('本地并行房间未能停止，尚未退出');
      if (widget.settingsStore.settings.networkId == room.id) {
        if (_canConnect) {
          final stopped = await widget.statusStore.stopPrimaryDaemon();
          if (!stopped.ok) throw const RoomException('本地房间网络无法停止，尚未退出房间');
        }
      }
      await _api.request(room.isOwner ? 'DELETE' : 'POST', [
        room.id,
        if (!room.isOwner) 'leave',
      ]);
      if (widget.settingsStore.settings.networkId == room.id) {
        await widget.settingsStore.updateSettings(
          personalNetworkSettings(widget.settingsStore.settings),
        );
      }
      _selectedId = null;
    }, success: room.isOwner ? '房间已解散' : '已退出房间');
  }

  Widget _roomList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.devices_rounded),
          title: const Text('个人网络'),
          subtitle: const Text('保持原有设备与 IP，不向房间公开'),
          trailing: _canConnect
              ? IconButton(
                  tooltip: '返回个人网络',
                  onPressed: _busy ? null : () => _connect(null),
                  icon: const Icon(Icons.login_rounded),
                )
              : null,
        ),
      ),
      const SizedBox(height: 12),
      if (_rooms.isEmpty && !_loading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '还没有加入房间\n创建一个房间，或向好友索取房间号与密码。',
            textAlign: TextAlign.center,
          ),
        ),
      for (final room in _rooms)
        Card(
          child: ListTile(
            selected: room.id == _selectedId,
            leading: Icon(
              room.isOwner ? Icons.home_work_rounded : Icons.group_rounded,
            ),
            title: Text(
              room.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${room.code} · ${room.isOwner ? '房主' : '成员'}\n${room.cidr}'
              '${_parallel.session(room.id) == null ? '' : ' · 独立运行时'}',
            ),
            isThreeLine: true,
            trailing: room.locked
                ? const Icon(Icons.lock_outline_rounded, size: 18)
                : null,
            onTap: _busy
                ? null
                : () {
                    setState(() {
                      _selectedId = room.id;
                      _roster = null;
                      _loading = true;
                    });
                    _generation++;
                    if (_refreshing) {
                      Future<void>.delayed(
                        const Duration(milliseconds: 100),
                        () async {
                          while (mounted && _refreshing) {
                            await Future<void>.delayed(
                              const Duration(milliseconds: 100),
                            );
                          }
                          if (mounted) await _refresh();
                        },
                      );
                    } else {
                      unawaited(_refresh());
                    }
                  },
          ),
        ),
    ],
  );

  Widget _roomDetails(RoomRoster roster) {
    final room = roster.room;
    final connection = _parallel.session(room.id);
    final active =
        connection != null ||
        widget.settingsStore.settings.networkId == room.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room.name,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                SelectableText('房间号 ${room.code}  ·  ${room.cidr}'),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_canConnect)
                      FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => connection != null
                                  ? _disconnectRoom(room)
                                  : _connect(room),
                        icon: Icon(
                          connection == null
                              ? Icons.lan_outlined
                              : Icons.link_off,
                        ),
                        label: Text(
                          connection != null
                              ? '断开此房间'
                              : active
                              ? (_parallel.supported ? '迁移为并行连接' : '重新连接房间')
                              : '连接房间网络',
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () async {
                              await Clipboard.setData(
                                ClipboardData(text: room.code),
                              );
                              if (mounted) _notify('房间号已复制');
                            },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('复制房间号'),
                    ),
                    if (room.isOwner)
                      OutlinedButton.icon(
                        onPressed: _busy || room.locked
                            ? null
                            : () => _issueInvite(room),
                        icon: const Icon(Icons.link_rounded),
                        label: const Text('生成邀请'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  connection != null
                      ? '${connection.phase.name} · ${connection.snapshot?.virtualIp ?? '等待地址'}'
                            '\n${connection.message ?? '独立网卡、连接及路由；断开本房间不会停止其他房间。'}'
                      : active
                      ? (_parallel.supported
                            ? '这是旧的单活动网络，连接后迁移为独立运行时。'
                            : '这是当前选择的单活动网络。')
                      : _parallel.supported
                      ? '点击连接会独立注册本设备，并与其他已连接房间同时运行。'
                      : '当前平台仍为单活动网络，不支持多个房间同时联网。',
                ),
                if (!_canConnect) const Text('此平台仅支持房间管理，不能创建本地虚拟网卡。'),
                if (room.isOwner) ...[
                  const Divider(height: 28),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('锁定新成员加入'),
                    subtitle: const Text('锁定后密码和邀请都无法添加新成员'),
                    value: room.locked,
                    onChanged: _busy
                        ? null
                        : (value) => _run(() async {
                            await _api.request(
                              'PATCH',
                              [room.id],
                              {'join_locked': value},
                            );
                          }),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: _busy ? null : () => _edit(room, false),
                        child: const Text('重命名'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _edit(room, true),
                        child: const Text('更改密码'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '成员 · ${roster.members.length}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final member in roster.members)
          Card(
            child: ListTile(
              leading: Icon(
                member['role'] == 'owner'
                    ? Icons.star_outline_rounded
                    : Icons.person_outline_rounded,
              ),
              title: SelectableText(member['user_id'] as String? ?? ''),
              subtitle: Text(member['role'] == 'owner' ? '房主' : '成员'),
              trailing: room.isOwner && member['role'] != 'owner'
                  ? PopupMenuButton<bool>(
                      enabled: !_busy,
                      onSelected: (ban) =>
                          _removeMember(room, member['user_id'] as String, ban),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: false, child: Text('移除成员')),
                        PopupMenuItem(value: true, child: Text('封禁成员')),
                      ],
                    )
                  : null,
            ),
          ),
        const SizedBox(height: 16),
        Text(
          '房间设备 · ${roster.devices.length}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (roster.devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('连接房间网络后，本设备才会出现在这里。'),
          ),
        for (final device in roster.devices)
          Card(
            child: ListTile(
              leading: Icon(
                device['online'] == true
                    ? Icons.computer_rounded
                    : Icons.computer_outlined,
              ),
              title: Text(device['device_name'] as String? ?? '设备'),
              subtitle: SelectableText(
                '${device['virtual_ip'] ?? ''} · ${device['online'] == true ? '在线' : '离线'}\n${device['user_id'] ?? ''}',
              ),
              isThreeLine: true,
              trailing: room.isOwner
                  ? PopupMenuButton<String>(
                      enabled: !_busy,
                      onSelected: (action) => action == 'ip'
                          ? _changeIp(room, device)
                          : _deleteDevice(room, device),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'ip', child: Text('分配 IP')),
                        PopupMenuItem(value: 'delete', child: Text('删除设备')),
                      ],
                    )
                  : null,
            ),
          ),
        if (room.isOwner) ...[
          const SizedBox(height: 16),
          Text('邀请管理', style: Theme.of(context).textTheme.titleMedium),
          if (_invites.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('尚未生成邀请；已生成链接的凭证不会再次返回。'),
            ),
          for (final invite in _invites)
            Card(
              child: ListTile(
                title: Text('已使用 ${invite['uses']} / ${invite['max_uses']} 次'),
                subtitle: Text(
                  '有效期至 ${DateTime.fromMillisecondsSinceEpoch((invite['expires_at'] as num).toInt() * 1000).toLocal()}${invite['revoked'] == true ? ' · 已撤销' : ''}',
                ),
                trailing: IconButton(
                  tooltip: '撤销邀请',
                  icon: const Icon(Icons.link_off_rounded),
                  onPressed: _busy || invite['revoked'] == true
                      ? null
                      : () async {
                          if (await _confirm('撤销邀请', '链接将不能再用于加入，已加入成员不受影响。') &&
                              mounted) {
                            await _run(() async {
                              await _api.request('DELETE', [
                                room.id,
                                'invites',
                                invite['id'] as String,
                              ]);
                            });
                          }
                        },
                ),
              ),
            ),
          if (roster.bannedUserIds.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('封禁账号', style: Theme.of(context).textTheme.titleMedium),
            for (final user in roster.bannedUserIds)
              Card(
                child: ListTile(
                  title: SelectableText(user),
                  trailing: TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            if (await _confirm('解除封禁', '该账号仍需使用有效密码或邀请重新加入。') &&
                                mounted) {
                              await _run(() async {
                                await _api.request('DELETE', [
                                  room.id,
                                  'bans',
                                  user,
                                ]);
                              });
                            }
                          },
                    child: const Text('解除封禁'),
                  ),
                ),
              ),
          ],
        ],
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : () => _leave(room),
            icon: const Icon(Icons.exit_to_app_rounded),
            label: Text(room.isOwner ? '解散房间' : '退出房间'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('房间设备只允许当前房间内通信，不承担房间之间的转发。退出、封禁或权限过期后，旧数据面授权最多保留 30 秒。'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.settingsStore,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('好友房间'),
        actions: [
          IconButton(
            tooltip: '刷新房间',
            onPressed: _busy ? null : () => _refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '和好友组成独立的局域网',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _parallel.supported
                            ? '每人创建一个房间，可同时连接多个房间；个人网络配置保持独立。'
                            : '每人创建一个房间，可以加入多个房间；此平台目前仍为单活动网络。',
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed:
                                _busy || _rooms.any((room) => room.isOwner)
                                ? null
                                : _create,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('创建房间'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _join,
                            icon: const Icon(Icons.meeting_room_outlined),
                            label: const Text('房间号加入'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _joinWithLink(),
                            icon: const Icon(Icons.link_rounded),
                            label: const Text('邀请链接加入'),
                          ),
                        ],
                      ),
                      if (_busy || _loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: LinearProgressIndicator(),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 20),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final details = _roster == null
                              ? const SizedBox.shrink()
                              : _roomDetails(_roster!);
                          if (constraints.maxWidth >= 840) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(width: 320, child: _roomList()),
                                const SizedBox(width: 24),
                                Expanded(child: details),
                              ],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _roomList(),
                              const SizedBox(height: 24),
                              details,
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RoomField {
  const _RoomField(
    this.label, {
    this.initial = '',
    this.hint,
    this.secret = false,
    this.multiline = false,
    this.number = false,
    this.maxLength = 128,
    this.validate,
  });
  final String label;
  final String initial;
  final String? hint;
  final bool secret;
  final bool multiline;
  final bool number;
  final int maxLength;
  final String? Function(String?)? validate;
}

class _RoomInputDialog extends StatefulWidget {
  const _RoomInputDialog({
    required this.title,
    required this.fields,
    this.description,
  });
  final String title;
  final List<_RoomField> fields;
  final String? description;
  @override
  State<_RoomInputDialog> createState() => _RoomInputDialogState();
}

class _RoomInputDialogState extends State<_RoomInputDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controllers = widget.fields
      .map((field) => TextEditingController(text: field.initial))
      .toList();
  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.description != null) ...[
                Text(widget.description!),
                const SizedBox(height: 20),
              ],
              for (var i = 0; i < widget.fields.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextFormField(
                    key: ValueKey(widget.fields[i].label),
                    controller: _controllers[i],
                    autofocus: i == 0,
                    obscureText: widget.fields[i].secret,
                    autocorrect: false,
                    enableSuggestions: !widget.fields[i].secret,
                    maxLength: widget.fields[i].maxLength,
                    maxLines: widget.fields[i].multiline ? 4 : 1,
                    keyboardType: widget.fields[i].number
                        ? TextInputType.number
                        : TextInputType.text,
                    decoration: InputDecoration(
                      labelText: widget.fields[i].label,
                      helperText: widget.fields[i].hint,
                      border: const OutlineInputBorder(),
                    ),
                    validator: widget.fields[i].validate,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState?.validate() == true) {
            Navigator.pop(
              context,
              _controllers.map((controller) => controller.text).toList(),
            );
          }
        },
        child: const Text('确认'),
      ),
    ],
  );
}
