import '../../sources/model/common.dart';

/// 详情中的章节（阅读顺序）。
///
/// 给出 [unitId] 时返回**包含该章节**的那一组（先查 `units`，再依次查各线路），
/// 这样从非首条线路打开的章节也能取到标题、上一章 / 下一章。
/// 没有给出或都不包含时：优先 `units`，为空时取第一组。
List<Unit> readingOrder(Detail detail, [String? unitId]) {
  if (unitId != null) {
    bool has(List<Unit> units) => units.any((u) => u.id == unitId);
    if (has(detail.units)) return detail.units;
    for (final g in detail.groups ?? const <UnitGroup>[]) {
      if (has(g.units)) return g.units;
    }
  }
  return detail.units.isNotEmpty
      ? detail.units
      : (detail.groups?.firstOrNull?.units ?? const []);
}
