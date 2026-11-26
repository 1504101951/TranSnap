import 'package:flutter/material.dart';

import '../common/widgets/native_glass.dart';

enum DefinitionLineKind { headword, partOfSpeech, sense, example, plain }

class DefinitionLine {
  const DefinitionLine(this.kind, this.text, {this.phonetic});
  final DefinitionLineKind kind;
  final String text;
  final String? phonetic;

  @override
  bool operator ==(Object other) =>
      other is DefinitionLine &&
      other.kind == kind &&
      other.text == text &&
      other.phonetic == phonetic;

  @override
  int get hashCode => Object.hash(kind, text, phonetic);

  @override
  String toString() => 'DefinitionLine($kind, $text, $phonetic)';
}

final _header = RegExp(r'^([^|]+)\|([^|]+)\|');

final _boundary = RegExp(
  '(?=[①-⑳▸])'
  r'|(?<=^|[\s›])(?=[A-Z]\. [a-z])'
  r'|(?<=^|\s)(?=(?:PHRASAL VERBS|PHRASES|IDIOMS|DERIVATIVES)\b)',
);

final _section = RegExp(
  r'^(PHRASAL VERBS|PHRASES|IDIOMS|DERIVATIVES)\s+(.+)$',
  dotAll: true,
);

final _cjk = RegExp('[㐀-鿿]');

List<DefinitionLine> parseDefinition(String definition) {
  final text = definition.trim();
  final lines = <DefinitionLine>[];
  var rest = text;
  final header = _header.firstMatch(text);
  if (header != null) {
    lines.add(
      DefinitionLine(
        DefinitionLineKind.headword,
        header[1]!.trim(),
        phonetic: header[2]!.trim(),
      ),
    );
    rest = text.substring(header.end);
  }
  final segments = rest
      .split(_boundary)
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList();
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    final section = _section.firstMatch(segment);
    if (section != null) {
      lines
        ..add(DefinitionLine(DefinitionLineKind.partOfSpeech, section[1]!))
        ..add(DefinitionLine(DefinitionLineKind.plain, section[2]!.trim()));
      continue;
    }
    final kind = switch (segment) {
      _ when segment.startsWith('▸') => DefinitionLineKind.example,
      _ when RegExp('^[①-⑳]').hasMatch(segment) => DefinitionLineKind.sense,
      _ when RegExp(r'^[A-Z]\. [a-z]').hasMatch(segment) =>
        DefinitionLineKind.partOfSpeech,
      _
          when header != null &&
              index == 0 &&
              !_cjk.hasMatch(segment) &&
              segment.split(' ').length <= 3 =>
        DefinitionLineKind.partOfSpeech,
      _ => DefinitionLineKind.plain,
    };
    final shown = kind == DefinitionLineKind.example
        ? segment.substring(1).trim()
        : segment;
    lines.add(DefinitionLine(kind, shown));
  }
  return lines;
}

class DictionaryDefinitionView extends StatelessWidget {
  const DictionaryDefinitionView({super.key, required this.definition});
  final String definition;

  static (String, List<DefinitionLine>)? _parsed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    TextStyle style(
      double size,
      double line,
      Color color, [
      FontWeight? weight,
    ]) => GlassFonts.resolve(context).body.copyWith(
      fontSize: size,
      height: line / size,
      color: color,
      fontWeight: weight,
    );

    if (_parsed?.$1 != definition) {
      _parsed = (definition, parseDefinition(definition));
    }
    final lines = _parsed!.$2;
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in lines)
            switch (line.kind) {
              DefinitionLineKind.headword => Text.rich(
                TextSpan(
                  text: line.text,
                  style: style(16, 24, colors.onSurface, FontWeight.w600),
                  children: [
                    if (line.phonetic?.isNotEmpty ?? false) ...[
                      const TextSpan(text: '  '),
                      TextSpan(
                        text: line.phonetic,
                        style: style(12, 22, colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              DefinitionLineKind.partOfSpeech => Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(line.text, style: style(12, 20, colors.primary)),
              ),
              DefinitionLineKind.sense => Padding(
                padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
                child: Text(line.text, style: style(13, 20, colors.onSurface)),
              ),
              DefinitionLineKind.example => Padding(
                padding: const EdgeInsets.only(left: 24, top: 1, bottom: 1),
                child: Text(
                  line.text,
                  style: style(12, 18, colors.onSurfaceVariant),
                ),
              ),
              DefinitionLineKind.plain => Text(
                line.text,
                style: style(13, 20, colors.onSurface),
              ),
            },
        ],
      ),
    );
  }
}
