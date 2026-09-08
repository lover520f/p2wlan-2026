bool daemonCommandMatchesLog(
  String command,
  String logPath, {
  bool windows = false,
}) {
  final executable = RegExp(r'''^\s*(?:"([^"]+)"|'([^']+)'|(\S+))''').firstMatch(command);
  if (executable == null) return false;
  final path = executable.group(1) ?? executable.group(2) ?? executable.group(3)!;
  final name = path.split(RegExp(r'[/\\]')).last;
  final normalizedName = windows ? name.toLowerCase() : name;
  if (normalizedName != 'p2wlan-daemon' &&
      normalizedName != 'p2wlan-daemon.exe') return false;
  if (RegExp(r'(?:^|\s)--build-info(?:\s|$)').hasMatch(command)) return false;
  final escaped = RegExp.escape(logPath);
  final pattern = RegExp(
    '(?:^|\\s)--log-file(?:=|\\s+)(?:"$escaped"|\'$escaped\'|$escaped)(?=\\s|\$)',
    caseSensitive: !windows,
  );
  return pattern.allMatches(command).length == 1 &&
      RegExp(r'(?:^|\s)--log-file(?:=|\s+)').allMatches(command).length == 1;
}
