import 'package:flutter/material.dart';

import '../../core/api/control_api.dart';
import '../../app/app_strings.dart';

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
      if (mounted) {
        _error = AppStringsScope.of(context).settingsUsernameLoadError;
      }
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
      _saved = AppStringsScope.of(context).settingsUsernameSaved;
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
  Widget build(BuildContext context) {
    final strings = AppStringsScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loaded)
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  maxLength: 32,
                  decoration: InputDecoration(
                    labelText: strings.settingsUsername,
                    hintText: strings.settingsUsernameHint,
                    helperText: strings.settingsUsernameHelper,
                    helperMaxLines: 3,
                  ),
                  onSubmitted: _busy ? null : (_) => _save(),
                )
              else
                Text(
                  strings.settingsUsername,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_saved != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _saved!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              TextButton(
                onPressed: _busy
                    ? null
                    : _loaded
                    ? _save
                    : _load,
                child: Text(
                  _loaded
                      ? strings.settingsSaveUsername
                      : strings.settingsReloadUsername,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
