abstract final class NetworkLimits {
  static const connectionTimeout = Duration(seconds: 10);

  static const idleTimeout = Duration(seconds: 60);

  static const anthropicThinkingBudget = 2048;
}
