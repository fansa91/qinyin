import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';

/// 封面图（列表用 webp 小图变体，详情用原图）
class CoverImage extends StatelessWidget {
  final CoverArt? cover;
  final double? width;
  final double? height;
  final double radius;
  final bool small;

  const CoverImage({
    super.key,
    required this.cover,
    this.width,
    this.height,
    this.radius = 8,
    this.small = true,
  });

  @override
  Widget build(BuildContext context) {
    final url = cover?.url(webp: small);
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: scheme.onSurfaceVariant),
    );
    if (url == null || url.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(width: width, height: height, child: placeholder),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      ),
    );
  }
}
