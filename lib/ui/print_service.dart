import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/converter.dart';

/// 打印排版服务：生成 A4 分板 PDF（每页一块底板 + 图例页）。
///
/// 中文支持：运行时加载 Windows 系统字体（单文件 TTF；TTC 集合字体
/// 如微软雅黑 msyh.ttc 不被 pdf 包支持，探测时跳过）。
class PrintService {
  PrintService._();

  /// 候选系统字体（按优先级）。仅列单文件 TTF：
  /// - simhei.ttf  黑体（Win7+ 自带）
  /// - Deng.ttf    等线（Win10+ 自带）
  /// - msyh.ttc    微软雅黑（TTC 集合，兜底尝试，pdf 包大概率不支持）
  static const List<String> fontCandidates = [
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\Deng.ttf',
    r'C:\Windows\Fonts\msyh.ttc',
  ];

  /// 字体缓存：同一进程多次打印不重复读盘/解析。
  static pw.Font? _cachedFont;

  /// 测试钩子：注入假字体路径列表后恢复缓存。
  static void resetFontCache() => _cachedFont = null;

  /// 加载中文字体；全部候选失败时抛出可读错误。
  /// [candidates] 可注入（测试用）。
  static Future<pw.Font> loadFont({List<String>? candidates}) async {
    final cached = _cachedFont;
    if (cached != null) return cached;
    final paths = candidates ?? fontCandidates;
    Object? lastError;
    for (final path in paths) {
      try {
        final file = File(path);
        if (!file.existsSync()) continue;
        final data = ByteData.sublistView(await file.readAsBytes());
        final font = pw.Font.ttf(data);
        _cachedFont = font;
        return font;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
      '未找到可用的系统中文字体（尝试过：${paths.join('、')}）。'
      'PDF 中文无法生成。${lastError == null ? '' : '最后错误：$lastError'}',
    );
  }

  /// 生成打印 PDF 字节。
  ///
  /// 页面结构：每块底板一页（页眉含项目名与板号），末页为
  /// 全图颜色图例（色号 + 中文名 + 数量）。
  /// [boardSize] 底板尺寸（豆数），默认 29。
  static Future<Uint8List> buildPdf(
    BeadPattern pattern, {
    String projectName = '拼豆图纸',
    int boardSize = 29,
  }) async {
    final font = await loadFont();
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: font));

    final boards = _boardCount(pattern, boardSize);
    for (int by = 0; by < boards.$2; by++) {
      for (int bx = 0; bx < boards.$1; bx++) {
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) => _boardPage(
            context, font, pattern, projectName,
            bx: bx, by: by, totalBoards: boards.$1 * boards.$2,
            boardSize: boardSize,
          ),
        ));
      }
    }
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (context) => _legendPage(font, pattern, projectName),
    ));

    return doc.save();
  }

  /// 底板分板数：(列数, 行数)。
  static (int, int) _boardCount(BeadPattern pattern, int boardSize) {
    return (
      (pattern.width + boardSize - 1) ~/ boardSize,
      (pattern.height + boardSize - 1) ~/ boardSize,
    );
  }

  /// PDF 总页数（分板页 + 图例页），供测试与预览提示。
  static int pageCount(BeadPattern pattern, {int boardSize = 29}) {
    final b = _boardCount(pattern, boardSize);
    return b.$1 * b.$2 + 1;
  }

  // ---------- 页面布局（pdf 包 widgets 体系） ----------

  /// 单块底板页：页眉 + 网格（色块 + 色号 + 行列号）+ 页脚说明。
  static pw.Widget _boardPage(
    pw.Context context,
    pw.Font font,
    BeadPattern pattern,
    String projectName, {
    required int bx,
    required int by,
    required int totalBoards,
    required int boardSize,
  }) {
    final x0 = bx * boardSize;
    final y0 = by * boardSize;
    final w = (pattern.width - x0).clamp(1, boardSize);
    final h = (pattern.height - y0).clamp(1, boardSize);
    final boardIndex = by * boardsInRow(pattern, boardSize) + bx + 1;

    return pw.Padding(
      padding: const pw.EdgeInsets.all(24),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '$projectName（${pattern.width}x${pattern.height}）',
                style: pw.TextStyle(font: font, fontSize: 12),
              ),
              pw.Text(
                '底板 $boardIndex / $totalBoards（第 ${by + 1} 行 第 ${bx + 1} 列）',
                style: pw.TextStyle(font: font, fontSize: 12),
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Center(
            child: pw.CustomPaint(
              size: PdfPoint(
                _GridPainter.labelGutter + w * _GridPainter.cellFor(boardSize) + 6,
                _GridPainter.labelGutter + h * _GridPainter.cellFor(boardSize) + 6,
              ),
              painter: (canvas, size) {
                _GridPainter(
                  pdfFont: font.getFont(context),
                  pattern: pattern,
                  x0: x0,
                  y0: y0,
                  width: w,
                  height: h,
                  cell: _GridPainter.cellFor(boardSize),
                ).paint(canvas);
              },
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            '每格一颗豆 · 粗线为每 10 格 · 行列号为全图坐标',
            style: pw.TextStyle(
                font: font, fontSize: 9, color: PdfColors.grey600),
          ),
        ],
      ),
    );
  }

  /// 分板列数（供板号计算）。
  static int boardsInRow(BeadPattern pattern, int boardSize) =>
      (pattern.width + boardSize - 1) ~/ boardSize;

  /// 图例页：全图颜色清单（色号 + 中文名 + 数量）。
  static pw.Widget _legendPage(
    pw.Font font,
    BeadPattern pattern,
    String projectName,
  ) {
    const rowsPerTable = 26;
    final counts = pattern.counts;
    final chunks = <List<BeadCount>>[];
    for (int i = 0; i < counts.length; i += rowsPerTable) {
      chunks.add(counts.sublist(i, (i + rowsPerTable).clamp(0, counts.length)));
    }

    return pw.Padding(
      padding: const pw.EdgeInsets.all(24),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            '$projectName · 颜色图例（共 ${pattern.colorCount} 色，总豆数 ${pattern.totalBeads}）',
            style: pw.TextStyle(font: font, fontSize: 14),
          ),
          pw.SizedBox(height: 12),
          for (final chunk in chunks) ...[
            pw.TableHelper.fromTextArray(
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: pw.TextStyle(font: font, fontSize: 10),
              cellStyle: pw.TextStyle(font: font, fontSize: 10),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColors.grey200),
              headers: <String>['色号', '颜色名称', '数量'],
              data: <List<String>>[
                for (final bc in chunk)
                  <String>[bc.color.code, bc.color.name, '${bc.count}'],
              ],
              columnWidths: <int, pw.TableColumnWidth>{
                0: pw.FixedColumnWidth(60),
                1: pw.FlexColumnWidth(),
                2: pw.FixedColumnWidth(60),
              },
            ),
            pw.SizedBox(height: 10),
          ],
          if (counts.isEmpty)
            pw.Text('（无颜色数据）', style: pw.TextStyle(font: font)),
        ],
      ),
    );
  }
}

/// 底板网格绘制：色块 + 色号 + 网格线 + 行列号。
///
/// pdf 包 CustomPainter 是 typedef：`Function(PdfGraphics canvas, PdfPoint size)`。
/// 坐标原点在左下角（PDF 规范），本绘制器内部以左上角为原点换算。
class _GridPainter {
  _GridPainter({
    required this.pdfFont,
    required this.pattern,
    required this.x0,
    required this.y0,
    required this.width,
    required this.height,
    required this.cell,
  });

  /// 已注册到当前 document 的底层字体（pw.Font.getFont(context) 取得）。
  final PdfFont pdfFont;
  final BeadPattern pattern;
  final int x0;
  final int y0;
  final int width;
  final int height;

  /// 每格边长（pt）：按底板尺寸动态计算。
  /// A4 可用宽约 547pt，29 格 x 16pt = 464pt 恰好放得下；
  /// 更大的底板（50/87）按可用宽度缩小格子，保证一页一块板。
  static double cellFor(int boardSize) {
    const usable = 547.0 - labelGutter - 6;
    return math.min(16.0, usable / boardSize);
  }

  /// 每格边长（pt），由构造参数传入（按底板尺寸动态计算）。
  final double cell;

  /// 行列号留白（pt）。
  static const double labelGutter = 14;

  void paint(PdfGraphics canvas) {
    final totalW = width * cell;
    final totalH = height * cell;

    // 色块与色号。空格（null）留白不填色不标号。
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final bead = pattern.cellAt(x0 + x, y0 + y);
        if (bead == null) continue;
        final px = labelGutter + x * cell;
        final py = labelGutter + totalH - (y + 1) * cell; // 行号向下增长
        canvas.setFillColor(PdfColor.fromInt(bead.argb));
        canvas.drawRect(px, py, cell, cell);
        canvas.fillPath();

        final luma =
            0.299 * bead.red + 0.587 * bead.green + 0.114 * bead.blue;
        canvas.setFillColor(luma > 140 ? _black87 : PdfColors.white);
        _drawLabel(canvas, bead.code, cell * 0.34, px + cell / 2, py + cell / 2);
      }
    }

    // 细网格线。
    canvas.setLineWidth(0.4);
    canvas.setStrokeColor(_black26);
    for (int x = 0; x <= width; x++) {
      canvas.drawLine(
        labelGutter + x * cell, labelGutter,
        labelGutter + x * cell, labelGutter + totalH,
      );
    }
    for (int y = 0; y <= height; y++) {
      canvas.drawLine(
        labelGutter, labelGutter + totalH - y * cell,
        labelGutter + totalW, labelGutter + totalH - y * cell,
      );
    }
    canvas.strokePath();

    // 每 10 格加深线。
    canvas.setLineWidth(1.2);
    canvas.setStrokeColor(_black45);
    for (int x = 0; x <= width; x += 10) {
      canvas.drawLine(
        labelGutter + x * cell, labelGutter,
        labelGutter + x * cell, labelGutter + totalH,
      );
    }
    for (int y = 0; y <= height; y += 10) {
      canvas.drawLine(
        labelGutter, labelGutter + totalH - y * cell,
        labelGutter + totalW, labelGutter + totalH - y * cell,
      );
    }
    canvas.strokePath();

    // 外框。
    canvas.setLineWidth(1.5);
    canvas.setStrokeColor(PdfColors.black);
    canvas.drawRect(labelGutter, labelGutter, totalW, totalH);
    canvas.strokePath();

    // 行列号（每 5 格，标注全图坐标 = 板内偏移 + 全图偏移）。
    canvas.setFillColor(_black54);
    const labelSize = 7.5;
    for (int x = 5; x <= width; x += 5) {
      _drawLabel(
        canvas, '${x0 + x}', labelSize,
        labelGutter + x * cell + cell / 2, labelGutter + totalH + 4,
      );
    }
    for (int y = 5; y <= height; y += 5) {
      _drawLabel(
        canvas, '${y0 + y}', labelSize,
        labelGutter - 4, labelGutter + totalH - y * cell + cell / 2,
        rightAlign: true,
      );
    }
  }

  /// 在 (cx, cy) 中心画文字；[rightAlign] 时右对齐于 cx。
  void _drawLabel(
    PdfGraphics canvas,
    String text,
    double fontSize,
    double cx,
    double cy, {
    bool rightAlign = false,
  }) {
    // stringMetrics 返回 em 单位（相对 unitsPerEm），需乘字号。
    final m = pdfFont.stringMetrics(text);
    final w = m.width * fontSize;
    final h = m.height * fontSize;
    final minY = m.top * fontSize;
    final dx = rightAlign ? cx - w : cx - w / 2;
    canvas.drawString(pdfFont, fontSize, text, dx, cy - h / 2 - minY);
  }

  static const PdfColor _black26 = PdfColor(0, 0, 0, 0.26);
  static const PdfColor _black45 = PdfColor(0, 0, 0, 0.45);
  static const PdfColor _black54 = PdfColor(0, 0, 0, 0.54);
  static const PdfColor _black87 = PdfColor(0, 0, 0, 0.87);
}
