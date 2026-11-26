enum PlatformCapability {
  appleTranslation,
  dictionary,
  permissions,
  screenshot,
  recording,
  mcp;

  static Set<PlatformCapability> parse(List<Object?> names) => {
    for (final name in names) PlatformCapability.values.byName(name! as String),
  };
}
