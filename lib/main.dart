import 'package:flutter/material.dart';

import 'state/editor_state.dart';
import 'ui/editor/editor_page.dart';

void main() {
  runApp(const PindouStudioApp());
}

class PindouStudioApp extends StatelessWidget {
  const PindouStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '拼豆工作室',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A7BD0)),
        useMaterial3: true,
      ),
      home: const _EditorHome(),
    );
  }
}

/// 应用根：打开即编辑器（单页直入，无图库首页）。
///
/// EditorState 在应用级持有，生命周期与进程一致；
/// 项目的新建/打开/保存收敛到编辑器 AppBar（保存按钮 + 项目菜单）。
class _EditorHome extends StatefulWidget {
  const _EditorHome();

  @override
  State<_EditorHome> createState() => _EditorHomeState();
}

class _EditorHomeState extends State<_EditorHome> {
  late final EditorState _editorState;

  @override
  void initState() {
    super.initState();
    _editorState = EditorState();
  }

  @override
  void dispose() {
    _editorState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EditorPage(state: _editorState);
  }
}
