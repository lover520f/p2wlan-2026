part of '../settings_page.dart';

/// Account & Network: credential state (never the token itself), control
/// server, network id, virtual IP, and Sign out as a bottom danger action.
class _AccountSection extends StatelessWidget {
  const _AccountSection({
    required this.state,
    required this.strings,
    required this.credentialState,
  });

  final _SettingsPageState state;
  final AppStrings strings;
  final String credentialState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saving = state._saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroup(
          title: strings.settingsAccountGroup,
          children: [
            if (state.widget.settingsStore.settings.authToken.trim().isNotEmpty)
              UsernameSettings(
                key: ValueKey((
                  state.widget.settingsStore.settings.controlServer,
                  state.widget.settingsStore.settings.authToken,
                )),
                server: state.widget.settingsStore.settings.controlServer,
                token: state.widget.settingsStore.settings.authToken,
                email: state.widget.settingsStore.settings.accountEmail,
                username: state.widget.settingsStore.settings.accountUsername,
                onProfileLoaded: state._rememberAccountProfile,
              )
            else if (state.widget.settingsStore.settings.accountEmail
                    .trim()
                    .isNotEmpty ||
                state.widget.settingsStore.settings.accountUsername
                    .trim()
                    .isNotEmpty)
              _CachedAccountIdentity(
                email: state.widget.settingsStore.settings.accountEmail,
                username: state.widget.settingsStore.settings.accountUsername,
                strings: strings,
              ),
            _PreferenceRow(
              label: strings.credentialSectionTitle,
              subtitle: credentialState,
              value: state._showTokenField
                  ? strings.hideCredential
                  : strings.changeCredential,
              onTap: saving
                  ? null
                  : () => state._updateState(
                      () => state._showTokenField = !state._showTokenField,
                    ),
            ),
            if (state._showTokenField) ...[
              const SizedBox(height: AppTokens.space4),
              _SettingsField(
                controller: state._authTokenController,
                label: strings.authToken,
                helper: strings.credentialChangeHelper,
                obscureText: true,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
        _SettingsGroup(
          title: strings.settingsConnectionGroup,
          subtitle: strings.settingsConnectionHint,
          children: [
            _SettingsField(
              controller: state._controlServerController,
              label: strings.controlServer,
              helper: strings.controlServerHelper,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            _SettingsField(
              controller: state._networkIdController,
              label: strings.networkId,
              helper: strings.networkIdHelper,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            _SettingsField(
              controller: state._virtualIpController,
              label: strings.requestedVirtualIp,
              helper: strings.requestedVirtualIpHelperSettings,
              textInputAction: TextInputAction.done,
              onSubmitted: saving
                  ? null
                  : (_) => state._saveCategory(SettingsCategory.accountNetwork),
            ),
          ],
        ),
        if (state.widget.onLogout != null) ...[
          const SizedBox(height: AppTokens.space16),
          const Divider(height: 1),
          const SizedBox(height: AppTokens.space12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: saving ? null : state.widget.onLogout,
              icon: const Icon(Icons.logout_outlined, size: 16),
              label: Text(strings.signOut),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _CachedAccountIdentity extends StatelessWidget {
  const _CachedAccountIdentity({
    required this.email,
    required this.username,
    required this.strings,
  });

  final String email;
  final String username;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: .45,
          ),
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                username.trim().isEmpty
                    ? strings.settingsUsernameNotSet
                    : username.trim(),
                style: theme.textTheme.titleMedium,
              ),
              if (email.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  email.trim(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                strings.settingsAccountCached,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
