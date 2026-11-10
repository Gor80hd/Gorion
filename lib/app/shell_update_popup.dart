part of 'shell.dart';

class _UpdateAvailablePopup extends StatelessWidget {
  const _UpdateAvailablePopup({required this.update, required this.onDismiss});

  final AppUpdateInfo update;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final accent = theme.brandAccent;
    final releaseName = update.releaseName?.trim();
    final releaseNameLabel =
        releaseName != null &&
            releaseName.isNotEmpty &&
            releaseName != update.latestVersion &&
            releaseName != update.tagName
        ? releaseName
        : null;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: GlassPanel(
          borderRadius: 24,
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          opacity: 0.14,
          backgroundColor: scheme.surface,
          strokeColor: accent,
          strokeOpacity: 0.26,
          strokeWidth: 1,
          showGlow: true,
          glowBlur: 16,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 30,
              offset: const Offset(0, 16),
            ),
          ],
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.system_update_alt_rounded, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Доступна новая версия ${update.latestVersion}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Сейчас установлена ${update.currentVersion}. Релиз уже опубликован на GitHub.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        height: 1.35,
                      ),
                    ),
                    if (releaseNameLabel != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        releaseNameLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (update.releaseUrl != null) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => unawaited(_openReleasePage(context)),
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label: const Text('Открыть страницу релиза'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Скрыть',
                onPressed: onDismiss,
                icon: Icon(Icons.close_rounded, color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openReleasePage(BuildContext context) async {
    final releaseUrl = update.releaseUrl;
    if (releaseUrl == null) {
      return;
    }

    final opened = await _openExternalUrl(releaseUrl);
    if (!context.mounted) {
      return;
    }

    if (!opened) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Не удалось открыть страницу релиза.')),
      );
    }
  }

  Future<bool> _openExternalUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
        return true;
      }
      if (Platform.isMacOS) {
        await Process.start('open', [url]);
        return true;
      }
      if (Platform.isLinux) {
        await Process.start('xdg-open', [url]);
        return true;
      }
    } on Object {
      return false;
    }
    return false;
  }
}
