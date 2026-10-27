import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/core/palette.dart';
import 'package:pindou_studio/core/palette_data.dart';

void main() {
  tearDown(() {
    // 每个测试后恢复默认色卡，避免影响其他测试组。
    BeadPalette.setActive('default');
  });

  group('色卡注册表', () {
    test('7 套内置色卡齐全且 id 唯一', () {
      expect(BeadPalette.all.length, 7);
      expect(BeadPalette.ordered.length, 7);
      expect(
        BeadPalette.ordered.map((s) => s.id).toSet().length,
        7,
      );
      expect(
        BeadPalette.ordered.map((s) => s.id),
        containsAll(['default', 'mard', 'coco', 'artkal', 'hama', 'perler']),
      );
    });

    test('各品牌色数正确', () {
      expect(BeadPalette.byId('default').colors.length, 83);
      expect(BeadPalette.byId('mard').colors.length, 291);
      expect(BeadPalette.byId('coco').colors.length, 291);
      expect(BeadPalette.byId('artkal').colors.length, 176);
      expect(BeadPalette.byId('artkal-mini').colors.length, 221);
      expect(BeadPalette.byId('hama').colors.length, 89);
      expect(BeadPalette.byId('perler').colors.length, 117);
    });

    test('每套色卡色号唯一且 RGB 合法', () {
      for (final set in BeadPalette.ordered) {
        final codes = set.colors.map((c) => c.code).toSet();
        expect(codes.length, set.colors.length,
            reason: '${set.id} 色号有重复');
        for (final c in set.colors) {
          expect(c.red, inInclusiveRange(0, 255), reason: '${set.id}/${c.code}');
          expect(c.green, inInclusiveRange(0, 255), reason: '${set.id}/${c.code}');
          expect(c.blue, inInclusiveRange(0, 255), reason: '${set.id}/${c.code}');
        }
      }
    });

    test('byId 未知 id 回退通用卡', () {
      expect(BeadPalette.byId('ghost').id, 'default');
    });
  });

  group('切换当前色卡', () {
    test('setActive 切换后静态门面跟随', () {
      expect(BeadPalette.active.id, 'default');
      expect(BeadPalette.colors.length, 83);

      expect(BeadPalette.setActive('mard'), isTrue);
      expect(BeadPalette.active.id, 'mard');
      expect(BeadPalette.colors.length, 291);
      expect(BeadPalette.byCode['A1'], isNotNull);
      // MARD A1 = #FAF4C8 = 250,244,200
      expect(BeadPalette.byCode['A1']!.red, 250);
      expect(BeadPalette.byCode['A1']!.green, 244);
      expect(BeadPalette.byCode['A1']!.blue, 200);

      expect(BeadPalette.setActive('default'), isTrue);
      expect(BeadPalette.colors.length, 83);
    });

    test('setActive 未知 id 返回 false 且不改动', () {
      expect(BeadPalette.setActive('ghost'), isFalse);
      expect(BeadPalette.active.id, 'default');
    });

    test('切换到相同色卡返回 false', () {
      expect(BeadPalette.setActive('default'), isFalse);
    });

    test('nearest 随当前色卡切换', () {
      // 纯绿 (0,255,0)：通用卡最近色为 G8 荧光绿，
      // MARD 最近色为 B5 鲜绿——两卡结果不同。
      BeadPalette.setActive('default');
      final d = BeadPalette.nearest(0, 255, 0);
      expect(d.code, 'G8');
      BeadPalette.setActive('mard');
      final m = BeadPalette.nearest(0, 255, 0);
      expect(m.code, 'B5');
    });
  });

  group('转换引擎使用当前色卡', () {
    test('MARD 色卡下纯色图映射到 MARD 色号', () {
      BeadPalette.setActive('mard');
      // MARD A4 = #FBED56 = 251,237,86（亮黄）。
      final px = List<int>.filled(8 * 8 * 4, 255);
      for (int i = 0; i < px.length; i += 4) {
        px[i] = 251;
        px[i + 1] = 237;
        px[i + 2] = 86;
      }
      final pattern = BeadConverter.convert(
        pixels: Uint8List.fromList(px),
        srcWidth: 8,
        srcHeight: 8,
        options: const ConvertOptions(gridWidth: 4, gridHeight: 4, dither: false),
      );
      expect(pattern.colorCount, 1);
      expect(pattern.cells.first?.code, 'A4');
    });

    test('通用卡下同图映射到通用色号', () {
      BeadPalette.setActive('default');
      // 通用卡 F2 浅黄绿 248,205,50（与目标色几乎一致）。
      final px = List<int>.filled(8 * 8 * 4, 255);
      for (int i = 0; i < px.length; i += 4) {
        px[i] = 248;
        px[i + 1] = 205;
        px[i + 2] = 50;
      }
      final pattern = BeadConverter.convert(
        pixels: Uint8List.fromList(px),
        srcWidth: 8,
        srcHeight: 8,
        options: const ConvertOptions(gridWidth: 4, gridHeight: 4, dither: false),
      );
      expect(pattern.cells.first?.code, 'F2');
    });
  });

  group('色卡数据文件', () {
    test('数据行数与注册表一致', () {
      expect(kMardRows.length, 291);
      expect(kCocoRows.length, 291);
      expect(kArtkalRows.length, 176);
      expect(kArtkalMiniRows.length, 221);
      expect(kHamaRows.length, 89);
      expect(kPerlerRows.length, 117);
    });
  });
}
