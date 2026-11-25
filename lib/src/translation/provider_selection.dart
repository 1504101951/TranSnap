import '../common/constants/text_mode.dart';
import '../platform/settings_platform.dart';
import '../settings/app_settings.dart';
import '../settings/service_config.dart';
import 'providers/api_translation_provider.dart';
import 'providers/apple_translation_provider.dart';
import 'providers/unofficial_google_provider.dart';
import 'translation_types.dart';

BatchTranslationProvider providerForSettings(
  AppSettings settings,
  SettingsPlatform platform,
) => providerForService(settings, platform, settings.defaultServiceId);

Uri? translationOrigin(AppSettings settings) {
  final serviceId = settings.defaultServiceId;
  if (serviceId == ServiceConfig.systemId) return null;
  if (serviceId == ServiceConfig.builtinId) {
    return Uri.parse(ServiceConfig.builtinEndpoint);
  }
  final config = settings.services.singleWhere(
    (service) => service.id == serviceId,
  );
  return Uri.parse(config.baseUrl);
}

BatchTranslationProvider providerForInput(
  AppSettings settings,
  SettingsPlatform platform,
) => providerForService(
  settings,
  platform,
  settings.defaultServiceId,
  semanticPairs: false,
);

BatchTranslationProvider providerForService(
  AppSettings settings,
  SettingsPlatform platform,
  String serviceId, {
  bool? semanticPairs,
}) {
  if (serviceId == ServiceConfig.builtinId) return UnofficialGoogleProvider();
  if (serviceId == ServiceConfig.systemId) return AppleTranslationProvider();
  final config = settings.services.singleWhere(
    (service) => service.id == serviceId,
  );
  return ApiTranslationProvider(
    config: config,
    credentials: () => platform.readCredentials(serviceId),
    prompt: settings.prompts[TextMode.translate]!,
    thinking: settings.thinking[TextMode.translate]!,
    semanticPairs: semanticPairs ?? config.semanticPairs,
    glossary: settings.glossary,
  );
}

TranslationProvider? assistProviderForSettings(
  AppSettings settings,
  SettingsPlatform platform,
  TextMode mode,
) => assistProviderForService(
  settings,
  platform,
  mode,
  settings.defaultServiceId,
);

TranslationProvider? assistProviderForService(
  AppSettings settings,
  SettingsPlatform platform,
  TextMode mode,
  String serviceId,
) {
  if (serviceId == ServiceConfig.builtinId ||
      serviceId == ServiceConfig.systemId) {
    return null;
  }
  final config = settings.services.singleWhere(
    (service) => service.id == serviceId,
  );
  if (!config.isModel) return null;
  return ApiTranslationProvider(
    config: config,
    credentials: () => platform.readCredentials(config.id),
    mode: mode,
    prompt: settings.prompts[mode]!,
    thinking: settings.thinking[mode]!,
    semanticPairs: false,
  );
}

List<ServiceChoice> serviceChoices(AppSettings settings) => [
  for (final (id, name) in [
    (ServiceConfig.systemId, ServiceConfig.systemName),
    (ServiceConfig.builtinId, ServiceConfig.builtinName),
  ])
    (
      id: id,
      name: name,
      isModel: false,
      isDefault: settings.defaultServiceId == id,
    ),
  for (final service in settings.services)
    (
      id: service.id,
      name: service.displayName,
      isModel: service.isModel,
      isDefault: settings.defaultServiceId == service.id,
    ),
];

String? translationHistoryModel(TranslationProvider provider) {
  if (provider is! ApiTranslationProvider || provider.config.model.isEmpty) {
    return null;
  }
  return provider.config.model;
}
