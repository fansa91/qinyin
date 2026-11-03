import 'dart:io';

/// 文件名模板渲染 + 非法字符清洗（对齐 xmlyfm 口径）。
/// 占位符：{artist} {title} {album} {quality}
String renderDownloadFilename(
  String format, {
  required String artist,
  required String title,
  required String album,
  required String quality,
}) {
  var name = format
      .replaceAll('{artist}', artist)
      .replaceAll('{title}', title)
      .replaceAll('{album}', album)
      .replaceAll('{quality}', quality);
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  if (name.isEmpty) name = title.isEmpty ? 'track' : title;
  if (name.length > 120) name = name.substring(0, 120).trim();
  return name;
}

/// 在目录内找不冲突的 .m4a 路径（同名追加序号）
Future<String> uniqueM4aPath(String dir, String baseName) =>
    _uniquePath(dir, baseName, '.m4a');

/// 在目录内找不冲突的 .flac 路径（无损下载用）
Future<String> uniqueFlacPath(String dir, String baseName) =>
    _uniquePath(dir, baseName, '.flac');

Future<String> _uniquePath(String dir, String baseName, String ext) async {
  var candidate = '$dir/$baseName$ext';
  var i = 1;
  while (await File(candidate).exists()) {
    i++;
    candidate = '$dir/$baseName ($i)$ext';
  }
  return candidate;
}
