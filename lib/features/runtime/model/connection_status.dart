sealed class ConnectionStatus {
  const ConnectionStatus();

  bool get isConnected => this is Connected;
  bool get isDisconnected => this is Disconnected;
  bool get isSwitching => this is Connecting || this is Disconnecting;
}

class Disconnected extends ConnectionStatus {
  const Disconnected();
}

class Connecting extends ConnectionStatus {
  const Connecting();
}

class Connected extends ConnectionStatus {
  const Connected();
}

class Disconnecting extends ConnectionStatus {
  const Disconnecting();
}
