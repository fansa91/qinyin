import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/responsive.dart';
import '../models/models.dart';
import '../services/player_service.dart';
import '../services/qishui_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/track_tile.dart';

/// 电台页：曲目流（接口无分页 cursor，取回多少播多少）
class RadioScreen extends StatelessWidget {
  final RadioStation radio;
  const RadioScreen({super.key, required this.radio});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(radio.title)),
      body: FutureBuilder<List<Track>>(
        future: context.read<QishuiService>().radioTracks(radio.id),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return const Center(child: Text('加载失败，请检查网络'));
          }
          final tracks = snap.data ?? const [];
          // 宽屏自适应：内容限宽居中，曲目列表不拉满整窗
          return ConstrainedCenter(
            maxWidth: Breakpoints.listMaxWidth,
            child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      CoverImage(
                          cover: radio.cover, width: 96, height: 96, radius: 48),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(radio.title,
                                style: Theme.of(context).textTheme.titleLarge),
                            if (radio.desc.isNotEmpty)
                              Text(radio.desc,
                                  style:
                                      Theme.of(context).textTheme.bodyMedium),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('播放全部'),
                              onPressed: tracks.isEmpty
                                  ? null
                                  : () => context
                                      .read<PlayerService>()
                                      .playQueue(tracks, 0),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (context, i) => TrackTile(
                  track: tracks[i],
                  onTap: () =>
                      context.read<PlayerService>().playQueue(tracks, i),
                ),
              ),
            ],
            ),
          );
        },
      ),
    );
  }
}
