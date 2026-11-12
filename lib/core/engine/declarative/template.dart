/// 模板变量替换（source-spec §3.2）。
library;

final _placeholder = RegExp(r'\{\{\s*([\w.-]+)\s*\}\}');

/// 把 [template] 中的 `{{name}}` 替换为 [vars] 中的值。
///
/// 值按原样插入，调用方负责编码（例如 `keyword` 在放入 [vars] 前已 URL 编码）。
/// 未定义的变量替换为空字符串，并通过 [onMissing] 报告。
String renderTemplate(
  String template,
  Map<String, String> vars, {
  void Function(String name)? onMissing,
}) => template.replaceAllMapped(_placeholder, (m) {
  final name = m.group(1)!;
  final value = vars[name];
  if (value == null) onMissing?.call(name);
  return value ?? '';
});

/// 把 [ref] 解析为相对 [base] 的绝对地址；无法解析时返回 `null`。
Uri? resolveUrl(Uri base, String ref) {
  final trimmed = ref.trim();
  if (trimmed.isEmpty) return null;
  try {
    return base.resolve(trimmed);
  } on FormatException {
    return null;
  }
}
