import '../common/constants/platform_capabilities.dart';

class ServiceConfig {
  const ServiceConfig({
    required this.id,
    required this.kind,
    required this.name,
    required this.baseUrl,
    this.model = '',
    this.semanticPairs = false,
    this.maxOutputTokens = 4096,
  });
  static const builtinId = 'unofficial-google';

  static const builtinEndpoint =
      'https://translate.googleapis.com/translate_a/single';

  static const builtinName = '谷歌翻译';

  static const systemId = 'apple-system';

  static const systemName = 'Apple 系统翻译';

  static Map<String, String> builtins(Set<PlatformCapability> capabilities) => {
    if (capabilities.contains(PlatformCapability.appleTranslation))
      systemId: systemName,
    builtinId: builtinName,
  };
  static const kinds = {
    'baidu': '百度翻译',
    'google': '谷歌翻译',
    'openai': 'OpenAI',
    'deepseek': 'DeepSeek',
    'anthropic': 'Anthropic',
  };

  static final selectableKinds = {
    for (final kind in ['google', 'baidu', 'openai', 'anthropic'])
      kind: kinds[kind]!,
  };

  String get displayName => switch (name) {
    'OpenAI-compatible' => 'OpenAI',
    'Google Cloud' => '谷歌翻译',
    _ => name,
  };
  static const endpoints = {
    'baidu': 'https://fanyi-api.baidu.com',
    'google': 'https://translation.googleapis.com',
    'openai': 'https://api.openai.com/v1',
    'deepseek': 'https://api.deepseek.com',
    'anthropic': 'https://api.anthropic.com/v1',
  };
  final String id;
  final String kind;
  final String name;
  final String baseUrl;
  final String model;
  final bool semanticPairs;
  final int maxOutputTokens;
  bool get isModel => isModelKind(kind);

  static bool isModelKind(String kind) =>
      kind == 'openai' || kind == 'deepseek' || kind == 'anthropic';

  factory ServiceConfig.fromMap(Map<Object?, Object?> map) => ServiceConfig(
    id: map['id'] as String,
    kind: map['kind'] as String,
    name: map['name'] as String,
    baseUrl: map['baseUrl'] as String,
    model: map['model'] as String? ?? '',
    semanticPairs: map['semanticPairs'] as bool? ?? false,
    maxOutputTokens: map['maxOutputTokens'] as int? ?? 4096,
  );

  Map<String, Object> toMap() => {
    'id': id,
    'kind': kind,
    'name': name,
    'baseUrl': baseUrl,
    'model': model,
    'semanticPairs': semanticPairs,
    'maxOutputTokens': maxOutputTokens,
  };

  void validate() {
    if (id.isEmpty || name.trim().isEmpty || !kinds.containsKey(kind)) {
      throw const FormatException('请选择服务类型并填写名称。');
    }
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(uri.scheme == 'https' ||
            uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host))) {
      throw const FormatException(
        'API 地址需为 HTTPS Base URL；本机服务可用 HTTP。请勿把密钥放在地址中。',
      );
    }
    if (isModel && model.trim().isEmpty) {
      throw const FormatException('请填写模型名称。');
    }
    if (maxOutputTokens < 1 || maxOutputTokens > 1000000) {
      throw const FormatException('模型输出上限需为 1 至 1,000,000 的整数。');
    }
  }

  void validateCredentials(Map<String, String> credentials) {
    if (isModel) return;
    if ((credentials['apiKey'] ?? '').trim().isEmpty ||
        kind == 'baidu' && (credentials['appId'] ?? '').trim().isEmpty) {
      throw const FormatException('请填写 API Key／密钥，百度翻译还需要 App ID。');
    }
  }
}

Future<Map<String, Map<String, String>?>> prepareCredentialChanges({
  required List<ServiceConfig> previous,
  required List<ServiceConfig> current,
  required Map<String, Map<String, String>?> drafts,
  required Future<Map<String, String>> Function(String id) readCredentials,
}) async {
  final old = {for (final config in previous) config.id: config};
  final changes = <String, Map<String, String>?>{};
  for (final config in current) {
    final draft = drafts[config.id];
    final saved = old[config.id];
    if (saved != null && saved.kind != config.kind) {
      throw const FormatException('更换服务类型请新增配置。');
    }
    if ((draft == null || draft.isEmpty) && saved != null) {
      continue;
    }
    final value = {
      if (saved != null) ...await readCredentials(config.id),
      ...?draft,
    };
    config.validateCredentials(value);
    if (draft?.isNotEmpty == true) changes[config.id] = value;
  }
  for (final removed in previous) {
    if (!current.any((config) => config.id == removed.id)) {
      changes[removed.id] = null;
    }
  }
  return changes;
}
