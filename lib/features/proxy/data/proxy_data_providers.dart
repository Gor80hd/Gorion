import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/utils/functional.dart';

/// Reactive proxy repository that emits an [OutboundGroup] whenever the
/// dashboard's selected server or delay map changes.
class _ProxyRepository {
  _ProxyRepository(this._stream, this._ref);
  final Stream<Either<dynamic, OutboundGroup>> _stream;
  final Ref _ref;

  Stream<Either<dynamic, OutboundGroup>> watchProxies() => _stream;

  /// Select [serverTag] within [groupTag]. Returns a TaskEither that resolves
  /// once the dashboard has registered the new selection.
  TaskEither<dynamic, void> selectProxy(String groupTag, String serverTag) {
    return TaskEither.fromFuture(
      () => _ref.read(dashboardControllerProvider.notifier).selectServer(serverTag),
      (e) => e,
    );
  }
}

OutboundGroup _buildGroupFromState(DashboardState state) {
  final profiles = state.storage.profiles;
  final allServers = <OutboundInfo>[];

  for (final profile in profiles) {
    for (final server in profile.servers) {
      final delay = state.delayByTag[server.tag] ?? 0;
      allServers.add(
        OutboundInfo.fromServerEntry(server, delay: delay),
      );
    }
  }

  final selectedTag = state.activeServerTag ?? state.selectedServerTag ?? '';

  return OutboundGroup(
    tag: state.storage.activeProfileId ?? 'main',
    selected: selectedTag,
    items: allServers,
  );
}

final proxyRepositoryProvider = Provider<_ProxyRepository>((ref) {
  final controller = StreamController<Either<dynamic, OutboundGroup>>.broadcast();

  ref.listen(
    dashboardControllerProvider,
    (_, state) {
      if (!controller.isClosed) {
        controller.add(Right(_buildGroupFromState(state)));
      }
    },
    fireImmediately: true,
  );

  ref.onDispose(controller.close);
  return _ProxyRepository(controller.stream, ref);
});
