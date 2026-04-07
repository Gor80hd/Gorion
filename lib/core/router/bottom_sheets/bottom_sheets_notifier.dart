import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

class _BottomSheetsNotifier extends Notifier<void> {
  @override
  void build() {}

  /// Opens the add subscription dialog.
  void showAddProfile() {
    final context = _buildContext;
    if (context == null || !context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => const _AddSubscriptionDialog(),
    );
  }

  /// Opens the profiles overview dialog.
  void showProfilesOverview() {
    final context = _buildContext;
    if (context == null || !context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => const _ProfilesOverviewDialog(),
    );
  }

  BuildContext? _buildContext;

  void attachContext(BuildContext ctx) => _buildContext = ctx;
}

final bottomSheetsNotifierProvider =
    NotifierProvider<_BottomSheetsNotifier, void>(_BottomSheetsNotifier.new);

enum _ManagedSubscriptionAction { activate, refresh, remove }

// ─── Inline dialogs ───────────────────────────────────────────────────────────

class _AddSubscriptionDialog extends ConsumerStatefulWidget {
  const _AddSubscriptionDialog();

  @override
  ConsumerState<_AddSubscriptionDialog> createState() =>
      _AddSubscriptionDialogState();
}

class _AddSubscriptionDialogState
    extends ConsumerState<_AddSubscriptionDialog> {
  final _ctrl = TextEditingController();
  bool _attemptedSubmit = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _ctrl.text.trim();
    if (url.isEmpty) {
      setState(() => _attemptedSubmit = true);
      return;
    }

    FocusScope.of(context).unfocus();
    final beforeCount = ref
        .read(dashboardControllerProvider)
        .storage
        .profiles
        .length;
    setState(() => _attemptedSubmit = true);

    await ref.read(dashboardControllerProvider.notifier).addSubscription(url);
    if (!mounted) {
      return;
    }

    final nextState = ref.read(dashboardControllerProvider);
    if (nextState.errorMessage == null &&
        nextState.storage.profiles.length > beforeCount) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dashboardControllerProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final busy = _attemptedSubmit && state.busy;
    final errorText = _attemptedSubmit ? state.errorMessage : null;

    return AlertDialog(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        'Добавить подписку',
        style: TextStyle(color: scheme.onSurface),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Вставьте URL удалённой подписки. Поддерживаются sing-box JSON и подписки с share-ссылками.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              autofocus: true,
              enabled: !busy,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              style: TextStyle(color: scheme.onSurface),
              decoration: const InputDecoration(
                labelText: 'URL подписки',
                hintText: 'https://example.com/subscription',
              ),
            ),
            if (errorText != null && errorText.isNotEmpty) ...[
              const SizedBox(height: 12),
              _InlineBanner(message: errorText, isError: true),
            ],
            if (busy) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(
                minHeight: 4,
                color: scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: busy ? null : _submit,
          child: Text(busy ? 'Добавляем…' : 'Добавить'),
        ),
      ],
    );
  }
}

class _ProfilesOverviewDialog extends ConsumerStatefulWidget {
  const _ProfilesOverviewDialog();

  @override
  ConsumerState<_ProfilesOverviewDialog> createState() =>
      _ProfilesOverviewDialogState();
}

class _ProfilesOverviewDialogState
    extends ConsumerState<_ProfilesOverviewDialog> {
  String? _pendingProfileId;
  _ManagedSubscriptionAction? _pendingAction;
  bool _surfaceControllerMessages = false;

  Future<void> _runProfileAction(
    ProxyProfile profile,
    _ManagedSubscriptionAction action,
    Future<void> Function() task,
  ) async {
    setState(() {
      _surfaceControllerMessages = true;
      _pendingProfileId = profile.id;
      _pendingAction = action;
    });

    await task();
    if (!mounted) {
      return;
    }

    setState(() {
      _pendingProfileId = null;
      _pendingAction = null;
    });
  }

  Future<void> _copyLink(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label скопирована в буфер обмена.')),
    );
  }

  Future<void> _removeProfile(
    ProxyProfile profile,
    bool isActiveProfile,
    ConnectionStage stage,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final scheme = theme.colorScheme;
        final muted = theme.gorionTokens.onSurfaceMuted;
        final reconnectWarning =
            isActiveProfile &&
                (stage == ConnectionStage.connected ||
                    stage == ConnectionStage.starting)
            ? ' Текущее подключение будет остановлено.'
            : '';
        return AlertDialog(
          backgroundColor: scheme.surface,
          title: Text(
            'Удалить подписку?',
            style: TextStyle(color: scheme.onSurface),
          ),
          content: Text(
            'Подписка "${profile.name}" будет удалена из локального хранилища.$reconnectWarning',
            style: TextStyle(color: muted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFF8E8E),
              ),
              child: const Text('Удалить'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    await _runProfileAction(
      profile,
      _ManagedSubscriptionAction.remove,
      () => ref
          .read(dashboardControllerProvider.notifier)
          .removeProfile(profile.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dashboardControllerProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final profiles = _sortProfiles(
      state.storage.profiles,
      state.storage.activeProfileId,
    );
    final message = _surfaceControllerMessages
        ? state.errorMessage ?? state.statusMessage
        : null;
    final isError = _surfaceControllerMessages && state.errorMessage != null;
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: size.height * 0.82,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.24),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: theme.shadowColor.withValues(alpha: 0.34),
                blurRadius: 36,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Подписки',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      profiles.isEmpty
                          ? 'Сохранённых подписок пока нет.'
                          : 'Выберите текущую подписку, обновите данные или удалите ненужные профили.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                    if (state.storage.activeProfile != null) ...[
                      const SizedBox(height: 8),
                      _DialogMetaChip(
                        icon: Icons.radio_button_checked_rounded,
                        label: 'Текущая: ${state.storage.activeProfile!.name}',
                      ),
                    ],
                  ],
                ),
              ),
              if (state.busy)
                LinearProgressIndicator(
                  minHeight: 3,
                  color: scheme.primary,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              if (message != null && message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                  child: _InlineBanner(message: message, isError: isError),
                ),
              Expanded(
                child: profiles.isEmpty
                    ? const _SubscriptionsEmptyState()
                    : Scrollbar(
                        thumbVisibility: profiles.length > 3,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
                          itemCount: profiles.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final profile = profiles[index];
                            final isActiveProfile =
                                profile.id == state.storage.activeProfileId;
                            final isPending = profile.id == _pendingProfileId;

                            return _ManagedSubscriptionCard(
                              profile: profile,
                              isActive: isActiveProfile,
                              activeStage: isActiveProfile
                                  ? state.connectionStage
                                  : ConnectionStage.disconnected,
                              isBusy: state.busy,
                              isPending: isPending,
                              pendingAction: isPending ? _pendingAction : null,
                              onActivate: isActiveProfile
                                  ? null
                                  : () => _runProfileAction(
                                      profile,
                                      _ManagedSubscriptionAction.activate,
                                      () => ref
                                          .read(
                                            dashboardControllerProvider
                                                .notifier,
                                          )
                                          .chooseProfile(profile.id),
                                    ),
                              onRefresh: () => _runProfileAction(
                                profile,
                                _ManagedSubscriptionAction.refresh,
                                () => ref
                                    .read(dashboardControllerProvider.notifier)
                                    .refreshProfile(profile.id),
                              ),
                              onRemove: () => _removeProfile(
                                profile,
                                isActiveProfile,
                                state.connectionStage,
                              ),
                              onCopyUrl: () => _copyLink(
                                profile.subscriptionUrl,
                                'Ссылка подписки',
                              ),
                              onCopyWebPage:
                                  _hasLink(profile.subscriptionInfo?.webPageUrl)
                                  ? () => _copyLink(
                                      profile.subscriptionInfo!.webPageUrl!,
                                      'Ссылка сайта',
                                    )
                                  : null,
                              onCopySupport:
                                  _hasLink(profile.subscriptionInfo?.supportUrl)
                                  ? () => _copyLink(
                                      profile.subscriptionInfo!.supportUrl!,
                                      'Ссылка поддержки',
                                    )
                                  : null,
                            );
                          },
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
                child: Row(
                  children: [
                    Text(
                      '${profiles.length} ${_subscriptionCountLabel(profiles.length)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Закрыть'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManagedSubscriptionCard extends StatelessWidget {
  const _ManagedSubscriptionCard({
    required this.profile,
    required this.isActive,
    required this.activeStage,
    required this.isBusy,
    required this.isPending,
    required this.pendingAction,
    this.onActivate,
    this.onRefresh,
    this.onRemove,
    this.onCopyUrl,
    this.onCopyWebPage,
    this.onCopySupport,
  });

  final ProxyProfile profile;
  final bool isActive;
  final ConnectionStage activeStage;
  final bool isBusy;
  final bool isPending;
  final _ManagedSubscriptionAction? pendingAction;
  final VoidCallback? onActivate;
  final VoidCallback? onRefresh;
  final VoidCallback? onRemove;
  final VoidCallback? onCopyUrl;
  final VoidCallback? onCopyWebPage;
  final VoidCallback? onCopySupport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final subscriptionInfo = profile.subscriptionInfo;
    final borderColor = isActive
        ? scheme.primary.withValues(alpha: 0.5)
        : theme.surfaceStrokeColor(darkAlpha: 0.10, lightAlpha: 0.22);
    final backgroundColor = isActive
        ? scheme.onSurface.withValues(alpha: 0.07)
        : scheme.onSurface.withValues(alpha: 0.04);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${profile.servers.length} ${_serverCountLabel(profile.servers.length)} · обновлена ${_formatDate(profile.updatedAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (isPending)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: pendingAction == _ManagedSubscriptionAction.remove
                          ? const Color(0xFFFF8E8E)
                          : scheme.primary,
                    ),
                  ),
                )
              else if (isActive)
                _DialogMetaChip(
                  icon: activeStage == ConnectionStage.connected
                      ? Icons.wifi_tethering_rounded
                      : Icons.check_circle_rounded,
                  label: _activeProfileLabel(activeStage),
                  accent: true,
                ),
            ],
          ),
          const SizedBox(height: 14),
          _UrlPreviewRow(url: profile.subscriptionUrl, onCopy: onCopyUrl),
          if (subscriptionInfo != null) ...[
            const SizedBox(height: 12),
            _SubscriptionInfoSummary(info: subscriptionInfo),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onActivate != null)
                OutlinedButton.icon(
                  onPressed: isBusy ? null : onActivate,
                  icon: const Icon(
                    Icons.radio_button_checked_rounded,
                    size: 18,
                  ),
                  label: const Text('Сделать текущей'),
                ),
              OutlinedButton.icon(
                onPressed: isBusy ? null : onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Обновить'),
              ),
              TextButton.icon(
                onPressed: onCopyUrl,
                icon: const Icon(Icons.content_copy_rounded, size: 18),
                label: const Text('Копировать URL'),
              ),
              if (onCopyWebPage != null)
                TextButton.icon(
                  onPressed: onCopyWebPage,
                  icon: const Icon(Icons.language_rounded, size: 18),
                  label: const Text('Сайт'),
                ),
              if (onCopySupport != null)
                TextButton.icon(
                  onPressed: onCopySupport,
                  icon: const Icon(Icons.support_agent_rounded, size: 18),
                  label: const Text('Поддержка'),
                ),
              TextButton.icon(
                onPressed: isBusy ? null : onRemove,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFFF8E8E),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Удалить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SubscriptionInfoSummary extends StatelessWidget {
  const _SubscriptionInfoSummary({required this.info});

  final SubscriptionInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final total = info.total;
    final remaining = info.remaining;
    final progress = total > 0 ? (info.consumed / total).clamp(0.0, 1.0) : null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.surfaceStrokeColor(darkAlpha: 0.08, lightAlpha: 0.20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            total > 0
                ? 'Осталось ${_formatBytes(remaining == null || remaining < 0 ? 0 : remaining)} из ${_formatBytes(total)}'
                : 'Лимит трафика не указан',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            info.expireAt == null
                ? 'Срок действия не указан'
                : 'Истекает ${_formatDate(info.expireAt!)}',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          if (progress != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 7,
                value: progress,
                color: progress >= 0.85
                    ? const Color(0xFFFF8E8E)
                    : scheme.primary,
                backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UrlPreviewRow extends StatelessWidget {
  const _UrlPreviewRow({required this.url, this.onCopy});

  final String url;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.surfaceStrokeColor(darkAlpha: 0.08, lightAlpha: 0.20),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.link_rounded, size: 16, color: muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: onCopy,
            tooltip: 'Копировать URL',
            icon: const Icon(Icons.content_copy_rounded, size: 18),
            color: muted,
          ),
        ],
      ),
    );
  }
}

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = isError ? const Color(0xFFFFB4B4) : scheme.onSurface;
    final background = isError
        ? const Color(0x40A11717)
        : scheme.primary.withValues(alpha: 0.14);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isError
              ? const Color(0x66FF8E8E)
              : scheme.primary.withValues(alpha: 0.18),
        ),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
      ),
    );
  }
}

class _DialogMetaChip extends StatelessWidget {
  const _DialogMetaChip({
    required this.icon,
    required this.label,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final foreground = accent ? scheme.primary : muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accent
            ? scheme.primary.withValues(alpha: 0.14)
            : scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionsEmptyState extends StatelessWidget {
  const _SubscriptionsEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 34,
              color: muted.withValues(alpha: 0.8),
            ),
            const SizedBox(height: 12),
            Text(
              'Пока нет ни одной сохранённой подписки.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Добавьте первую подписку через кнопку с плюсом на главном экране.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

List<ProxyProfile> _sortProfiles(
  List<ProxyProfile> profiles,
  String? activeProfileId,
) {
  final next = [...profiles];
  next.sort((a, b) {
    final aRank = a.id == activeProfileId ? 0 : 1;
    final bRank = b.id == activeProfileId ? 0 : 1;
    if (aRank != bRank) {
      return aRank.compareTo(bRank);
    }
    return b.updatedAt.compareTo(a.updatedAt);
  });
  return next;
}

bool _hasLink(String? value) => value != null && value.trim().isNotEmpty;

String _formatDate(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$day.$month.${local.year} $hour:$minute';
}

String _formatBytes(int value) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var amount = value.toDouble();
  var unitIndex = 0;

  while (amount >= 1024 && unitIndex < units.length - 1) {
    amount /= 1024;
    unitIndex += 1;
  }

  final fractionDigits = unitIndex == 0
      ? 0
      : amount >= 100
      ? 0
      : amount >= 10
      ? 1
      : 2;
  return '${amount.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
}

String _serverCountLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) {
    return 'сервер';
  }
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return 'сервера';
  }
  return 'серверов';
}

String _subscriptionCountLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) {
    return 'подписка';
  }
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return 'подписки';
  }
  return 'подписок';
}

String _activeProfileLabel(ConnectionStage stage) {
  switch (stage) {
    case ConnectionStage.connected:
      return 'Подключена';
    case ConnectionStage.starting:
      return 'Подключение';
    case ConnectionStage.stopping:
      return 'Отключение';
    case ConnectionStage.failed:
      return 'Ошибка';
    case ConnectionStage.disconnected:
      return 'Текущая';
  }
}
