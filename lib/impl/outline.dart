library atom.outline;

import 'dart:async';
import 'dart:html' as html;

import 'package:atom/atom.dart';
import 'package:atom/node/fs.dart';
import 'package:atom/node/workspace.dart';
import 'package:atom/utils/disposable.dart';
import 'package:logging/logging.dart';

import 'package:analysis_server_lib/analysis_server_lib.dart' as analysis;
import '../analysis/quick_fixes.dart';
import '../analysis_server.dart';
import '../elements.dart';
import '../linter.dart';
import '../projects.dart';
import '../state.dart';
import '../views.dart';

final String _keyPath = '${pluginId}.showOutlineView';

final Logger _logger = new Logger('atom.outline');

class OutlineController extends DockedViewManager<OutlineView> {
  static const outlineURI = 'atom://dartlang/outline';

  Map<String, AnalysisOutline> lastOutlines = {};
  List<analysis.AnalysisError> lastErrors;

  OutlineController() : super(outlineURI) {
    subs.add(analysisServer.onOutline.listen(_handleOutline));
    subs.add(onProcessedErrorsChanged.listen(_handleErrorsChanged));

    disposables.add(
      atom.commands.add('atom-workspace', '${pluginId}:toggle-outline-view', (_) {
        showView();
      })
    );

    disposables.add(atom.config.observe(_keyPath, null, (val) {
      showView();
    }));

    disposables.add(atom.workspace.observeActiveTextEditor((activeEditor) {
      // Do memory cleanup on editor swap, easier than tracking each editor
      // close.
      Set<String> paths =
          new Set.from(atom.workspace.getTextEditors().map((e) => e.getPath()));
      lastOutlines = new Map.fromIterable(
          lastOutlines.keys.where((k) => paths.contains(k)),
          value: (k) => lastOutlines[k]);
    }));

    if (state[_keyPath] == true) {
      showView();
    }
  }

  void _handleOutline(AnalysisOutline data) {
    lastOutlines[data.file] = data;
    if (singleton != null) singleton._handleOutline(data);
  }

  void _handleErrorsChanged(List<analysis.AnalysisError> errors) {
    lastErrors = errors;
    if (singleton != null) singleton._handleErrorsChanged(errors);
  }

  OutlineView instantiateView(String id, [dynamic data]) =>
      new OutlineView(this);
}

class OutlineView extends DockedView implements Disposable {
  final OutlineController controller;

  CoreElement fileType;
  CoreElement title;
  ListTreeBuilder treeBuilder;
  CoreElement errorArea;
  _ErrorsList errorsList;

  StreamSubscriptions subs = new StreamSubscriptions();
  Disposables disposables = new Disposables();

  List<Outline> _topLevel = [];

  TextEditor editor;
  String get path => editor?.getPath();

  String get label => 'Outline';
  String get defaultLocation => 'left';

  OutlineView(this.controller) : super('outline', div(c: 'outline-view source')) {

    disposables.add(atom.workspace.observeActiveTextEditor((activeEditor) {
      editor = activeEditor.obj == null || !isDartFile(activeEditor.getPath())
          ? null : activeEditor;
      subs.cancel();
      if (editor != null) {
        subs.add(editor.onDidChangeCursorPosition.listen(_cursorChanged));
      }
      _handleOutline(controller.lastOutlines[path]);
    }));

    content..add([
      div(c: 'title-container')..add([
        div(c: 'title-text')..add([
          fileType = span(c: 'keyword'),
          title = span()
        ])
      ]),
      treeBuilder = new ListTreeBuilder(_render, hasToggle: false)
        ..toggleClass('outline-tree')
        ..toggleClass('selection'),
      errorArea = div(c: 'outline-errors')..hidden(true)..add([
        errorsList = new _ErrorsList(this)
      ])
    ]);

    treeBuilder.onClickNode.listen(_jumpTo);
    treeBuilder.setSelectionClass('region');

    // Ask the manager for the last data.
    _handleOutline(null);
    _handleErrorsChanged(controller.lastErrors);
  }

  void dispose() {
    subs.cancel();
    disposables.dispose();
  }

  void _handleOutline(AnalysisOutline data) {
    if (treeBuilder == null) return;
    treeBuilder.clear();
    _topLevel.clear();
    fileType.text = '';
    title.text = 'no outline';
    if (data == null || data.file != path || editor == null) return;

    // Update the title.
    if (data.libraryName == null) {
      fileType.text = '';
      title.text = fs.basename(path);
    } else if (data.kind == 'PART') {
      fileType.text = 'part of ';
      title.text = data.libraryName;
    } else {
      fileType.text = 'library ';
      title.text = data.libraryName;
    }

    if (data.outline == null) {
      treeBuilder.add(div(text: 'outline not available', c: 'comment'));
    } else {
      List<Outline> nodes = data.outline.children ?? <Outline>[];
      for (Outline node in nodes) {
        _topLevel.add(node);
        treeBuilder.addNode(_toNode(node));
      }
    }

    _cursorChanged(editor.getCursorBufferPosition());
  }

  void _handleErrorsChanged(List<analysis.AnalysisError> errors) {
    if (errors == null) errors = (deps[DartLinterConsumer] as DartLinterConsumer)?.errors;
    if (errors == null || errorsList == null) return;
    errorsList.updateWith(errors);
    errorArea.hidden(!errorsList.hasErrors);
  }

  void _cursorChanged(Point pos) {
    if (pos == null || editor == null || treeBuilder == null) return;

    int offset = editor.getBuffer().characterIndexForPosition(pos);
    List<Node> selected = [];

    for (Node node in treeBuilder.nodes) {
      _collectSelected(node, offset, selected);
    }

    treeBuilder.selectNodes(selected.isEmpty ? selected : [selected.last]);
    treeBuilder.scrollToSelection();
  }

  void _collectSelected(Node node, int offset, List<Node> selected) {
    Outline o = node.data;

    if (offset >= o.offset && offset < o.offset + o.length) {
      selected.add(node);

      if (node.children != null) {
        for (Node child in node.children) {
          _collectSelected(child, offset, selected);
        }
      }
    }
  }

  Node _toNode(Outline outline) {
    Node n = new Node(outline, canHaveChildren: outline.children != null);
    if (outline.children != null) {
      if (outline.element.kind == 'ENUM') outline.children.clear();

      for (Outline child in outline.children) {
        n.add(_toNode(child));
      }
    }
    return n;
  }

  void _render(Outline item, html.Element intoElement) {
    analysis.Element e = item.element;

    // static class members
    bool isStatic = false;
    if (((e.flags & 0x08) != 0) && !_topLevel.contains(item)) {
      isStatic = true;
    }

    if (e.kind == 'CLASS') {
      intoElement.children.add(new html.SpanElement()
          ..classes.add('syntax--keyword')
          ..text = 'class ');
    } else if (e.kind == 'ENUM') {
      intoElement.children.add(new html.SpanElement()
          ..classes.add('syntax--keyword')
          ..text = 'enum ');
    } else if (e.kind == 'FUNCTION_TYPE_ALIAS') {
      intoElement.children.add(new html.SpanElement()
          ..classes.add('syntax--keyword')
          ..text = 'typedef ');
    }

    if (e.kind == 'GETTER') {
      intoElement.children.add(new html.SpanElement()
          ..classes.add('syntax--comment')
          ..text = 'get ');
    } else if (e.kind == 'SETTER') {
      intoElement.children.add(new html.SpanElement()
          ..classes.add('syntax--comment')
          ..text = 'set ');
    }

    html.Element span = new html.AnchorElement();
    if ((e.flags & 0x20) != 0) span.classes.add('outline-deprecated');
    if (isStatic) span.classes.add('outline-static');
    intoElement.children.add(span);

    String name = e.name;

    if (e.kind == 'CLASS') span.classes.addAll(['syntax--support', 'syntax--class']);
    if (e.kind == 'CONSTRUCTOR') span.classes.addAll(['syntax--support', 'syntax--class']);
    if (e.kind == 'FUNCTION' || e.kind == 'METHOD' || e.kind == 'GETTER' ||
        e.kind == 'SETTER') {
      span.classes.addAll(['syntax--entity', 'syntax--name', 'syntax--function']);
    }

    if (e.parameters != null && e.kind != 'GETTER') {
      String str = e.parameters.length > 2 ? '(…)' : '()';
      // intoElement.children.add(
      //     new html.SpanElement()../*classes.add('muted')..*/text = str);
      name += str;
    }

    span.text = name;

    if (e.typeParameters != null) {
      intoElement.children.add(
          new html.SpanElement()..classes.add('syntax--comment')..text = e.typeParameters);
      //name += e.typeParameters;
    }

    if (e.returnType != null && e.returnType.isNotEmpty) {
      String type = e.returnType;
      int index = type.indexOf('<');
      if (index != -1) type = '${type.substring(0, index)}<…>';
      intoElement.children.add(
          new html.SpanElement()..classes.add('syntax--comment')..text = ' → ${type}');
    }
  }

  void _jumpTo(Node node) => _jumpToLocation(node.data.element.location);

  void _jumpToLocation(analysis.Location location) {
    if (editor == null) return;
    Range range = new Range.fromPoints(
      new Point.coords(location.startLine - 1, location.startColumn - 1),
      new Point.coords(location.startLine - 1, location.startColumn - 1 + location.length)
    );
    editor.setSelectedBufferRange(range);
  }
}

class _ErrorsList extends CoreElement {
  final OutlineView view;

  String get path => view.path;

  _ErrorsList(OutlineView inView) :
    view = inView,
    super('div', classes: 'errors-list');

  bool get hasErrors => element.children.isNotEmpty;

  void updateWith(List<analysis.AnalysisError> errors) {
    clear();

    for (analysis.AnalysisError error in errors) {
      if (path != error.location.file) continue;

      List row = [];

      row
        ..add(span(
          text: error.severity.toLowerCase(),
          c: 'item-${error.severity.toLowerCase()}'
        ))
        ..add(span(text: '${error.message}', c: 'item-text comment'));

      if (error.hasFix) {
        row.add(span(c: 'item-icon icon-tools quick-fix')
          ..click(() => _quickFix(error)));
      }

      add(div(c: 'outline-error-item')
        ..add(row)
        ..click(() => view._jumpToLocation(error.location)));
    }
  }

  void _quickFix(analysis.AnalysisError error) {
    _jumpTo(error.location).then((TextEditor editor) {
      // Show the quick fix menu.
      QuickFixHelper helper = deps[QuickFixHelper];
      helper.displayQuickFixes(editor);

      // Show a toast with the keybinding (one time).
      if (state['_quickFixBindings'] != true) {
        atom.notifications.addInfo(
          'Show quick fixes using `ctrl-1` or `alt-enter`.');
        state['_quickFixBindings'] = true;
      }
    });
  }

  Future<TextEditor> _jumpTo(analysis.Location location) {
    Map options = {
      'initialLine': location.startLine,
      'initialColumn': location.startColumn,
      'searchAllPanes': true
    };

    // If we're editing the target file, then use the current editor.
    var ed = atom.workspace.getActiveTextEditor();
    if (ed != null && ed.getPath() == location.file) {
      options['searchAllPanes'] = false;
    }

    return atom.workspace.openPending(location.file, options: options).then(
        (TextEditor editor) {
      // Select offset to length.
      TextBuffer buffer = editor.getBuffer();
      editor.setSelectedBufferRange(new Range.fromPoints(
        buffer.positionForCharacterIndex(location.offset),
        buffer.positionForCharacterIndex(location.offset + location.length)
      ));
      return editor;
    });
  }
}
