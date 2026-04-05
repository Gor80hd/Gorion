enum ServerSortMode { none, ping, speed, alpha }

extension ServerSortModeStorage on ServerSortMode {
  String get storageValue => switch (this) {
    ServerSortMode.none => 'none',
    ServerSortMode.ping => 'ping',
    ServerSortMode.speed => 'speed',
    ServerSortMode.alpha => 'alpha',
  };

  static ServerSortMode fromStorageValue(String? value) {
    return ServerSortMode.values.firstWhere(
      (mode) => mode.storageValue == value,
      orElse: () => ServerSortMode.speed,
    );
  }
}
