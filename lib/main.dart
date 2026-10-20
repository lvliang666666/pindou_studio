import 'package:flutter/material.dart';

import 'data/project_model.dart';
import 'state/editor_state.dart';
import 'ui/editor/editor_page.dart';
import 'ui/library/library_page.dart';

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
      home: const _HomeFlow(),
    );
  }
}

/// 根导航流：项目库 <-> 编辑器。
///
/// EditorState 在应用级持有（跨页面共享），编辑器退出时 reset。
class _HomeFlow extends StatefulWidget {
  const _HomeFlow();

  @override
  State<_HomeFlow> createState() => _HomeFlowState();
}

class _HomeFlowState extends State<_HomeFlow> {
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
    return Navigator(
      onDidRemovePage: (page) {},
      pages: [
        MaterialPage(
          key: const ValueKey('library'),
          child: LibraryPage(
            repository: _editorState.repository,
            onCreateProject: _createProject,
            onOpenProject: _openProject,
          ),
        ),
        if (_editorOpen)
          MaterialPage(
            key: const ValueKey('editor'),
            child: EditorPage(state: _editorState),
          ),
      ],
    );
  }

  /// 编辑器是否已打开（简单导航状态）。
  bool _editorOpen = false;

  /// 新建项目：重置编辑器后进入编辑器页（用户再导入图片）。
  Future<void> _createProject() async {
    _editorState.reset();
    setState(() => _editorOpen = true);
  }

  /// 打开已有项目：加载后进入编辑器页。
  Future<void> _openProject(SavedProject project) async {
    try {
      await _editorState.loadProject(project);
      if (!mounted) return;
      setState(() => _editorOpen = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开项目失败：$e')),
      );
    }
  }
}
