import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/converter.dart';
import '../core/palette.dart';

/// 导出服务：图纸 PNG 渲染与豆数 CSV 生成。
class ExportService {
  ExportService._();

  /// 生成豆数清单 CSV 文本。
  static String buildCsv(BeadPattern pattern) {
    final buf = StringBuffer();
    buf.writeln('色号,颜色名称,数量');
    for (final bc in pattern.counts) {
      buf.writeln('${bc.color.code},${bc.color.name},${bc.count}');
    }
    buf.writeln('总计,,${pattern.totalBeads}');
    return buf.toString();
  }

  /// 将图纸渲染为 PNG 字节（含行列号、网格线、底板分界线、色号与图例）。
  static Future<Uint8List> renderPatternPng(BeadPattern pattern) async {
    const cell = 32; // 每豆 32px
    const margin = 56; // 四周留白（含行列号区域）
    final legendRows = (pattern.counts.length + 7) ~/ 8; // 图例每行 8 项
    const legendRowHeight = 36;
    final legendHeight =
        pattern.counts.isEmpty ? 0 : legendRows * legendRowHeight + 40;

    final width = pattern.width * cell + margin * 2;
    final height = pattern.height * cell + margin * 2 + legendHeight;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));

    // 背景。
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = Colors.white,
    );

    final fillPaint = Paint()..style = PaintingStyle.fill;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // 色块。空格（null）留白不填色不标号。
    for (int y = 0; y < pattern.height; y++) {
      for (int x = 0; x < pattern.width; x++) {
        final bead = pattern.cellAt(x, y);
        if (bead == null) continue;
        final rect =
            Rect.fromLTWH(margin + x * cell.toDouble(), margin + y * cell.toDouble(), cell.toDouble(), cell.toDouble());
        fillPaint.color = Color(bead.argb);
        canvas.drawRect(rect, fillPaint);
        final luma = 0.299 * bead.red + 0.587 * bead.green + 0.114 * bead.blue;
        textPainter.text = TextSpan(
          text: bead.code,
          style: TextStyle(
            color: luma > 140 ? Colors.black87 : Colors.white,
            fontSize: cell * 0.32,
            fontWeight: FontWeight.w600,
          ),
        );
        textPainter.layout(maxWidth: cell.toDouble());
        textPainter.paint(
          canvas,
          Offset(
            margin + x * cell + (cell - textPainter.width) / 2,
            margin + y * cell + (cell - textPainter.height) / 2,
          ),
        );
      }
    }

    // 网格线。
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.black26;
    for (int x = 0; x <= pattern.width; x++) {
      canvas.drawLine(
        Offset(margin + x * cell.toDouble(), margin.toDouble()),
        Offset(margin + x * cell.toDouble(), margin + pattern.height * cell.toDouble()),
        gridPaint,
      );
    }
    for (int y = 0; y <= pattern.height; y++) {
      canvas.drawLine(
        Offset(margin.toDouble(), margin + y * cell.toDouble()),
        Offset(margin + pattern.width * cell.toDouble(), margin + y * cell.toDouble()),
        gridPaint,
      );
    }
    // 每 10 格加深。
    final majorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black45;
    for (int x = 0; x <= pattern.width; x += 10) {
      canvas.drawLine(
        Offset(margin + x * cell.toDouble(), margin.toDouble()),
        Offset(margin + x * cell.toDouble(), margin + pattern.height * cell.toDouble()),
        majorPaint,
      );
    }
    for (int y = 0; y <= pattern.height; y += 10) {
      canvas.drawLine(
        Offset(margin.toDouble(), margin + y * cell.toDouble()),
        Offset(margin + pattern.width * cell.toDouble(), margin + y * cell.toDouble()),
        majorPaint,
      );
    }
    // 外框。
    canvas.drawRect(
      Rect.fromLTWH(margin.toDouble(), margin.toDouble(),
          pattern.width * cell.toDouble(), pattern.height * cell.toDouble()),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black87,
    );

    // 行列号（每 5 格标注）与 29 格底板分界虚线。
    const rulerStep = 5;
    const boardSize = 29;
    final labelStyle = const TextStyle(
      color: Colors.black54,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    void drawLabel(String text, Offset center) {
      textPainter.text = TextSpan(text: text, style: labelStyle);
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          center.dx - textPainter.width / 2,
          center.dy - textPainter.height / 2,
        ),
      );
    }

    for (int x = rulerStep; x <= pattern.width; x += rulerStep) {
      drawLabel('$x', Offset(margin + x * cell.toDouble(), margin - 18));
    }
    for (int y = rulerStep; y <= pattern.height; y += rulerStep) {
      drawLabel('$y', Offset(margin - 18, margin + y * cell.toDouble()));
    }

    final dashPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.deepOrange.withValues(alpha: 0.65);
    for (int x = boardSize; x < pattern.width; x += boardSize) {
      _drawDashedLine(
        canvas, dashPaint,
        Offset(margin + x * cell.toDouble(), margin.toDouble()),
        Offset(margin + x * cell.toDouble(),
            margin + pattern.height * cell.toDouble()),
      );
    }
    for (int y = boardSize; y < pattern.height; y += boardSize) {
      _drawDashedLine(
        canvas, dashPaint,
        Offset(margin.toDouble(), margin + y * cell.toDouble()),
        Offset(margin + pattern.width * cell.toDouble(),
            margin + y * cell.toDouble()),
      );
    }

    // 图例。
    var legendY = margin + pattern.height * cell + 24;
    textPainter.text = TextSpan(
      text: '颜色图例（共 ${pattern.colorCount} 色，总豆数 ${pattern.totalBeads}）',
      style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.bold),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(margin.toDouble(), legendY.toDouble()));
    legendY += 28;

    var col = 0;
    for (final bc in pattern.counts) {
      final lx = margin + col * 120.0;
      canvas.drawCircle(
        Offset(lx + 10, legendY + 10),
        10,
        Paint()..color = Color(bc.color.argb),
      );
      canvas.drawCircle(
        Offset(lx + 10, legendY + 10),
        10,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black26,
      );
      textPainter.text = TextSpan(
        text: '${bc.color.code} x${bc.count}',
        style: const TextStyle(color: Colors.black87, fontSize: 13),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(lx + 26, legendY + 2));
      col++;
      if (col >= 8) {
        col = 0;
        legendY += legendRowHeight;
      }
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// 按标准底板尺寸切分图纸：返回 (列索引, 行索引, 子图纸) 列表。
  /// 每块最大 [boardSize] x [boardSize] 格，不足处保留实际格子。
  static List<(int, int, BeadPattern)> splitByBoards(
    BeadPattern pattern, {
    int boardSize = 29,
  }) {
    final cols = (pattern.width + boardSize - 1) ~/ boardSize;
    final rows = (pattern.height + boardSize - 1) ~/ boardSize;
    final result = <(int, int, BeadPattern)>[];
    for (int by = 0; by < rows; by++) {
      for (int bx = 0; bx < cols; bx++) {
        final x0 = bx * boardSize;
        final y0 = by * boardSize;
        final w = (pattern.width - x0).clamp(1, boardSize);
        final h = (pattern.height - y0).clamp(1, boardSize);
        final cells = <BeadColor?>[];
        for (int y = y0; y < y0 + h; y++) {
          for (int x = x0; x < x0 + w; x++) {
            cells.add(pattern.cellAt(x, y));
          }
        }
        final counts = <BeadColor, int>{};
        for (final c in cells) {
          if (c == null) continue;
          counts[c] = (counts[c] ?? 0) + 1;
        }
        final sorted = counts.entries.toList()
          ..sort((a, b) {
            final byCount = b.value.compareTo(a.value);
            if (byCount != 0) return byCount;
            return a.key.code.compareTo(b.key.code);
          });
        result.add((
          bx,
          by,
          BeadPattern(
            width: w,
            height: h,
            cells: List.unmodifiable(cells),
            counts: List.unmodifiable([
              for (final e in sorted) BeadCount(color: e.key, count: e.value),
            ]),
          ),
        ));
      }
    }
    return result;
  }

  /// 绘制竖直/水平虚线。
  static void _drawDashedLine(
    Canvas canvas, Paint paint, Offset start, Offset end) {
    const dashLen = 6.0;
    const gapLen = 4.0;
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = dx * dx + dy * dy;
    if (len == 0) return;
    final unit = Offset(dx, dy) / len;
    var dist = 0.0;
    while (dist < len) {
      final segEnd = (dist + dashLen).clamp(0.0, len);
      canvas.drawLine(start + unit * dist, start + unit * segEnd, paint);
      dist = segEnd + gapLen;
    }
  }
}
