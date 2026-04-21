#ifndef RUNNER_SYSTEM_PROXY_CLEANUP_H_
#define RUNNER_SYSTEM_PROXY_CLEANUP_H_

// Best-effort cleanup used during Windows session shutdown, when the Dart
// shutdown path may not have enough time to restore the WinINET proxy.
void RestoreManagedWindowsSystemProxyForSessionEnd();

#endif  // RUNNER_SYSTEM_PROXY_CLEANUP_H_
