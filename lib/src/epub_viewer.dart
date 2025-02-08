import 'dart:io';

import 'package:flutter_epub_viewer/src/epub_controller.dart';
import 'package:flutter_epub_viewer/src/helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_epub_viewer/src/utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

class EpubViewer extends StatefulWidget {
  const EpubViewer({
    super.key,
    required this.epubController,
    required this.epubSource,
    this.initialCfi,
    this.onChaptersLoaded,
    this.onEpubLoaded,
    this.onRelocated,
    this.onTextSelected,
    this.displaySettings,
    this.selectionContextMenu,
    this.onAnnotationClicked,
    this.onCenterClicked
  });

  ///Epub controller to manage epub
  final EpubController epubController;

  ///Epub source, accepts url, file or assets
  ///opf format is not tested, use with caution
  final EpubSource epubSource;

  ///Initial cfi string to  specify which part of epub to load initially
  ///if null, the first chapter will be loaded
  final String? initialCfi;

  ///Call back when epub is loaded and displayed
  final VoidCallback? onEpubLoaded;

  ///Call back when chapters are loaded
  final ValueChanged<List<EpubChapter>>? onChaptersLoaded;

  ///Call back when epub page changes
  final ValueChanged<EpubLocation>? onRelocated;

  ///Call back when text selection changes
  final ValueChanged<EpubTextSelection>? onTextSelected;

  ///initial display settings
  final EpubDisplaySettings? displaySettings;

  ///Callback for handling annotation click (Highlight and Underline)
  final ValueChanged<String>? onAnnotationClicked;

  ///context menu for text selection
  ///if null, the default context menu will be used
  final ContextMenu? selectionContextMenu;

  /// center 영역을 클릭해서 메뉴를 띄우는 역할을 함.
  final VoidCallback? onCenterClicked;

  @override
  State<EpubViewer> createState() => _EpubViewerState();
}

class _EpubViewerState extends State<EpubViewer> {
  final GlobalKey webViewKey = GlobalKey();

  // late PullToRefreshController pullToRefreshController;
  // late ContextMenu contextMenu;
  var selectedText = '';

  InAppWebViewController? webViewController;

  InAppWebViewSettings settings = InAppWebViewSettings(
      isInspectable: kDebugMode,
      javaScriptEnabled: true,
      mediaPlaybackRequiresUserGesture: false,
      transparentBackground: true,
      supportZoom: false,
      allowsInlineMediaPlayback: true,
      disableLongPressContextMenuOnLinks: false,
      iframeAllowFullscreen: true,
      allowsLinkPreview: false,
      verticalScrollBarEnabled: false,
      // disableVerticalScroll: true,
      selectionGranularity: SelectionGranularity.CHARACTER);

  @override
  void initState() {
    // widget.epubController.initServer();
    super.initState();
  }

  addJavaScriptHandlers() {
    webViewController?.addJavaScriptHandler(
        handlerName: "displayed",
        callback: (data) {
          widget.onEpubLoaded?.call();
        });

    webViewController?.addJavaScriptHandler(
        handlerName: "rendered",
        callback: (data) {
          // widget.onEpubLoaded?.call();
        });

    webViewController?.addJavaScriptHandler(
        handlerName: "chapters",
        callback: (data) async {
          final chapters = await widget.epubController.parseChapters();
          widget.onChaptersLoaded?.call(chapters);
        });

    ///selection handler
    webViewController?.addJavaScriptHandler(
        handlerName: "selection",
        callback: (data) {
          var cfiString = data[0];
          var selectedText = data[1];
          widget.onTextSelected?.call(EpubTextSelection(
              selectedText: selectedText, selectionCfi: cfiString));
        });

    ///search callback
    webViewController?.addJavaScriptHandler(
        handlerName: "search",
        callback: (data) async {
          var searchResult = data[0];
          widget.epubController.searchResultCompleter.complete(
              List<EpubSearchResult>.from(
                  searchResult.map((e) => EpubSearchResult.fromJson(e))));
        });

    ///current cfi callback
    webViewController?.addJavaScriptHandler(
        handlerName: "relocated",
        callback: (data) {
          var location = data[0];
          widget.onRelocated?.call(EpubLocation.fromJson(location));
        });

    webViewController?.addJavaScriptHandler(
        handlerName: "readyToLoad",
        callback: (data) {
          loadBook();
        });

    webViewController?.addJavaScriptHandler(
        handlerName: "displayError",
        callback: (data) {
          // loadBook();
        });

    webViewController?.addJavaScriptHandler(
        handlerName: "markClicked",
        callback: (data) {
          String cfi = data[0];
          widget.onAnnotationClicked?.call(cfi);
        });

    webViewController?.addJavaScriptHandler(
        handlerName: "epubText",
        callback: (data) {
          var text = data[0].trim();
          var cfi = data[1];
          widget.epubController.pageTextCompleter
              .complete(EpubTextExtractRes(text: text, cfiRange: cfi));
        });

    webViewController?.addJavaScriptHandler(
        handlerName: "centerClicked",
        callback: (data) {
          widget.onCenterClicked?.call();
        });
  }

  loadBook() async {
    var data = await widget.epubSource.epubData;
    final displaySettings = widget.displaySettings ?? EpubDisplaySettings();
    String manager = displaySettings.manager.name;
    int fontSize = displaySettings.fontSize;
    String flow = displaySettings.flow.name;
    String spread = displaySettings.spread.name;
    bool snap = displaySettings.snap;
    bool allowScripted = displaySettings.allowScriptedContent;
    String cfi = widget.initialCfi ?? "";
    String direction = widget.displaySettings?.defaultDirection.name ??
        EpubDefaultDirection.ltr.name;

    bool useCustomSwipe =
        Platform.isAndroid && !displaySettings.useSnapAnimationAndroid;

    String? backgroundColor =
        widget.displaySettings?.theme?.backgroundColor?.toHex();
    String? foregroundColor =
        widget.displaySettings?.theme?.foregroundColor?.toHex();

    final path = await saveEpubToAppStorage(data, 'book.epub');
    await startLocalServer(path);

    webViewController?.evaluateJavascript(
        source:
            'loadBook("http://localhost:8080/book.epub", "$cfi", "$manager", "$flow", "$spread", $snap, $allowScripted, "$direction", $useCustomSwipe, "$backgroundColor", "$foregroundColor", "$fontSize")');
  }

  Future<String> saveEpubToAppStorage(Uint8List epubData, String fileName) async {
    final directory = await getApplicationDocumentsDirectory(); // ✅ 앱 전용 저장소
    final filePath = "${directory!.path}/$fileName";
    final file = File(filePath);
    await file.writeAsBytes(epubData);
    return filePath; // ✅ WebView에서 접근 가능
  }

  Future<void> startLocalServer(String filePath) async {
    var directory = await getApplicationDocumentsDirectory();
    var handler = createStaticHandler(directory.path, listDirectories: false);
    var server = await shelf_io.serve(handler, 'localhost', 8080);

    print('✅ Local EPUB server running at http://${server.address.host}:${server.port}');
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      contextMenu: widget.selectionContextMenu,
      key: webViewKey,
      initialFile:
          'packages/flutter_epub_viewer/lib/assets/webpage/html/swipe.html',
      // initialUrlRequest: URLRequest(
      //     url: WebUri(
      //         'http://localhost:8080/html/swipe.html?cfi=${widget.initialCfi ?? ''}&displaySettings=$displaySettings')),
      initialSettings: settings
        ..disableVerticalScroll = widget.displaySettings?.snap ?? false
        ..allowFileAccess = true
        ..allowContentAccess = true
        ..allowsInlineMediaPlayback = true
        ..clearCache = true
        ..javaScriptEnabled = true
        ..allowUniversalAccessFromFileURLs = true // ✅ 추가
        ..allowFileAccessFromFileURLs = true, // ✅ 추가

      // pullToRefreshController: pullToRefreshController,
      onWebViewCreated: (controller) async {
        webViewController = controller;
        widget.epubController.setWebViewController(controller);
        // await loadBook();
        addJavaScriptHandlers();
      },
      onLoadStart: (controller, url) {},
      onPermissionRequest: (controller, request) async {
        return PermissionResponse(
            resources: request.resources,
            action: PermissionResponseAction.GRANT);
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        var uri = navigationAction.request.url!;

        if (!["http", "https", "file", "chrome", "data", "javascript", "about"]
            .contains(uri.scheme)) {
          // if (await canLaunchUrl(uri)) {
          //   // Launch the App
          //   await launchUrl(
          //     uri,
          //   );
          //   // and cancel the request
          //   return NavigationActionPolicy.CANCEL;
          // }
        }

        return NavigationActionPolicy.ALLOW;
      },
      onLoadStop: (controller, url) async {
        //addJavaScriptHandlers();
        await controller.evaluateJavascript(source: "document.body.style.visibility='visible';");
      },
      onReceivedError: (controller, request, error) {},

      onProgressChanged: (controller, progress) {},
      onUpdateVisitedHistory: (controller, url, androidIsReload) {},
      onConsoleMessage: (controller, consoleMessage) {
        if (kDebugMode) {
          debugPrint("JS_LOG: ${consoleMessage.message}");
          // debugPrint(consoleMessage.message);
        }
      },
      gestureRecognizers: {
        Factory<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer()),
        Factory<LongPressGestureRecognizer>(() => LongPressGestureRecognizer(
            duration: const Duration(milliseconds: 30))),
      },
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
