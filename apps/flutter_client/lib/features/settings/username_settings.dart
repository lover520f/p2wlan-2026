import 'package:flutter/material.dart';

import '../../core/api/control_api.dart';
import '../../app/app_strings.dart';
import '../../shared/widgets/app_notice.dart';

/// Usernames are account display names, independent of login email and devices.
class UsernameSettings extends StatefulWidget {
  const UsernameSettings({
    super.key,
    required this.server,
    required this.token,
    this.email = '',
    this.username = '',
    this.onProfileLoaded,
  });
  final String server;
  final String token;
  final String email;
  final String username;
  final ValueChanged<AccountProfile>? onProfileLoaded;
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
  late String _email;

  @override
  void initState() {
    super.initState();
    _email = widget.email.trim();
    _name.text = widget.username.trim();
    _loaded = _name.text.isNotEmpty;
    _load();
  }

  @override
  void didUpdateWidget(covariant UsernameSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextEmail = widget.email.trim();
    if (nextEmail.isNotEmpty && nextEmail != _email) _email = nextEmail;
    final nextUsername = widget.username.trim();
    if (nextUsername.isNotEmpty && nextUsername != _name.text.trim()) {
      _name.text = nextUsername;
      _loaded = true;
    }
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = await _api.accountProfile(
        controlServer: widget.server,
        authToken: widget.token,
      );
      if (!mounted) return;
      _email = profile.email.isEmpty ? _email : profile.email;
      _name.text = profile.username;
      _loaded = true;
      widget.onProfileLoaded?.call(profile);
    } catch (_) {
      if (mounted) {
        _error = AppStringsScope.of(context).settingsUsernameLoadError;
        showAppNotice(context, content: Text(_error!));
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
      final profile = await _api.accountProfile(
        controlServer: widget.server,
        authToken: widget.token,
        username: _name.text,
      );
      if (!mounted) return;
      _email = profile.email.isEmpty ? _email : profile.email;
      _name.text = profile.username;
      widget.onProfileLoaded?.call(profile);
      _saved = AppStringsScope.of(context).settingsUsernameSaved;
    } on ControlApiException catch (error) {
      if (mounted) {
        _error = error.message;
        showAppNotice(context, content: Text(error.message));
      }
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
              if (_email.isNotEmpty) ...[
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: strings.settingsAccountEmail,
                    helperText: strings.settingsAccountEmailHelper,
                    helperMaxLines: 2,
                    prefixIcon: const Icon(Icons.alternate_email_outlined),
                  ),
                  child: Text(
                    _email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 16),
              ],
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
              if (_error != null && _name.text.trim().isEmpty)
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
