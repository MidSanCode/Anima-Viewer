/// 手工工具：生成一个引擎兼容的最小 amproj 测试工程（temp/amproj-demo）。
///
/// model.json 用引擎 spec 形状（§5.2）：nodes 是数组、字段 `kind`。
/// 运行：`dart run tool/make_demo_project.dart`
library;

import 'dart:io';

import 'package:anima_viewer/core/project/amproj_writer.dart';

Future<void> main() async {
  final dir = r'F:\exeliang\Anima\temp\amproj-demo';
  final info = AmprojWriter.freshInfo(
    name: 'amproj-demo',
    displayName: 'AMPROJ Demo',
  );
  await AmprojWriter.createDirectory(dir, info: info);

  const rootId = 'node-root';
  const texId = 'tex-0';
  const bodyId = 'node-body';

  await AmprojWriter.writeSpecFile(
    dir,
    'spec/model.json',
    AmprojWriter.encodeJson(<String, Object?>{
      'version': 1,
      'id': 'model-amproj-demo',
      'name': 'amproj-demo',
      'canvas': <String, Object?>{
        'width': 1024.0,
        'height': 1024.0,
        'origin': <String, Object?>{'x': 0.0, 'y': 0.0},
        'pixels_per_unit': 1.0,
      },
      'textures': <Object?>[
        <String, Object?>{
          'id': texId,
          'asset': 'assets/images/body.png',
          'width': 256,
          'height': 256,
          'atlas': false,
        },
      ],
      'nodes': <Object?>[
        <String, Object?>{
          'id': rootId,
          'name': 'Root',
          'parent': null,
          'visible': true,
          'locked': false,
          'draw_order': 0,
          'kind': 'part',
          'drawable': null,
          'warp': null,
          'rotation': null,
          'keyforms': <String, Object?>{},
        },
        <String, Object?>{
          'id': bodyId,
          'name': 'Body',
          'parent': rootId,
          'visible': true,
          'locked': false,
          'draw_order': 1,
          'kind': 'drawable',
          'drawable': <String, Object?>{
            'texture': 0,
            'uv_rect': null,
            'mesh': <String, Object?>{
              'vertices': <Object?>[
                <String, Object?>{'x': -128.0, 'y': -128.0},
                <String, Object?>{'x': 128.0, 'y': -128.0},
                <String, Object?>{'x': 128.0, 'y': 128.0},
                <String, Object?>{'x': -128.0, 'y': 128.0},
              ],
              'uvs': <Object?>[
                <String, Object?>{'x': 0.0, 'y': 0.0},
                <String, Object?>{'x': 1.0, 'y': 0.0},
                <String, Object?>{'x': 1.0, 'y': 1.0},
                <String, Object?>{'x': 0.0, 'y': 1.0},
              ],
              'indices': <Object?>[0, 1, 2, 0, 2, 3],
            },
            'opacity': 1.0,
            'blend': 'normal',
            'masks': <Object?>[],
            'inverted_mask': false,
            'culling': false,
          },
          'warp': null,
          'rotation': null,
          'keyforms': <String, Object?>{},
        },
      ],
      'parameters': <Object?>[
        <String, Object?>{
          'id': 'AngleX',
          'name': 'Angle X',
          'group': null,
          'min': -30.0,
          'max': 30.0,
          'default': 0.0,
          'keys': <Object?>[-30.0, 0.0, 30.0],
          'is_blend_shape': false,
          'repeat': false,
          'auto': false,
          'weight': 1.0,
          'comment': null,
        },
      ],
      'parameter_groups': <Object?>[],
    }),
  );
  await AmprojWriter.writeSpecFile(
    dir,
    'spec/model.settings.json',
    AmprojWriter.encodeJson(<String, Object?>{
      'display_name': 'AMPROJ Demo',
      'default_motion': null,
      'default_expression': null,
      'physics': true,
      'auto_blink': <String, Object?>{'enabled': true, 'interval': 4.0},
      'auto_breath': <String, Object?>{'enabled': true, 'period': 3.5},
      'lip_sync': <String, Object?>{'enabled': false, 'gain': 1.0},
      'parameter_defaults': <String, Object?>{'AngleX': 0.0},
    }),
  );
  await AmprojWriter.rebuildRegistry(dir);

  // 占位纹理（引擎加载 model.json 时不校验像素，但文件得在）。
  final imageDir = Directory(
    '$dir${Platform.pathSeparator}assets'
    '${Platform.pathSeparator}images',
  );
  await imageDir.create(recursive: true);
  // 1x1 PNG（最小合法文件）。
  const png = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x62,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ];
  File(
    '${imageDir.path}${Platform.pathSeparator}body.png',
  ).writeAsBytesSync(png);

  stdout.writeln('created $dir');
}
