import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/library_service.dart';
import '../services/qishui_service.dart';

/// 搜索页：只有联想（sug）+ 搜索历史。
/// 游客态全文搜索被服务端掏空（extra.empty_search=1），
/// 这里诚实说明限制：点联想词只记录历史并提示，不伪造结果页。
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<String> _sugs = [];
  Timer? _debounce;
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (q.trim().isEmpty) {
        setState(() => _sugs = []);
        return;
      }
      setState(() => _loading = true);
      try {
        final sugs = await context.read<QishuiService>().sug(q);
        if (mounted && _controller.text == q) {
          setState(() {
            _sugs = sugs;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  void _tapWord(String word) {
    context.read<LibraryService>().addSearchHistory(word);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('游客模式暂不支持全文搜索结果，可从首页发现/歌单中找歌'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '搜歌名/歌手（仅联想）'),
          onChanged: _onChanged,
          onSubmitted: _tapWord,
        ),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('游客限制：搜索仅提供联想词，暂无结果页'),
          ),
          for (final s in _sugs)
            ListTile(
              leading: const Icon(Icons.search),
              title: Text(s),
              onTap: () => _tapWord(s),
            ),
          if (_sugs.isEmpty && library.searchHistory.isNotEmpty) ...[
            ListTile(
              title: const Text('搜索历史'),
              trailing: TextButton(
                onPressed: library.clearSearchHistory,
                child: const Text('清空'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final h in library.searchHistory)
                    ActionChip(
                      label: Text(h),
                      onPressed: () {
                        _controller.text = h;
                        _onChanged(h);
                      },
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
