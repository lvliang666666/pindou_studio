import 'package:flutter/material.dart';

/// 画布专用配色（ThemeExtension）。
///
/// 图纸画布的网格线、标尺、底板分界线、加载遮罩等颜色不套用
/// Material colorScheme（豆子颜色必须保持真实，网格只是辅助层），
/// 因此单独建模并挂到各主题的 ThemeData 上。
///
/// 实现了 `==`/`hashCode`：画布位图缓存用它判断"主题是否变了，
/// 需要重新光栅化"。
@immutable
class PindouCanvasColors extends ThemeExtension<PindouCanvasColors> {
  const PindouCanvasColors({
    required this.canvasBg,
    required this.gridThin,
    required this.gridMajor,
    required this.boardDash,
    required this.rulerText,
    required this.patternBorder,
    required this.overlayMask,
    required this.overlayText,
    this.emptyCell = const Color(0x14000000),
  });

  /// 画布区背景（图纸外围留白）。
  final Color canvasBg;

  /// 细网格线（每 1 格）。
  final Color gridThin;

  /// 加深网格线（每 10 格）。
  final Color gridMajor;

  /// 29 格底板分界虚线。
  final Color boardDash;

  /// 行号/列号标尺文字。
  final Color rulerText;

  /// 图纸外边框。
  final Color patternBorder;

  /// 转换中加载遮罩底色（半透明）。
  final Color overlayMask;

  /// 加载遮罩文字。
  final Color overlayText;

  /// 空格（不放豆）棋盘格纹理色。
  final Color emptyCell;

  static final light = PindouCanvasColors(
    canvasBg: const Color(0xFFEFF1F4),
    gridThin: Colors.black26,
    gridMajor: Colors.black45,
    boardDash: Colors.deepOrange.withValues(alpha: 0.65),
    rulerText: Colors.black54,
    patternBorder: Colors.black87,
    overlayMask: const Color(0xB3FFFFFF),
    overlayText: Colors.black87,
  );

  static final mac = PindouCanvasColors(
    canvasBg: const Color(0xFFE8EAED),
    gridThin: const Color(0x338E8E93),
    gridMajor: const Color(0x598E8E93),
    boardDash: const Color(0xA6FF9500),
    rulerText: const Color(0x993C3C43),
    patternBorder: const Color(0xB33C3C43),
    overlayMask: const Color(0xCCF2F2F7),
    overlayText: const Color(0xE63C3C43),
  );

  static final codex = PindouCanvasColors(
    canvasBg: const Color(0xFF0D1117),
    gridThin: const Color(0xFF30363D),
    gridMajor: const Color(0xFF484F58),
    boardDash: const Color(0xFFD29922),
    rulerText: const Color(0xFF8B949E),
    patternBorder: const Color(0xFF6E7681),
    overlayMask: const Color(0xCC16181D),
    overlayText: const Color(0xFFC9D1D9),
    emptyCell: const Color(0x14FFFFFF),
  );

  static final hacker = PindouCanvasColors(
    canvasBg: Colors.black,
    gridThin: const Color(0xFF003B00),
    gridMajor: const Color(0xFF008F11),
    boardDash: const Color(0xFF00FF41),
    rulerText: const Color(0xFF00C853),
    patternBorder: const Color(0xFF00FF41),
    overlayMask: const Color(0xD9000000),
    overlayText: const Color(0xFF00FF41),
    emptyCell: const Color(0x1400FF41),
  );

  @override
  PindouCanvasColors copyWith({
    Color? canvasBg,
    Color? gridThin,
    Color? gridMajor,
    Color? boardDash,
    Color? rulerText,
    Color? patternBorder,
    Color? overlayMask,
    Color? overlayText,
    Color? emptyCell,
  }) {
    return PindouCanvasColors(
      canvasBg: canvasBg ?? this.canvasBg,
      gridThin: gridThin ?? this.gridThin,
      gridMajor: gridMajor ?? this.gridMajor,
      boardDash: boardDash ?? this.boardDash,
      rulerText: rulerText ?? this.rulerText,
      patternBorder: patternBorder ?? this.patternBorder,
      overlayMask: overlayMask ?? this.overlayMask,
      overlayText: overlayText ?? this.overlayText,
      emptyCell: emptyCell ?? this.emptyCell,
    );
  }

  @override
  PindouCanvasColors lerp(PindouCanvasColors? other, double t) {
    if (other == null) return this;
    return PindouCanvasColors(
      canvasBg: Color.lerp(canvasBg, other.canvasBg, t)!,
      gridThin: Color.lerp(gridThin, other.gridThin, t)!,
      gridMajor: Color.lerp(gridMajor, other.gridMajor, t)!,
      boardDash: Color.lerp(boardDash, other.boardDash, t)!,
      rulerText: Color.lerp(rulerText, other.rulerText, t)!,
      patternBorder: Color.lerp(patternBorder, other.patternBorder, t)!,
      overlayMask: Color.lerp(overlayMask, other.overlayMask, t)!,
      overlayText: Color.lerp(overlayText, other.overlayText, t)!,
      emptyCell: Color.lerp(emptyCell, other.emptyCell, t)!,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PindouCanvasColors &&
        other.canvasBg == canvasBg &&
        other.gridThin == gridThin &&
        other.gridMajor == gridMajor &&
        other.boardDash == boardDash &&
        other.rulerText == rulerText &&
        other.patternBorder == patternBorder &&
        other.overlayMask == overlayMask &&
        other.overlayText == overlayText &&
        other.emptyCell == emptyCell;
  }

  @override
  int get hashCode => Object.hash(canvasBg, gridThin, gridMajor, boardDash,
      rulerText, patternBorder, overlayMask, overlayText, emptyCell);
}

/// 从 BuildContext 取画布配色（未挂载时回退浅色，防御测试环境）。
extension PindouCanvasColorsContext on BuildContext {
  PindouCanvasColors get canvasColors =>
      Theme.of(this).extension<PindouCanvasColors>() ?? PindouCanvasColors.light;
}

/// 一套完整主题：Material 外壳 + 画布配色 + 设置页预览色。
class PindouTheme {
  const PindouTheme({
    required this.id,
    required this.name,
    required this.themeData,
    required this.preview,
  });

  /// 稳定标识（持久化到 settings.json）。
  final String id;

  /// 显示名。
  final String name;

  /// Material 外壳主题（已挂载 PindouCanvasColors 扩展）。
  final ThemeData themeData;

  /// 设置页卡片预览色。
  final PindouThemePreview preview;
}

/// 设置页主题卡片预览色。
class PindouThemePreview {
  const PindouThemePreview({
    required this.background,
    required this.primary,
    required this.surface,
    required this.canvasBg,
    required this.gridLine,
  });

  final Color background;
  final Color primary;
  final Color surface;
  final Color canvasBg;
  final Color gridLine;
}

/// 等宽字体（Windows 自带；中文回退系统字体，只影响数字/拉丁字符）。
const _monoFont = 'Consolas';

/// 全部内置主题（顺序即设置页展示顺序）。
final List<PindouTheme> kPindouThemes = [
  _defaultTheme,
  _macTheme,
  _codexTheme,
  _hackerTheme,
];

/// 按 id 查找主题；未知 id 回退默认主题。
PindouTheme pindouThemeById(String id) {
  for (final t in kPindouThemes) {
    if (t.id == id) return t;
  }
  return _defaultTheme;
}

/// 默认主题：现有蓝色 M3 浅色（视觉与历史版本一致）。
final PindouTheme _defaultTheme = PindouTheme(
  id: 'default',
  name: '默认',
  themeData: ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A7BD0)),
    useMaterial3: true,
  ).copyWith(extensions: [PindouCanvasColors.light]),
  preview: const PindouThemePreview(
    background: Color(0xFFEFF1F4),
    primary: Color(0xFF4A7BD0),
    surface: Colors.white,
    canvasBg: Color(0xFFEFF1F4),
    gridLine: Color(0x42000000),
  ),
);

/// Mac 风：浅灰底、白卡片、iOS 蓝主色、大圆角、细分割线。
final PindouTheme _macTheme = PindouTheme(
  id: 'mac',
  name: 'Mac 风',
  themeData: ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF5F5F7),
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF007AFF),
      brightness: Brightness.light,
    ).copyWith(
      surface: Colors.white,
      surfaceContainerHighest: const Color(0xFFE8EAED),
      outlineVariant: const Color(0x1F3C3C43),
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: Color(0x143C3C43)),
      ),
      margin: EdgeInsets.zero,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    fontFamily: _monoFont,
  ).copyWith(extensions: [PindouCanvasColors.mac]),
  preview: const PindouThemePreview(
    background: Color(0xFFF5F5F7),
    primary: Color(0xFF007AFF),
    surface: Colors.white,
    canvasBg: Color(0xFFE8EAED),
    gridLine: Color(0x338E8E93),
  ),
);

/// Codex 风：深色终端极简——黑灰底、近白主色、细边框、等宽字体。
final PindouTheme _codexTheme = PindouTheme(
  id: 'codex',
  name: 'Codex 风',
  themeData: ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF16181D),
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFFC9D1D9),
      brightness: Brightness.dark,
    ).copyWith(
      surface: const Color(0xFF1C1F26),
      surfaceContainerHighest: const Color(0xFF22262E),
      primary: const Color(0xFFE6EDF3),
      onPrimary: const Color(0xFF16181D),
      outline: const Color(0xFF3D444D),
      outlineVariant: const Color(0xFF2A2F37),
    ),
    cardTheme: const CardThemeData(
      color: Color(0xFF1C1F26),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        side: BorderSide(color: Color(0xFF2A2F37)),
      ),
      margin: EdgeInsets.zero,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xFF1C1F26),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        side: BorderSide(color: Color(0xFF2A2F37)),
      ),
    ),
    dividerColor: const Color(0xFF2A2F37),
    fontFamily: _monoFont,
  ).copyWith(extensions: [PindouCanvasColors.codex]),
  preview: const PindouThemePreview(
    background: Color(0xFF16181D),
    primary: Color(0xFFE6EDF3),
    surface: Color(0xFF1C1F26),
    canvasBg: Color(0xFF0D1117),
    gridLine: Color(0xFF30363D),
  ),
);

/// 黑客风：纯黑底 + matrix 绿 + 等宽字体。
final PindouTheme _hackerTheme = PindouTheme(
  id: 'hacker',
  name: '黑客风',
  themeData: ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.black,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF00FF41),
      brightness: Brightness.dark,
    ).copyWith(
      surface: const Color(0xFF0A0F0A),
      surfaceContainerHighest: const Color(0xFF101810),
      primary: const Color(0xFF00FF41),
      onPrimary: Colors.black,
      outline: const Color(0xFF1E5B2A),
      outlineVariant: const Color(0xFF143318),
    ),
    cardTheme: const CardThemeData(
      color: Color(0xFF0A0F0A),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        side: BorderSide(color: Color(0xFF143318)),
      ),
      margin: EdgeInsets.zero,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xFF0A0F0A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        side: BorderSide(color: Color(0xFF1E5B2A)),
      ),
    ),
    dividerColor: const Color(0xFF143318),
    fontFamily: _monoFont,
  ).copyWith(extensions: [PindouCanvasColors.hacker]),
  preview: const PindouThemePreview(
    background: Colors.black,
    primary: Color(0xFF00FF41),
    surface: Color(0xFF0A0F0A),
    canvasBg: Colors.black,
    gridLine: Color(0xFF008F11),
  ),
);
