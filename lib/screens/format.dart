/// "just now", "5m ago", "2h ago", "3d ago", then a date.
String formatRelativeTime(DateTime time, DateTime now) {
  final elapsed = now.difference(time);
  if (elapsed.inMinutes < 1) {
    return 'just now';
  }
  if (elapsed.inHours < 1) {
    return '${elapsed.inMinutes}m ago';
  }
  if (elapsed.inDays < 1) {
    return '${elapsed.inHours}h ago';
  }
  if (elapsed.inDays < 7) {
    return '${elapsed.inDays}d ago';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = time.toLocal();
  final year = local.year == now.toLocal().year ? '' : ' ${local.year}';
  return '${local.day} ${months[local.month - 1]}$year';
}
