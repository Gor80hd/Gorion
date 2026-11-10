part of 'servers_panel.dart';

class ServerSettingsDialog extends StatelessWidget {
  const ServerSettingsDialog({
    super.key,
    required this.server,
    required this.outbound,
  });

  final OutboundInfo server;
  final Map<String, dynamic>? outbound;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final prettyJson = outbound == null
        ? null
        : const JsonEncoder.withIndent('  ').convert(outbound);

    Widget infoRow(String title, String value) {
      if (value.isEmpty || value == '0') return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(
                title,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.88),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Gap(8),
            Expanded(
              child: SelectableText(
                value,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.74),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: GlassPanel(
        borderRadius: 24,
        backgroundColor: scheme.surface,
        opacity: 0.9,
        strokeOpacity: 0.14,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                EmojiFlagText(
                  _displayName(server),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Gap(16),
                infoRow('Тип', server.type.toUpperCase()),
                infoRow('Host', server.host),
                infoRow('Port', server.port.toString()),
                infoRow('Tag', server.tag),
                if (prettyJson != null) ...[
                  Divider(
                    height: 24,
                    color: scheme.onSurface.withValues(alpha: 0.08),
                  ),
                  Text(
                    'Сырые настройки сервера',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Gap(8),
                  GlassPanel(
                    borderRadius: 16,
                    backgroundColor: Colors.white,
                    opacity: 0.04,
                    strokeOpacity: 0.04,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      prettyJson,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.78),
                      ),
                    ),
                  ),
                ] else
                  Text(
                    'Полная конфигурация сейчас недоступна, но базовые параметры сервера уже видны.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: muted.withValues(alpha: 0.95),
                    ),
                  ),
                const Gap(16),
                Row(
                  children: [
                    if (prettyJson != null)
                      Expanded(
                        child: _DialogActionButton(
                          label: 'Копировать JSON',
                          accent: true,
                          onTap: () => Clipboard.setData(
                            ClipboardData(text: prettyJson),
                          ),
                        ),
                      ),
                    if (prettyJson != null) const Gap(10),
                    Expanded(
                      child: _DialogActionButton(
                        label: 'Закрыть',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    this.onTap,
    this.accent = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = accent ? scheme.primary : scheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: accent
              ? scheme.primary.withValues(alpha: 0.14)
              : scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.22), width: 0.8),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}
