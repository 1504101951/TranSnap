enum FontFile {
  inter(
    'Inter.ttf',
    876576,
    '29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031',
  ),
  notoSansSC(
    'NotoSansSC.ttf',
    17772300,
    'a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da',
  ),
  geist(
    'Geist.ttf',
    169056,
    '73894e0448cae90a92b6c2f8732b7bb9acb7b94c418bff559dad4a18e1de9659',
  ),
  instrumentSans(
    'InstrumentSans.ttf',
    194336,
    'b24f1812584816958afcf22e22d08e44318c5e51651e25d2438efdde389b33b1',
  ),
  sourceSerif4(
    'SourceSerif4.ttf',
    1209508,
    '97b2d4da6e3cb494b5a1e66ae176914d852ccabef49e0c02c0df25f3e39aca0b',
  ),
  notoSerifSC(
    'NotoSerifSC.ttf',
    25125512,
    '050080d9255a86808f2945bffac582b31ef32bc36411ce29563b4961670c66f9',
  ),
  ibmPlexSans(
    'IBMPlexSans.ttf',
    537244,
    '3b031aa4216174205bd8471f88a49b91f093169e9e87bd5262242bc5967fe2e3',
  ),
  nunito(
    'Nunito.ttf',
    276932,
    'bb55a5ca5c2042335b3991af27c4d0705d0ef41cac6164ac737fd8f2a1e85207',
  ),
  literata(
    'Literata.ttf',
    955132,
    'b41138c9373112f32abb589cc22e8674b06ed4048b0c513be922bdd26f274440',
  ),
  lxgwWenKai(
    'LXGWWenKai-Regular.ttf',
    25928940,
    '2d73eea94ad808999d90c0000c239a84a33b09d4bc6ab6c5b8bbf1eda8a7fc8b',
  ),
  spaceGrotesk(
    'SpaceGrotesk.ttf',
    136676,
    'acad6de1fc93436f5c0f1f4137751ef04f1aea3063e7036535970ffcfbd79f72',
  ),
  smileySans(
    'SmileySans-Oblique.ttf',
    2629764,
    'b447d7e781f08bc95c4c9f23ba71ed2b8ebb639aa7184485c71c4ca5afcd25c4',
  ),
  atkinsonHyperlegibleNext(
    'AtkinsonHyperlegibleNext.ttf',
    114552,
    '5a455d1cfa099b601ab70751bb9673e8fe1854dc4500c80e1a220d0d75e31745',
  );

  const FontFile(this.fileName, this.bytes, this.sha256);

  final String fileName;
  final int bytes;
  final String sha256;

  static const releaseUrl =
      'https://github.com/1504101951/TranSnap/releases/download/fonts-v1/';

  static const bundledDirectory = 'assets/fonts';

  static const bundled = {inter, notoSansSC};

  String get family => 'TranSnap ${fileName.split('.').first}';

  String get url => '$releaseUrl$fileName';

  bool get isBundled => bundled.contains(this);
}

typedef FontPair = ({FontFile latin, FontFile cjk});

enum FontSet {
  neutral(
    '中性',
    'Inter + 思源黑体',
    ui: (latin: FontFile.inter, cjk: FontFile.notoSansSC),
  ),
  geometric(
    '几何利落',
    'Geist + 思源黑体',
    ui: (latin: FontFile.geist, cjk: FontFile.notoSansSC),
  ),
  claude(
    'Claude 风',
    'Instrument Sans + Source Serif 4 / 思源宋体',
    ui: (latin: FontFile.instrumentSans, cjk: FontFile.notoSansSC),
    body: (latin: FontFile.sourceSerif4, cjk: FontFile.notoSerifSC),
  ),
  humanist(
    '人文科技',
    'IBM Plex Sans + 思源黑体',
    ui: (latin: FontFile.ibmPlexSans, cjk: FontFile.notoSansSC),
  ),
  rounded(
    '圆润友好',
    'Nunito + 思源黑体',
    ui: (latin: FontFile.nunito, cjk: FontFile.notoSansSC),
  ),
  bookish(
    '书卷',
    'Literata + 霞鹜文楷',
    ui: (latin: FontFile.literata, cjk: FontFile.lxgwWenKai),
  ),
  character(
    '个性',
    'Space Grotesk + 得意黑 / 思源黑体',
    ui: (latin: FontFile.spaceGrotesk, cjk: FontFile.notoSansSC),
    title: (latin: FontFile.spaceGrotesk, cjk: FontFile.smileySans),
  ),
  legible(
    '高可读',
    'Atkinson Hyperlegible Next + 思源黑体',
    ui: (latin: FontFile.atkinsonHyperlegibleNext, cjk: FontFile.notoSansSC),
  );

  const FontSet(
    this.label,
    this.composition, {
    required this.ui,
    this._body,
    this._title,
  });

  final String label;
  final String composition;
  final FontPair ui;
  final FontPair? _body;
  final FontPair? _title;

  static const fallback = neutral;

  FontPair get body => _body ?? ui;

  FontPair get title => _title ?? ui;

  Set<FontFile> get files => {
    for (final pair in [ui, body, title]) ...[pair.latin, pair.cjk],
  };

  bool get isBundled => files.every((file) => file.isBundled);

  String get nameFamily => 'TranSnap Name $name';

  String get nameTitleFamily => 'TranSnap Name $name Title';

  String get nameTextFamily => 'TranSnap Name $name Text';

  static FontSet parse(Object? value) =>
      value == null ? fallback : FontSet.values.byName(value as String);
}
