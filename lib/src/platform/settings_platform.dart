abstract interface class SettingsPlatform {
  Future<void> applySettings(
    Map<String, Object> settings, {
    Map<String, Map<String, String>?> credentials = const {},
  });

  Future<Map<String, String>> readCredentials(String id);

  Future<List<String>> credentialIds(List<String> ids);
}
