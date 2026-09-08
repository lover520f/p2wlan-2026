import 'package:flutter/material.dart';

import '../../core/api/control_api.dart';

/// Usernames are account display names, independent of login email and devices.
class UsernameSettings extends StatefulWidget {
  const UsernameSettings({
    super.key,
    required this.server,
    required this.token,
  });
  final String server;
  final String token;
  @override
  State<UsernameSettings> createState() => _UsernameSettingsState();
}

class _UsernameSettingsState extends State<UsernameSettings> {
  final _api = ControlApi();
  final _name = TextEditingController();
  bool _busy = true;
  bool _loaded = false;
  String? _error;
  String? _saved;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = await _api.profileUsername(
        controlServer: widget.server,
        authToken: widget.token,
      );
      if (!mounted) return;
      _name.text = name;
      _loaded = true;
    } catch (_) {
      if (mounted) _error = '无法读取用户名，请检查连接，并确认控制服务器支持用户名功能。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _saved = null;
    });
    try {
      final name = await _api.profileUsername(
        controlServer: widget.server,
        authToken: widget.token,
        username: _name.text,
      );
      if (!mounted) return;
      _name.text = name;
      _saved = '用户名已保存，房间成员可看到这个名字。';
    } on ControlApiException catch (error) {
      if (mounted) _error = error.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _api.close();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('用户名', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        const Text('在房间中向好友展示，邮箱仍用于登录。'),
        const SizedBox(height: 12),
        if (_loaded)
          TextField(
            controller: _name,
            enabled: !_busy,
            maxLength: 32,
            decoration: const InputDecoration(
              labelText: '用户名',
              hintText: '填写好友认识的名字',
            ),
            onSubmitted: _busy ? null : (_) => _save(),
          ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_saved != null) Text(_saved!),
        TextButton(
          onPressed: _busy
              ? null
              : _loaded
              ? _save
              : _load,
          child: Text(_loaded ? '保存用户名' : '重新加载用户名'),
        ),
      ],
    ),
  );
}
