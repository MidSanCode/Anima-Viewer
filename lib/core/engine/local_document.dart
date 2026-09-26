/// 内置降级文档模型：在引擎就绪前，让编辑器的**全部 UI 与工作流**可跑通。
///
/// 设计原则：
/// * 数据形状与 `spec/model.json`（tasks.md §1.3）一致，引擎接入后可直接
///   `doc.query` / `doc.command` 平移，不需要改 UI；
/// * 所有写操作都经过 [applyCommand]，天然获得 undo/redo 与 `doc.revision`；
/// * 快照式撤销（JSON 深拷贝）——数据量级在编辑器可接受范围内，
///   换来实现简单、可序列化、可重放（契约要求命令幂等可重放）。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'am_types.dart';

String newAnimaId() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// 取出（并**保持活引用**的）JSON 对象。
///
/// 文档内部一律用活引用改数据：`jsonDecode` 产出 `Map<String, dynamic>`，
/// 与 `Map<String, Object?>` 可互认；只有类型不匹配时才复制成
/// `Map<String, Object?>`，并由调用方写回 `data`。
Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) return value;
  final out = <String, Object?>{};
  if (value is Map) value.forEach((k, v) => out['$k'] = v);
  return out;
}

/// 内置文档。
class LocalDocument {
  LocalDocument() {
    data = defaultAnimaDocument();
  }

  LocalDocument.fromJson(Map<String, Object?> json) {
    data = json;
  }

  /// 文档本体（可 JSON 序列化）。
  late Map<String, Object?> data;

  int _revision = 0;

  /// 当前修订号，UI 据此做增量刷新。
  int get revision => _revision;

  final List<String> _undo = <String>[];
  final List<String> _redo = <String>[];
  static const int _maxHistory = 120;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// 最近一条命令的 op 名（历史面板展示用）。
  final List<String> history = <String>[];

  List<String> get historyLabels => List<String>.unmodifiable(history);

  Map<String, Object?> get nodes {
    final live = _map(data['nodes']);
    data['nodes'] = live;
    return live;
  }

  Map<String, Object?> get parameters {
    final live = _map(data['parameters']);
    data['parameters'] = live;
    return live;
  }

  List<Object?> get motions => asJsonList(data['motions']);

  List<Object?> get expressions => asJsonList(data['expressions']);

  List<Object?> get physics => asJsonList(data['physics']);

  List<Object?> get pose => asJsonList(data['pose']);

  Map<String, Object?> get settings => _map(data['settings']);

  Map<String, Object?> get config => _map(data['config']);

  String? get rootId => data['root'] as String?;

  String snapshotJson() => const JsonEncoder.withIndent('\t').convert(data);

  Map<String, Object?> snapshot() =>
      jsonDecode(jsonEncode(data)) as Map<String, Object?>;

  /// 执行一条命令（唯一写入口，契约 §3.2）。
  int applyCommand(Map<String, Object?> command) {
    final op = '${command['op'] ?? ''}';
    if (op.isEmpty) {
      throw const AmException('BAD_COMMAND', 'command.op is required');
    }
    final before = snapshotJson();
    _dispatch(op, command);
    _undo.add(before);
    if (_undo.length > _maxHistory) _undo.removeAt(0);
    _redo.clear();
    history.add(op);
    if (history.length > _maxHistory) history.removeAt(0);
    _revision++;
    return _revision;
  }

  /// 直接改文档（不含撤销），用于运行时/装配。
  void touch() => _revision++;

  int undo() {
    if (_undo.isEmpty) return _revision;
    _redo.add(snapshotJson());
    data = jsonDecode(_undo.removeLast()) as Map<String, Object?>;
    history.add('doc.undo');
    _revision++;
    return _revision;
  }

  int redo() {
    if (_redo.isEmpty) return _revision;
    _undo.add(snapshotJson());
    data = jsonDecode(_redo.removeLast()) as Map<String, Object?>;
    history.add('doc.redo');
    _revision++;
    return _revision;
  }

  /// 命令分发。返回 `null` 表示命令已就地生效。
  Object? _dispatch(String op, Map<String, Object?> c) {
    switch (op) {
      case 'project.set_config':
        final patch = _map(c['config']);
        config.addAll(patch);
        return null;
      case 'part.create':
        return _createNode(
          AmNodeKind.part,
          name: '${c['name'] ?? _nextName('part')}',
          parent: c['parent'] as String?,
        );
      case 'node.rename':
        _node(c)['name'] = '${c['name'] ?? ''}';
        return null;
      case 'node.create':
        return _createByKind(
          AmNodeKind.parse(c['kind']),
          name: '${c['name'] ?? ''}',
          parent: c['parent'] as String?,
        );
      case 'node.duplicate':
        return _duplicateNode(_requireId(c));
      case 'node.reparent':
        _reparent(
          _requireId(c),
          c['parent'] as String?,
          index: c['index'] == null ? null : asInt(c['index']),
        );
        return null;
      case 'node.reorder':
        _reorder(_requireId(c), asInt(c['index']));
        return null;
      case 'node.delete':
        _deleteNode(_requireId(c));
        return null;
      case 'node.set_visible':
        _node(c)['visible'] = asBool(c['value'], true);
        return null;
      case 'node.set_locked':
        _node(c)['locked'] = asBool(c['value']);
        return null;
      case 'node.set_property':
        final node = _node(c);
        final key = '${c['key'] ?? ''}';
        if (key.isEmpty) {
          throw const AmException('BAD_COMMAND', 'node.set_property needs key');
        }
        node[key] = c['value'];
        return null;
      case 'drawable.set_blend':
        _node(c)['blend_mode'] = AmBlendMode.parse(c['value']).wire;
        return null;
      case 'drawable.set_opacity':
        _node(c)['opacity'] = asDouble(c['value'], 1).clamp(0.0, 1.0);
        return null;
      case 'drawable.set_mask':
        _node(c)['mask'] = asJsonList(c['value']).map((e) => '$e').toList();
        return null;
      case 'drawable.set_texture':
        _node(c)['texture'] = c['texture'];
        return null;
      case 'drawable.set_uv':
        final uv = asJsonList(c['uv']);
        if (uv.length == 4) _node(c)['uv'] = uv;
        return null;
      case 'mesh.set':
        _node(c)['mesh'] = _map(c['mesh']);
        return null;
      case 'mesh.auto_generate':
        _autoGenerateMesh(
          _node(c),
          rows: math.max(1, asInt(c['rows'], 4)),
          cols: math.max(1, asInt(c['cols'], 4)),
        );
        return null;
      case 'mesh.move_vertices':
        _moveVertices(
          _node(c),
          asJsonList(c['indices']).map(asInt).toList(),
          asDouble(c['dx']),
          asDouble(c['dy']),
        );
        return null;
      case 'mesh.add_vertices':
        _addVertices(_node(c), asJsonList(c['vertices']));
        return null;
      case 'mesh.remove_vertices':
        _removeVertices(_node(c), asJsonList(c['indices']).map(asInt).toList());
        return null;
      case 'mesh.split_triangle':
        _splitTriangle(
          _node(c),
          asInt(c['triangle']),
          asDouble(c['t']).clamp(0.05, 0.95),
        );
        return null;
      case 'deformer.create_warp':
        return _createWarp(
          name: '${c['name'] ?? _nextName('warp')}',
          parent: c['parent'] as String?,
          rows: math.max(1, asInt(c['rows'], 2)),
          cols: math.max(1, asInt(c['cols'], 2)),
          bounds: asJsonList(c['bounds']),
        );
      case 'deformer.create_rotation':
        return _createRotation(
          name: '${c['name'] ?? _nextName('rotation')}',
          parent: c['parent'] as String?,
          position: asJsonList(c['position']),
        );
      case 'deformer.set_parent':
        _reparent(_requireId(c), c['parent'] as String?);
        return null;
      case 'deformer.move_control_point':
        _moveControlPoint(
          _node(c),
          asInt(c['index']),
          asDouble(c['dx']),
          asDouble(c['dy']),
        );
        return null;
      case 'param.create':
        return _createParameter(c);
      case 'param.delete':
        _deleteParameter('${c['id'] ?? c['param'] ?? ''}');
        return null;
      case 'param.set_range':
        final param = _parameter(c);
        param['min'] = asDouble(c['min'], -1);
        param['max'] = asDouble(c['max'], 1);
        return null;
      case 'param.set_default':
        _parameter(c)['default'] = asDouble(c['value']);
        return null;
      case 'param.rename':
        _parameter(c)['name'] = '${c['name'] ?? ''}';
        return null;
      case 'param.set_group':
        _parameter(c)['group'] = '${c['group'] ?? ''}';
        return null;
      case 'param.set_keys':
        _parameter(c)['keys'] = asJsonList(c['keys']);
        return null;
      case 'keyform.record':
        return _recordKeyform(c);
      case 'keyform.set_value':
        _setKeyformValue(c);
        return null;
      case 'keyform.delete':
        _deleteKeyform(c);
        return null;
      case 'keyform.set_blend_type':
        _setKeyformBlend(c);
        return null;
      case 'texture.set':
        _setTexture(c);
        return null;
      case 'texture.import_psd':
        return _importPsd(c);
      case 'texture.repack':
        _repackTextures(c);
        return null;
      case 'physics.add_setting':
        return _addPhysics(c);
      case 'physics.remove_setting':
        data['physics'] = physics
            .where((e) => _map(e)['id'] != c['id'])
            .toList();
        return null;
      case 'physics.set_property':
        _setPhysicsProperty(c);
        return null;
      case 'motion.create':
        return _createMotion(c);
      case 'motion.set_key':
        _setMotionKey(c);
        return null;
      case 'motion.remove_key':
        _removeMotionKey(c);
        return null;
      case 'motion.set_curve':
        _setMotionCurve(c);
        return null;
      case 'motion.delete':
        final name = '${c['motion'] ?? c['name'] ?? ''}';
        data['motions'] = motions
            .where((e) => _map(e)['name'] != name)
            .toList();
        return null;
      case 'motion.set_meta':
        _setMotionMeta(c);
        return null;
      case 'expression.create':
        return _createExpression(c);
      case 'expression.set_param':
        _setExpressionParam(c);
        return null;
      case 'expression.delete':
        data['expressions'] = expressions
            .where((e) => _map(e)['name'] != c['name'])
            .toList();
        return null;
      case 'pose.add':
        return _addPose(c);
      case 'pose.remove':
        data['pose'] = pose.where((e) => _map(e)['id'] != c['id']).toList();
        return null;
      case 'settings.set':
        final patch = _map(c['settings']);
        settings.addAll(patch);
        return null;
      default:
        throw AmException('UNSUPPORTED', 'unsupported command op: $op');
    }
  }

  // -------------------------------------------------------------------------
  // 节点
  // -------------------------------------------------------------------------

  String _requireId(Map<String, Object?> c) {
    final id = '${c['id'] ?? c['node'] ?? ''}';
    if (id.isEmpty) {
      throw const AmException('BAD_COMMAND', 'command requires node id');
    }
    return id;
  }

  Map<String, Object?> _node(Map<String, Object?> c) {
    final id = _requireId(c);
    final node = _map(nodes[id]);
    if (node.isEmpty) {
      throw AmException('NODE_NOT_FOUND', 'node $id not found');
    }
    nodes[id] = node;
    return node;
  }

  Map<String, Object?> _parameter(Map<String, Object?> c) {
    final id = '${c['id'] ?? c['param'] ?? ''}';
    if (id.isEmpty) {
      throw const AmException('BAD_COMMAND', 'command requires param id');
    }
    final param = _map(parameters[id]);
    if (param.isEmpty) {
      throw AmException('PARAM_NOT_FOUND', 'parameter $id not found');
    }
    parameters[id] = param;
    return param;
  }

  String _nextName(String prefix) {
    var index = 1;
    final used = nodes.values.map((n) => '${_map(n)['name']}').toSet();
    while (used.contains('$prefix$index')) {
      index++;
    }
    return '$prefix$index';
  }

  String _createNode(AmNodeKind kind, {String? name, String? parent}) {
    final id = newAnimaId();
    final node = <String, Object?>{
      'id': id,
      'name': name ?? kind.wire,
      'type': kind.wire,
      'parent': parent ?? rootId,
      'children': <Object?>[],
      'visible': true,
      'locked': false,
    };
    if (kind == AmNodeKind.drawable) {
      node.addAll(<String, Object?>{
        'opacity': 1.0,
        'blend_mode': AmBlendMode.normal.wire,
        'texture': null,
        'uv': <Object?>[0.0, 0.0, 1.0, 1.0],
        'mask': <Object?>[],
        'mesh': <String, Object?>{
          'vertices': <Object?>[],
          'uvs': <Object?>[],
          'indices': <Object?>[],
        },
      });
    }
    nodes[id] = node;
    final targetId = parent ?? rootId;
    if (targetId != null) {
      final target = _map(nodes[targetId]);
      if (target.isNotEmpty) {
        target['children'] = <Object?>[...asJsonList(target['children']), id];
        nodes[targetId] = target;
      }
    }
    return id;
  }

  /// `node.create`：按种类创建节点（部件 / 可绘制对象 / 两种变形器）。
  String _createByKind(AmNodeKind kind, {String? name, String? parent}) {
    final nodeName = (name == null || name.isEmpty)
        ? _nextName(kind.wire)
        : name;
    switch (kind) {
      case AmNodeKind.drawable:
        final id = _createNode(kind, name: nodeName, parent: parent);
        final node = _map(nodes[id]);
        if (node.isNotEmpty) _autoGenerateMesh(node, rows: 2, cols: 2);
        return id;
      case AmNodeKind.warpDeformer:
        return _createWarp(
          name: nodeName,
          parent: parent,
          rows: 2,
          cols: 2,
          bounds: const <Object?>[],
        );
      case AmNodeKind.rotationDeformer:
        return _createRotation(
          name: nodeName,
          parent: parent,
          position: const <Object?>[],
        );
      case AmNodeKind.part:
      case AmNodeKind.unknown:
        return _createNode(AmNodeKind.part, name: nodeName, parent: parent);
    }
  }

  /// `node.duplicate`：复制子树（含网格/变形器数据），插在原节点之后。
  ///
  /// 关键形（keyform）不随复制迁移，避免参数曲线出现悬挂引用。
  String _duplicateNode(String id) {
    final source = _map(nodes[id]);
    if (source.isEmpty) {
      throw AmException('NODE_NOT_FOUND', 'node $id not found');
    }
    final copy = _copySubtree(
      source,
      parentOverride: source['parent'] as String?,
    );
    final parentId = '${copy['parent']}';
    final parent = _map(nodes[parentId]);
    if (parent.isNotEmpty) {
      final children = asJsonList(parent['children']).map((e) => '$e').toList();
      final index = children.indexOf(id);
      children.insert(index < 0 ? children.length : index + 1, '${copy['id']}');
      parent['children'] = children;
      nodes[parentId] = parent;
    }
    return '${copy['id']}';
  }

  Map<String, Object?> _copySubtree(
    Map<String, Object?> source, {
    String? parentOverride,
  }) {
    final id = newAnimaId();
    final childIds = <Object?>[];
    final copy = <String, Object?>{
      for (final entry in source.entries)
        entry.key: entry.key == 'children' ? childIds : _deepClone(entry.value),
      'id': id,
      'parent': parentOverride,
      'name': '${source['name']} copy',
    };
    nodes[id] = copy;
    for (final childId in asJsonList(source['children'])) {
      final child = _map(nodes['$childId']);
      if (child.isEmpty) continue;
      final childCopy = _copySubtree(child, parentOverride: id);
      childIds.add(childCopy['id']);
    }
    nodes[id] = copy;
    return copy;
  }

  static Object? _deepClone(Object? value) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          '${entry.key}': _deepClone(entry.value),
      };
    }
    if (value is List) {
      return <Object?>[for (final item in value) _deepClone(item)];
    }
    return value;
  }

  void _reparent(String id, String? parent, {int? index}) {
    final node = _map(nodes[id]);
    if (node.isEmpty) throw AmException('NODE_NOT_FOUND', 'node $id not found');
    final target = parent ?? rootId;
    if (target == null) {
      throw const AmException('BAD_COMMAND', 'document has no root node');
    }
    if (target == id || _isDescendant(target, id)) {
      throw const AmException('BAD_COMMAND', 'cannot reparent into itself');
    }
    final oldParent = _map(nodes['${node['parent']}']);
    if (oldParent.isNotEmpty) {
      oldParent['children'] = asJsonList(
        oldParent['children'],
      ).where((e) => '$e' != id).toList();
      nodes['${node['parent']}'] = oldParent;
    }
    node['parent'] = target;
    final newParent = _map(nodes[target]);
    final children = asJsonList(
      newParent['children'],
    ).where((e) => '$e' != id).toList();
    final at = index == null
        ? children.length
        : index.clamp(0, children.length);
    children.insert(at, id);
    newParent['children'] = children;
    nodes[target] = newParent;
    nodes[id] = node;
  }

  bool _isDescendant(String? candidate, String ancestor) {
    var current = candidate;
    var guard = 0;
    while (current != null && current.isNotEmpty && guard++ < 4096) {
      if (current == ancestor) return true;
      current = _map(nodes[current])['parent'] as String?;
    }
    return false;
  }

  void _reorder(String id, int index) {
    final node = _map(nodes[id]);
    if (node.isEmpty) throw AmException('NODE_NOT_FOUND', 'node $id not found');
    final parentId = '${node['parent']}';
    final parent = _map(nodes[parentId]);
    final children = asJsonList(
      parent['children'],
    ).where((e) => '$e' != id).toList();
    final at = index.clamp(0, children.length);
    children.insert(at, id);
    parent['children'] = children;
    nodes[parentId] = parent;
    applyDrawOrder();
  }

  void _deleteNode(String id) {
    if (id == rootId) {
      throw const AmException('BAD_COMMAND', 'cannot delete root node');
    }
    final node = _map(nodes[id]);
    if (node.isEmpty) throw AmException('NODE_NOT_FOUND', 'node $id not found');
    final parent = _map(nodes['${node['parent']}']);
    if (parent.isNotEmpty) {
      parent['children'] = asJsonList(
        parent['children'],
      ).where((e) => '$e' != id).toList();
      nodes['${node['parent']}'] = parent;
    }
    for (final child in asJsonList(node['children'])) {
      _deleteNode('$child');
    }
    nodes.remove(id);
  }

  /// 重新计算绘制顺序（art path）：先序遍历。
  List<String> applyDrawOrder() {
    final result = <String>[];
    void walk(String id) {
      final node = _map(nodes[id]);
      final kind = AmNodeKind.parse(node['type']);
      if (kind == AmNodeKind.part || kind == AmNodeKind.drawable) {
        result.add(id);
      }
      for (final child in asJsonList(node['children'])) {
        walk('$child');
      }
    }

    if (rootId != null) walk(rootId!);
    for (var i = 0; i < result.length; i++) {
      final node = _map(nodes[result[i]]);
      node['draw_order'] = i;
      nodes[result[i]] = node;
    }
    data['art_path'] = result;
    return result;
  }

  // -------------------------------------------------------------------------
  // 网格
  // -------------------------------------------------------------------------

  Map<String, Object?> _mesh(Map<String, Object?> node) {
    final mesh = _map(node['mesh']);
    if (mesh.isEmpty) {
      node['mesh'] = <String, Object?>{
        'vertices': <Object?>[],
        'uvs': <Object?>[],
        'indices': <Object?>[],
      };
    }
    return _map(node['mesh']);
  }

  void _autoGenerateMesh(
    Map<String, Object?> node, {
    required int rows,
    required int cols,
  }) {
    final uv = asJsonList(node['uv']);
    final u0 = uv.length == 4 ? asDouble(uv[0]) : 0.0;
    final v0 = uv.length == 4 ? asDouble(uv[1]) : 0.0;
    final u1 = uv.length == 4 ? asDouble(uv[2]) : 1.0;
    final v1 = uv.length == 4 ? asDouble(uv[3]) : 1.0;
    final bounds = _map(node['bounds']);
    final x0 = asDouble(bounds['x'], -0.5);
    final y0 = asDouble(bounds['y'], -0.5);
    final x1 = asDouble(bounds['width'], 0.5);
    final y1 = asDouble(bounds['height'], 0.5);

    final vertices = <Object?>[];
    final uvs = <Object?>[];
    for (var r = 0; r <= rows; r++) {
      final t = r / rows;
      for (var c = 0; c <= cols; c++) {
        final s = c / cols;
        // 坐标系：原点画布中心、Y 轴向上、单位 = 画布像素。
        vertices.add(<Object?>[x0 + (x1 - x0) * s, y0 + (y1 - y0) * t]);
        uvs.add(<Object?>[u0 + (u1 - u0) * s, v0 + (v1 - v0) * t]);
      }
    }
    final indices = <Object?>[];
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final i0 = r * (cols + 1) + c;
        final i1 = i0 + 1;
        final i2 = i0 + (cols + 1);
        final i3 = i2 + 1;
        indices.addAll(<Object?>[i0, i2, i1, i1, i2, i3]);
      }
    }
    node['mesh'] = <String, Object?>{
      'vertices': vertices,
      'uvs': uvs,
      'indices': indices,
    };
  }

  void _moveVertices(
    Map<String, Object?> node,
    List<int> indices,
    double dx,
    double dy,
  ) {
    // 顶点编辑需要落在网格上；若为空则先自动生成一份。
    if (asJsonList(_mesh(node)['vertices']).isEmpty) {
      _autoGenerateMesh(node, rows: 4, cols: 4);
    }
    final mesh = _mesh(node);
    final vertices = asJsonList(mesh['vertices']).toList();
    for (final index in indices) {
      if (index < 0 || index >= vertices.length) continue;
      final vertex = asJsonList(vertices[index]);
      if (vertex.length < 2) continue;
      vertices[index] = <Object?>[
        asDouble(vertex[0]) + dx,
        asDouble(vertex[1]) + dy,
      ];
    }
    mesh['vertices'] = vertices;
  }

  void _addVertices(Map<String, Object?> node, List<Object?> added) {
    final mesh = _mesh(node);
    final vertices = asJsonList(mesh['vertices']).toList();
    final uvs = asJsonList(mesh['uvs']).toList();
    for (final item in added) {
      final vertex = asJsonList(item);
      vertices.add(<Object?>[asDouble(vertex[0]), asDouble(vertex[1])]);
      uvs.add(<Object?>[
        vertex.length > 2 ? asDouble(vertex[2]) : 0.5,
        vertex.length > 3 ? asDouble(vertex[3]) : 0.5,
      ]);
    }
    mesh['vertices'] = vertices;
    mesh['uvs'] = uvs;
  }

  void _removeVertices(Map<String, Object?> node, List<int> indices) {
    final mesh = _mesh(node);
    final vertices = asJsonList(mesh['vertices']);
    final uvs = asJsonList(mesh['uvs']);
    final indicesRaw = asJsonList(mesh['indices']);
    final removed = indices.toSet();
    final remap = <int, int>{};
    final newVertices = <Object?>[];
    final newUvs = <Object?>[];
    for (var i = 0; i < vertices.length; i++) {
      if (removed.contains(i)) continue;
      remap[i] = newVertices.length;
      newVertices.add(vertices[i]);
      if (i < uvs.length) newUvs.add(uvs[i]);
    }
    final newIndices = <Object?>[];
    for (var t = 0; t + 2 < indicesRaw.length; t += 3) {
      final a = asInt(indicesRaw[t]);
      final b = asInt(indicesRaw[t + 1]);
      final c = asInt(indicesRaw[t + 2]);
      if (removed.contains(a) || removed.contains(b) || removed.contains(c)) {
        continue;
      }
      newIndices.addAll(<Object?>[remap[a], remap[b], remap[c]]);
    }
    mesh['vertices'] = newVertices;
    mesh['uvs'] = newUvs;
    mesh['indices'] = newIndices;
  }

  void _splitTriangle(Map<String, Object?> node, int triangle, double t) {
    final mesh = _mesh(node);
    final vertices = asJsonList(mesh['vertices']).toList();
    final uvs = asJsonList(mesh['uvs']).toList();
    final indicesRaw = asJsonList(mesh['indices']).toList();
    final base = triangle * 3;
    if (base < 0 || base + 2 >= indicesRaw.length) {
      throw const AmException('BAD_COMMAND', 'triangle index out of range');
    }
    // 在最长边上插入一点，把三角形一分为二。
    final a = asInt(indicesRaw[base]);
    final b = asInt(indicesRaw[base + 1]);
    final c = asInt(indicesRaw[base + 2]);
    final pa = asJsonList(vertices[a]);
    final pb = asJsonList(vertices[b]);
    final pc = asJsonList(vertices[c]);
    double len(List<Object?> p, List<Object?> q) {
      final dx = asDouble(p[0]) - asDouble(q[0]);
      final dy = asDouble(p[1]) - asDouble(q[1]);
      return dx * dx + dy * dy;
    }

    final pairs = <List<int>>[
      <int>[a, b],
      <int>[b, c],
      <int>[c, a],
    ];
    pairs.sort(
      (x, y) => len(
        asJsonList(vertices[x[0]]),
        asJsonList(vertices[x[1]]),
      ).compareTo(len(asJsonList(vertices[y[0]]), asJsonList(vertices[y[1]]))),
    );
    final edge = pairs.last;
    final p = edge[0];
    final q = edge[1];
    final opposite = <int>[
      a,
      b,
      c,
    ].firstWhere((v) => v != p && v != q, orElse: () => c);
    final pp = asJsonList(vertices[p]);
    final pq = asJsonList(vertices[q]);
    final newVertex = <Object?>[
      asDouble(pp[0]) + (asDouble(pq[0]) - asDouble(pp[0])) * t,
      asDouble(pp[1]) + (asDouble(pq[1]) - asDouble(pp[1])) * t,
    ];
    vertices.add(newVertex);
    final newIndex = vertices.length - 1;
    if (uvs.length > math.max(p, q)) {
      final up = asJsonList(uvs[p]);
      final uq = asJsonList(uvs[q]);
      uvs.add(<Object?>[
        asDouble(up[0]) + (asDouble(uq[0]) - asDouble(up[0])) * t,
        asDouble(up[1]) + (asDouble(uq[1]) - asDouble(up[1])) * t,
      ]);
    }
    final ordered = <List<int>>[
      <int>[opposite, p, newIndex],
      <int>[opposite, newIndex, q],
    ];
    final orientation = _triangleOrientation(pa, pb, pc);
    indicesRaw.removeRange(base, base + 3);
    for (final tri in ordered) {
      final flat = orientation >= 0
          ? <Object?>[tri[0], tri[1], tri[2]]
          : <Object?>[tri[0], tri[2], tri[1]];
      indicesRaw.insertAll(base, flat);
    }
    mesh['vertices'] = vertices;
    mesh['uvs'] = uvs;
    mesh['indices'] = indicesRaw;
  }

  double _triangleOrientation(
    List<Object?> a,
    List<Object?> b,
    List<Object?> c,
  ) {
    return (asDouble(b[0]) - asDouble(a[0])) *
            (asDouble(c[1]) - asDouble(a[1])) -
        (asDouble(b[1]) - asDouble(a[1])) * (asDouble(c[0]) - asDouble(a[0]));
  }

  // -------------------------------------------------------------------------
  // 变形器
  // -------------------------------------------------------------------------

  String _createWarp({
    required String name,
    required int rows,
    required int cols,
    required List<Object?> bounds,
    String? parent,
  }) {
    final id = newAnimaId();
    final x = bounds.length >= 4 ? asDouble(bounds[0]) : -100.0;
    final y = bounds.length >= 4 ? asDouble(bounds[1]) : -100.0;
    final w = bounds.length >= 4 ? asDouble(bounds[2]) : 200.0;
    final h = bounds.length >= 4 ? asDouble(bounds[3]) : 200.0;
    final points = <Object?>[];
    for (var r = 0; r <= rows; r++) {
      for (var c = 0; c <= cols; c++) {
        points.add(<Object?>[x + w * c / cols, y + h * r / rows]);
      }
    }
    nodes[id] = <String, Object?>{
      'id': id,
      'name': name,
      'type': AmNodeKind.warpDeformer.wire,
      'parent': parent ?? rootId,
      'children': <Object?>[],
      'visible': true,
      'locked': false,
      'rows': rows,
      'cols': cols,
      'bounds': <Object?>[x, y, w, h],
      'control_points': points,
    };
    final target = _map(nodes[parent ?? rootId]);
    final children = asJsonList(target['children']).toList()..add(id);
    target['children'] = children;
    nodes[parent ?? rootId!] = target;
    return id;
  }

  String _createRotation({
    required String name,
    required List<Object?> position,
    String? parent,
  }) {
    final id = newAnimaId();
    nodes[id] = <String, Object?>{
      'id': id,
      'name': name,
      'type': AmNodeKind.rotationDeformer.wire,
      'parent': parent ?? rootId,
      'children': <Object?>[],
      'visible': true,
      'locked': false,
      'position': <Object?>[
        position.isNotEmpty ? asDouble(position[0]) : 0.0,
        position.length > 1 ? asDouble(position[1]) : 0.0,
      ],
      'angle': 0.0,
      'scale': <Object?>[1.0, 1.0],
    };
    final target = _map(nodes[parent ?? rootId]);
    final children = asJsonList(target['children']).toList()..add(id);
    target['children'] = children;
    nodes[parent ?? rootId!] = target;
    return id;
  }

  void _moveControlPoint(
    Map<String, Object?> node,
    int index,
    double dx,
    double dy,
  ) {
    final points = asJsonList(node['control_points']).toList();
    if (index < 0 || index >= points.length) {
      throw const AmException('BAD_COMMAND', 'control point out of range');
    }
    final point = asJsonList(points[index]);
    points[index] = <Object?>[asDouble(point[0]) + dx, asDouble(point[1]) + dy];
    node['control_points'] = points;
  }

  // -------------------------------------------------------------------------
  // 参数 / 关键形
  // -------------------------------------------------------------------------

  String _createParameter(Map<String, Object?> c) {
    final id = '${c['id'] ?? newAnimaId()}';
    parameters[id] = <String, Object?>{
      'id': id,
      'name': '${c['name'] ?? _nextName('param')}',
      'group': '${c['group'] ?? 'ParamGroup'}',
      'min': asDouble(c['min'], -1),
      'max': asDouble(c['max'], 1),
      'default': asDouble(c['default'], 0),
      'keys': asJsonList(c['keys']),
      'is_blend_shape': asBool(c['is_blend_shape']),
    };
    return id;
  }

  void _deleteParameter(String id) {
    parameters.remove(id);
    for (final entry in nodes.entries.toList()) {
      final node = _map(entry.value);
      final keyforms = _map(node['keyforms']);
      if (keyforms.remove(id) != null) {
        if (keyforms.isEmpty) {
          node.remove('keyforms');
        } else {
          node['keyforms'] = keyforms;
        }
        nodes[entry.key] = node;
      }
    }
    data['parameters'] = parameters;
  }

  /// 关键形存储形状（与 `spec/model.json` 对齐，UI 与本文件共用）：
  ///
  /// ```json
  /// "keyforms": {
  ///   "<param_id>": {
  ///     "blend_type": "normal|multiply|screen|add",
  ///     "keys": [
  ///       {"value": 10.0, "vertices": [[dx,dy],...],
  ///        "transform": {"position":[x,y],"angle":a,"scale":[sx,sy]},
  ///        "control_points": [[x,y],...], "opacity": 1.0}
  ///     ]
  ///   }
  /// }
  /// ```
  Object? _recordKeyform(Map<String, Object?> c) {
    final node = _node(c);
    final paramId = '${c['param'] ?? c['param_id'] ?? ''}';
    if (paramId.isEmpty) {
      throw const AmException('BAD_COMMAND', 'keyform.record needs param');
    }
    final value = asDouble(c['value']);
    final keyforms = _map(node['keyforms']);
    final perParam = _map(keyforms[paramId]);
    final mesh = _mesh(node);
    final offsets = <Object?>[];
    for (final vertex in asJsonList(mesh['vertices'])) {
      final v = asJsonList(vertex);
      offsets.add(<Object?>[
        v.isNotEmpty ? asDouble(v[0]) : 0.0,
        v.length > 1 ? asDouble(v[1]) : 0.0,
      ]);
    }
    // 顺带快照节点自身的可变属性，保证“打帧”能覆盖变换类节点。
    final record = <String, Object?>{
      'value': value,
      'vertices': offsets,
      'transform': <String, Object?>{
        'position': asJsonList(node['position']),
        'angle': asDouble(node['angle']),
        'scale': asJsonList(node['scale']).isEmpty
            ? <Object?>[1.0, 1.0]
            : asJsonList(node['scale']),
      },
      'control_points': asJsonList(node['control_points']),
      'opacity': asDouble(node['opacity'], 1),
    };
    final keys = asJsonList(perParam['keys']).toList();
    final existing = keys.indexWhere(
      (e) => asDouble(_map(e)['value']) == value,
    );
    if (existing >= 0) {
      keys[existing] = record;
    } else {
      keys.add(record);
      keys.sort(
        (a, b) =>
            asDouble(_map(a)['value']).compareTo(asDouble(_map(b)['value'])),
      );
    }
    perParam['keys'] = keys;
    perParam['blend_type'] = AmKeyformBlend.parse(perParam['blend_type']).wire;
    keyforms[paramId] = perParam;
    node['keyforms'] = keyforms;
    return <String, Object?>{'param': paramId, 'value': value};
  }

  /// 定位（或在缺失时补建）某个关键形帧。
  Map<String, Object?> _keyformKey(
    Map<String, Object?> c, {
    bool create = false,
  }) {
    final node = _node(c);
    final paramId = '${c['param'] ?? c['param_id'] ?? ''}';
    if (paramId.isEmpty) {
      throw const AmException('BAD_COMMAND', 'keyform command needs param');
    }
    final value = asDouble(c['value']);
    final keyforms = _map(node['keyforms']);
    var perParam = _map(keyforms[paramId]);
    if (perParam.isEmpty) {
      throw AmException('KEYFORM_NOT_FOUND', 'no keyform for $paramId');
    }
    final keys = asJsonList(perParam['keys']).toList();
    var index = keys.indexWhere((e) => asDouble(_map(e)['value']) == value);
    if (index < 0) {
      if (!create) {
        throw AmException('KEYFORM_NOT_FOUND', 'no keyform at $value');
      }
      keys.add(<String, Object?>{
        'value': value,
        'vertices': <Object?>[],
        'transform': <String, Object?>{},
        'control_points': <Object?>[],
        'opacity': asDouble(node['opacity'], 1),
      });
      keys.sort(
        (a, b) =>
            asDouble(_map(a)['value']).compareTo(asDouble(_map(b)['value'])),
      );
      perParam['keys'] = keys;
      keyforms[paramId] = perParam;
      node['keyforms'] = keyforms;
      perParam = _map(keyforms[paramId]);
      index = asJsonList(
        perParam['keys'],
      ).indexWhere((e) => asDouble(_map(e)['value']) == value);
    }
    final record = _map(asJsonList(perParam['keys'])[index]);
    asJsonList(perParam['keys']).toList()[index] = record;
    return record;
  }

  /// 把 [record] 写回其所属的关键形列表。
  void _storeKeyformKey(Map<String, Object?> c, Map<String, Object?> record) {
    final node = _node(c);
    final paramId = '${c['param'] ?? c['param_id'] ?? ''}';
    final value = asDouble(c['value']);
    final keyforms = _map(node['keyforms']);
    final perParam = _map(keyforms[paramId]);
    final keys = asJsonList(perParam['keys']).toList();
    final index = keys.indexWhere((e) => asDouble(_map(e)['value']) == value);
    if (index < 0) {
      throw AmException('KEYFORM_NOT_FOUND', 'no keyform at $value');
    }
    keys[index] = record;
    perParam['keys'] = keys;
    keyforms[paramId] = perParam;
    node['keyforms'] = keyforms;
  }

  void _setKeyformValue(Map<String, Object?> c) {
    final record = _keyformKey(c, create: true);
    final vertex = asInt(c['vertex'], -1);
    final vertices = asJsonList(record['vertices']).toList();
    if (vertex >= 0) {
      while (vertices.length <= vertex) {
        vertices.add(<Object?>[0.0, 0.0]);
      }
      vertices[vertex] = <Object?>[asDouble(c['dx']), asDouble(c['dy'])];
      record['vertices'] = vertices;
    } else if (c['vertices'] != null) {
      record['vertices'] = asJsonList(c['vertices']);
    }
    if (c['opacity'] != null) record['opacity'] = asDouble(c['opacity'], 1);
    final transform = _map(record['transform']);
    for (final field in <String>['position', 'angle', 'scale']) {
      if (c[field] != null) {
        transform[field] = field == 'angle'
            ? asDouble(c[field])
            : asJsonList(c[field]);
      }
    }
    if (transform.isNotEmpty) record['transform'] = transform;
    if (c['control_point'] != null && c['cp_index'] != null) {
      final cpIndex = asInt(c['cp_index']);
      final points = asJsonList(record['control_points']).toList();
      while (points.length <= cpIndex) {
        points.add(<Object?>[0.0, 0.0]);
      }
      points[cpIndex] = asJsonList(c['control_point']);
      record['control_points'] = points;
    }
    _storeKeyformKey(c, record);
  }

  void _deleteKeyform(Map<String, Object?> c) {
    final node = _node(c);
    final paramId = '${c['param'] ?? c['param_id'] ?? ''}';
    final keyforms = _map(node['keyforms']);
    final perParam = _map(keyforms[paramId]);
    if (perParam.isEmpty) return;
    if (c['value'] == null) {
      keyforms.remove(paramId);
    } else {
      final value = asDouble(c['value']);
      perParam['keys'] = asJsonList(
        perParam['keys'],
      ).where((e) => asDouble(_map(e)['value']) != value).toList();
      keyforms[paramId] = perParam;
    }
    node['keyforms'] = keyforms;
  }

  void _setKeyformBlend(Map<String, Object?> c) {
    final node = _node(c);
    final paramId = '${c['param'] ?? c['param_id'] ?? ''}';
    final keyforms = _map(node['keyforms']);
    final perParam = _map(keyforms[paramId]);
    if (perParam.isEmpty) {
      throw AmException('KEYFORM_NOT_FOUND', 'no keyform for $paramId');
    }
    perParam['blend_type'] = AmKeyformBlend.parse(c['value']).wire;
    keyforms[paramId] = perParam;
    node['keyforms'] = keyforms;
  }

  // -------------------------------------------------------------------------
  // 纹理
  // -------------------------------------------------------------------------

  void _setTexture(Map<String, Object?> c) {
    final node = _node(c);
    node['texture'] = c['texture'] ?? c['path'];
    if (c['uv'] != null) node['uv'] = asJsonList(c['uv']);
  }

  Object? _importPsd(Map<String, Object?> c) {
    final layers = asJsonList(c['layers']);
    final created = <Object?>[];
    for (final layer in layers) {
      final map = _map(layer);
      final id = _createNode(
        AmNodeKind.drawable,
        name: '${map['name'] ?? 'layer'}',
        parent: (map['parent'] ?? rootId) as String?,
      );
      final node = _map(nodes[id]);
      node['texture'] = map['texture'];
      node['visible'] = asBool(map['visible'], true);
      node['opacity'] = asDouble(map['opacity'], 1);
      node['uv'] = asJsonList(map['uv']).length == 4
          ? asJsonList(map['uv'])
          : <Object?>[0.0, 0.0, 1.0, 1.0];
      nodes[id] = node;
      created.add(id);
    }
    return <String, Object?>{'created': created};
  }

  void _repackTextures(Map<String, Object?> c) {
    final atlases = asJsonList(c['atlas']);
    if (atlases.isNotEmpty) data['atlas'] = atlases;
  }

  // -------------------------------------------------------------------------
  // 物理 / 动作 / 表情 / 姿势
  // -------------------------------------------------------------------------

  Object? _addPhysics(Map<String, Object?> c) {
    final item = <String, Object?>{
      'id': '${c['id'] ?? newAnimaId()}',
      'name': '${c['name'] ?? 'physics'}',
      'inputs': asJsonList(c['inputs']),
      'outputs': asJsonList(c['outputs']),
      'pendulum': _map(c['pendulum']),
      'vertex': _map(c['vertex']),
      'enabled': asBool(c['enabled'], true),
    };
    data['physics'] = <Object?>[...physics, item];
    return item['id'];
  }

  void _setPhysicsProperty(Map<String, Object?> c) {
    final id = '${c['id'] ?? ''}';
    final list = physics.toList();
    final index = list.indexWhere((e) => _map(e)['id'] == id);
    if (index < 0) {
      throw AmException('PHYSICS_NOT_FOUND', 'physics $id not found');
    }
    final item = _map(list[index]);
    final path = '${c['path'] ?? ''}';
    final value = c['value'];
    if (path.isEmpty) {
      item.addAll(_map(value));
    } else {
      item[path] = value;
    }
    list[index] = item;
    data['physics'] = list;
  }

  Object? _createMotion(Map<String, Object?> c) {
    final name = '${c['name'] ?? 'motion'}';
    final item = <String, Object?>{
      'name': name,
      'duration': asDouble(c['duration'], 3),
      'loop': asBool(c['loop']),
      'fade_in': asDouble(c['fade_in'], 0.3),
      'fade_out': asDouble(c['fade_out'], 0.3),
      'curves': <Object?>[],
    };
    data['motions'] = <Object?>[
      ...motions.where((e) => _map(e)['name'] != name),
      item,
    ];
    return name;
  }

  Map<String, Object?> _motion(Map<String, Object?> c) {
    final name = '${c['motion'] ?? c['name'] ?? ''}';
    final list = motions.toList();
    final index = list.indexWhere((e) => _map(e)['name'] == name);
    if (index < 0) {
      throw AmException('MOTION_NOT_FOUND', 'motion $name not found');
    }
    final item = _map(list[index]);
    list[index] = item;
    data['motions'] = list;
    return item;
  }

  Map<String, Object?> _curve(Map<String, Object?> motion, String param) {
    final curves = asJsonList(motion['curves']).toList();
    var index = curves.indexWhere((e) => '${_map(e)['param']}' == param);
    if (index < 0) {
      curves.add(<String, Object?>{'param': param, 'keys': <Object?>[]});
      index = curves.length - 1;
    }
    final curve = _map(curves[index]);
    curves[index] = curve;
    motion['curves'] = curves;
    return curve;
  }

  void _setMotionKey(Map<String, Object?> c) {
    final motion = _motion(c);
    final curve = _curve(motion, '${c['param'] ?? ''}');
    final time = asDouble(c['time']);
    final keys = asJsonList(curve['keys']).toList();
    final record = <String, Object?>{
      'time': time,
      'value': asDouble(c['value']),
      'interp': AmInterpolation.parse(c['interp'] ?? c['interpolation']).wire,
      'in_tangent': asDouble(c['in_tangent']),
      'out_tangent': asDouble(c['out_tangent']),
    };
    final existing = keys.indexWhere((e) => asDouble(_map(e)['time']) == time);
    if (existing >= 0) {
      keys[existing] = record;
    } else {
      keys.add(record);
    }
    keys.sort(
      (a, b) => asDouble(_map(a)['time']).compareTo(asDouble(_map(b)['time'])),
    );
    curve['keys'] = keys;
  }

  void _removeMotionKey(Map<String, Object?> c) {
    final motion = _motion(c);
    final curve = _curve(motion, '${c['param'] ?? ''}');
    final time = asDouble(c['time']);
    curve['keys'] = asJsonList(
      curve['keys'],
    ).where((e) => asDouble(_map(e)['time']) != time).toList();
  }

  void _setMotionCurve(Map<String, Object?> c) {
    final motion = _motion(c);
    final curve = _curve(motion, '${c['param'] ?? ''}');
    final key = asInt(c['key'], -1);
    final keys = asJsonList(curve['keys']).toList();
    if (key < 0 || key >= keys.length) {
      throw const AmException('BAD_COMMAND', 'key index out of range');
    }
    final record = _map(keys[key]);
    if (c['interp'] != null) {
      record['interp'] = AmInterpolation.parse(c['interp']).wire;
    }
    if (c['in_tangent'] != null) {
      record['in_tangent'] = asDouble(c['in_tangent']);
    }
    if (c['out_tangent'] != null) {
      record['out_tangent'] = asDouble(c['out_tangent']);
    }
    if (c['value'] != null) record['value'] = asDouble(c['value']);
    keys[key] = record;
    curve['keys'] = keys;
  }

  void _setMotionMeta(Map<String, Object?> c) {
    final motion = _motion(c);
    for (final field in <String>['duration', 'loop', 'fade_in', 'fade_out']) {
      if (c[field] != null) {
        motion[field] = field == 'loop' ? asBool(c[field]) : asDouble(c[field]);
      }
    }
  }

  Object? _createExpression(Map<String, Object?> c) {
    final name = '${c['name'] ?? 'expression'}';
    final item = <String, Object?>{
      'name': name,
      'params': _map(c['params']),
      'fade_in': asDouble(c['fade_in'], 0.5),
    };
    data['expressions'] = <Object?>[
      ...expressions.where((e) => _map(e)['name'] != name),
      item,
    ];
    return name;
  }

  void _setExpressionParam(Map<String, Object?> c) {
    final name = '${c['name'] ?? c['expression'] ?? ''}';
    final list = expressions.toList();
    final index = list.indexWhere((e) => _map(e)['name'] == name);
    if (index < 0) {
      throw AmException('EXPRESSION_NOT_FOUND', 'expression $name not found');
    }
    final item = _map(list[index]);
    final params = _map(item['params']);
    final paramId = '${c['param'] ?? ''}';
    if (c['value'] == null) {
      params.remove(paramId);
    } else {
      params[paramId] = asDouble(c['value']);
    }
    item['params'] = params;
    if (c['fade_in'] != null) item['fade_in'] = asDouble(c['fade_in']);
    list[index] = item;
    data['expressions'] = list;
  }

  Object? _addPose(Map<String, Object?> c) {
    final id = '${c['id'] ?? newAnimaId()}';
    final item = <String, Object?>{
      'id': id,
      'name': '${c['name'] ?? 'pose'}',
      'group': '${c['group'] ?? 'pose_group'}',
      'parts': asJsonList(c['parts']),
    };
    data['pose'] = <Object?>[...pose, item];
    return id;
  }
}

/// 默认空工程文档（结构与 `spec/model.json` 对齐）。
Map<String, Object?> defaultAnimaDocument() {
  final rootId = newAnimaId();
  return <String, Object?>{
    'root': rootId,
    'nodes': <String, Object?>{
      rootId: <String, Object?>{
        'id': rootId,
        'name': 'root',
        'type': AmNodeKind.part.wire,
        'parent': null,
        'children': <Object?>[],
        'visible': true,
        'locked': false,
      },
    },
    'art_path': <Object?>[],
    'parameters': <String, Object?>{},
    'physics': <Object?>[],
    'motions': <Object?>[],
    'expressions': <Object?>[],
    'pose': <Object?>[],
    'atlas': <Object?>[],
    'config': <String, Object?>{
      'canvas': <String, Object?>{'width': 1280, 'height': 720, 'unit': 'px'},
      'default_language': 'zh-CN',
      'render_quality': 'high',
      'device_pixel_ratio': 1.0,
    },
    'settings': <String, Object?>{
      'default_motion': null,
      'default_expression': null,
      'physics_enabled': true,
      'blink': <String, Object?>{'enabled': true, 'interval': 4.0},
      'breath': <String, Object?>{'enabled': true, 'period': 3.5},
      'lipsync': <String, Object?>{'enabled': false, 'gain': 1.0},
      'param_groups': <Object?>[],
    },
  };
}

/// 演示文档：给“空状态示例工程”与首启体验用（不写盘）。
Map<String, Object?> demoAnimaDocument() {
  final document = LocalDocument();
  final rootId = document.rootId!;

  final paramAngleX = document._createParameter(<String, Object?>{
    'name': 'AngleX',
    'group': 'Head',
    'min': -30,
    'max': 30,
    'default': 0,
  });
  final paramAngleY = document._createParameter(<String, Object?>{
    'name': 'AngleY',
    'group': 'Head',
    'min': -30,
    'max': 30,
    'default': 0,
  });
  final eyeOpen = document._createParameter(<String, Object?>{
    'name': 'EyeOpen',
    'group': 'Eyes',
    'min': 0,
    'max': 1,
    'default': 1,
  });
  final mouthOpen = document._createParameter(<String, Object?>{
    'name': 'MouthOpen',
    'group': 'Mouth',
    'min': 0,
    'max': 1,
    'default': 0,
  });

  final body = document._createNode(
    AmNodeKind.part,
    name: 'Body',
    parent: rootId,
  );
  final head = document._createNode(
    AmNodeKind.part,
    name: 'Head',
    parent: body,
  );
  final rotation = document._createRotation(
    name: 'HeadRotation',
    parent: head,
    position: const <Object?>[0.0, 120.0],
  );
  final face = document._createNode(
    AmNodeKind.drawable,
    name: 'Face',
    parent: rotation,
  );
  final faceNode = _map(document.nodes[face]);
  faceNode['bounds'] = <String, Object?>{
    'x': -80.0,
    'y': -60.0,
    'width': 160.0,
    'height': 160.0,
  };
  faceNode['uv'] = <Object?>[0.0, 0.0, 1.0, 1.0];
  document.nodes[face] = faceNode;
  document._autoGenerateMesh(faceNode, rows: 4, cols: 4);
  document.nodes[face] = faceNode;

  final torso = document._createNode(
    AmNodeKind.drawable,
    name: 'Torso',
    parent: body,
  );
  final torsoNode = _map(document.nodes[torso]);
  torsoNode['bounds'] = <String, Object?>{
    'x': -70.0,
    'y': -220.0,
    'width': 140.0,
    'height': 200.0,
  };
  document.nodes[torso] = torsoNode;
  document._autoGenerateMesh(torsoNode, rows: 4, cols: 3);
  document.nodes[torso] = torsoNode;

  document._recordKeyform(<String, Object?>{
    'id': rotation,
    'param': paramAngleX,
    'value': -30,
  });
  document._recordKeyform(<String, Object?>{
    'id': rotation,
    'param': paramAngleX,
    'value': 30,
  });
  document._recordKeyform(<String, Object?>{
    'id': rotation,
    'param': paramAngleY,
    'value': -30,
  });
  document._recordKeyform(<String, Object?>{
    'id': rotation,
    'param': paramAngleY,
    'value': 30,
  });
  // 旋转轴随角度左右摆，Y 角度则抬/低头（用位置偏移表现）。
  document._setKeyformValue(<String, Object?>{
    'id': rotation,
    'param': paramAngleX,
    'value': -30,
    'angle': -0.25,
  });
  document._setKeyformValue(<String, Object?>{
    'id': rotation,
    'param': paramAngleX,
    'value': 30,
    'angle': 0.25,
  });
  document._setKeyformValue(<String, Object?>{
    'id': rotation,
    'param': paramAngleY,
    'value': -30,
    'position': <Object?>[0.0, 140.0],
  });
  document._setKeyformValue(<String, Object?>{
    'id': rotation,
    'param': paramAngleY,
    'value': 30,
    'position': <Object?>[0.0, 100.0],
  });

  document._createMotion(<String, Object?>{
    'name': 'Idle',
    'duration': 4,
    'loop': true,
  });
  final idle = document._motion(<String, Object?>{'name': 'Idle'});
  final curve = document._curve(idle, paramAngleX);
  curve['keys'] = <Object?>[
    <String, Object?>{
      'time': 0.0,
      'value': 0.0,
      'interp': 'bezier',
      'in_tangent': 0.0,
      'out_tangent': 0.0,
    },
    <String, Object?>{
      'time': 2.0,
      'value': 20.0,
      'interp': 'bezier',
      'in_tangent': 0.0,
      'out_tangent': 0.0,
    },
    <String, Object?>{
      'time': 4.0,
      'value': 0.0,
      'interp': 'bezier',
      'in_tangent': 0.0,
      'out_tangent': 0.0,
    },
  ];

  document._createExpression(<String, Object?>{
    'name': 'Smile',
    'params': <String, Object?>{eyeOpen: 0.6, mouthOpen: 0.4},
  });

  document.applyDrawOrder();
  return document.data;
}
