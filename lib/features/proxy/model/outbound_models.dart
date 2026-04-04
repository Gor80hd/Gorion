import 'package:gorion_clean/features/profiles/model/profile_models.dart';

/// Server entry model compatible with the home page UI.
/// Maps to [ServerEntry] from the profiles domain.
class OutboundInfo {
  OutboundInfo({
    this.tag = '',
    this.tagDisplay = '',
    this.type = '',
    this.isVisible = false,
    this.isGroup = false,
    this.urlTestDelay = 0,
    this.isSelected = false,
    this.host = '',
    this.port = 0,
  });

  OutboundInfo.fromServerEntry(ServerEntry entry, {int delay = 0, bool selected = false})
    : tag = entry.tag,
      tagDisplay = entry.displayName,
      type = entry.type,
      isVisible = true,
      isGroup = false,
      urlTestDelay = delay,
      isSelected = selected,
      host = entry.host ?? '',
      port = entry.port ?? 0;

  final String tag;
  final String tagDisplay;
  final String type;
  bool isVisible;
  bool isGroup;
  int urlTestDelay;
  bool isSelected;
  final String host;
  final int port;

  OutboundInfo clone() => OutboundInfo(
    tag: tag,
    tagDisplay: tagDisplay,
    type: type,
    isVisible: isVisible,
    isGroup: isGroup,
    urlTestDelay: urlTestDelay,
    isSelected: isSelected,
    host: host,
    port: port,
  );
}

class OutboundGroup {
  OutboundGroup({
    required this.tag,
    this.type = 'selector',
    required this.selected,
    required this.items,
  });

  final String tag;
  final String type;
  final String selected;
  final List<OutboundInfo> items;
}
