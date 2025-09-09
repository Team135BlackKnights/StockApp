import 'dart:async';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:gsheets/gsheets.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'secrets.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final AppLinks appLinks;
  final GlobalKey<_StockHomePageState> _stockHomePageKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    appLinks = AppLinks();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = _stockHomePageKey.currentState;
      if (state != null) {
        state
            .initSheets()
            .then((_) {
              setState(() {});
              if (kDebugMode) {
                print("Google Sheets initialized successfully.");
              }
              _handleInitialLinks();
            })
            .catchError((error) {
              if (kDebugMode) {
                print(error);
                print("Error initializing Google Sheets: $error");
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error initializing Google Sheets: $error'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            });
      } else {
        if (kDebugMode) {
          print("Error: StockHomePage not mounted yet.");
        }
      }
    });
  }

  Future<void> _handleInitialLinks() async {
    // Ongoing link stream while app is running
    appLinks.uriLinkStream.listen(
      (Uri uri) {
        if (uri.scheme == 'stock135') {
          //uri.toString returns stock135://wcp-0251%7Cincrement
          // We just need to decode the utf8 into text
          final livePayload = utf8
              .decode(uri.toString().codeUnits.toList())
              .replaceAll('%7C', '|');
          debugPrint("Live app link received: $livePayload");

          // If StockHomePage is already mounted, pass it to the handler
          final state = _stockHomePageKey.currentState;
          state!._processNfcContent(livePayload);
        }
      },
      onError: (err) {
        debugPrint("Error listening for app links: $err");
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        primarySwatch: Colors.blue,
        primaryColor: const Color(0xFF1976D2),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1976D2),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF1976D2),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.grey),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.grey),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF1976D2), width: 2),
          ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          color: Colors.white,
        ),
      ),
      home: StockHomePage(key: _stockHomePageKey),
    );
  }
}

class StockHomePage extends StatefulWidget {
  final String? initialPayload;
  const StockHomePage({super.key, this.initialPayload});
  @override
  State<StockHomePage> createState() => _StockHomePageState();
}

class _StockHomePageState extends State<StockHomePage> {
  final manualIdController = TextEditingController();

  late Worksheet _stockSheet;
  late Worksheet _timelineSheet;
  String? tagId;
  Map<String, dynamic>? partInfo;
  bool isReady = false;
  String savedName = '';
  bool savedManualPartEntryEnabled = false;
  bool runningNFC = false;
  @override
  void initState() {
    super.initState();
    _loadSavedName();
    _loadSavedManualPartEntryEnabled();
    _startNfc();
  }

  Future<void> _loadSavedName() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('user_name') ?? '';
    setState(() {
      savedName = name;
    });
  }

  Future<bool> _saveName(String name) async {
    //Confirm no numbers, two words, each word has first letter capitalized, at least 2 characters each words
    final regex = RegExp(r'^[A-Z][a-z]{1,}\s[A-Z][a-z]{1,}$');
    if (!regex.hasMatch(name)) {
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', name);
    setState(() {
      savedName = name;
    });
    return true;
  }

  Future<void> _loadSavedManualPartEntryEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('manual_part_entry_enabled') ?? false;
    setState(() {
      savedManualPartEntryEnabled = enabled;
    });
  }

  Future<void> _saveManualPartEntryEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('manual_part_entry_enabled', enabled);
    setState(() {
      savedManualPartEntryEnabled = enabled;
    });
  }

  Future<void> initSheets() async {
    final gsheets = GSheets(jsonDecode(googleSheetCredentials));
    final ss = await gsheets.spreadsheet(spreadsheetID);
    log("Connected to Google Sheets: ${ss.url}");
    _stockSheet =
        ss.worksheetByTitle('Stock Count') ??
        await ss.addWorksheet('Stock Count');
    _timelineSheet =
        ss.worksheetByTitle('Timeline') ?? await ss.addWorksheet('Timeline');
    isReady = true;
  }

  void _startNfc() async {
    bool isAvailable = await NfcManager.instance.isAvailable();
    if (!isAvailable) return;
    if (kDebugMode) {
      print("Running NFC Detection...");
    }
    NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443},
      invalidateAfterFirstReadIos: false,
      alertMessageIos: 'Hold your phone near an NFC tag to read it',
      onSessionErrorIos: (p0) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("NFC session error: $p0"),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      onDiscovered: (NfcTag tag) async {
        await _handleNfcTag(tag);
        // Wait for more tags.  This is important to allow multiple reads without restarting the session.
      },
    );
    setState(() {
      runningNFC = true;
    });
  }

  Future<void> _handleNfcTag(NfcTag tag) async {
    try {
      final ndef = Ndef.from(tag);
      if (ndef != null && ndef.cachedMessage != null) {
        final message = ndef.cachedMessage!;
        if (message.records.isNotEmpty) {
          final record = message.records.first;
          final payload = String.fromCharCodes(
            record.payload.skip(3),
          ); // may need to be 3 to skip language code...
          if (kDebugMode) {
            print("NFC Tag content: $payload");
          }
          await _processNfcContent(payload);
          return;
        }
      }

      // Fallback to tag ID if no NDEF data
      // ignore: invalid_use_of_protected_member
      final tagIdString = tag.data.toString();
      if (kDebugMode) {
        print("Using tag ID as fallback: $tagIdString");
      }
      await _lookupPart(tagIdString);
    } catch (e) {
      if (kDebugMode) {
        print("Error handling NFC tag: $e");
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error reading NFC tag: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _processNfcContent(String content) async {
    final parts = content.split('|');
    if (parts.length < 2) {
      if (kDebugMode) {
        print("Invalid NFC content format: $content");
      }
      return;
    }
    //parts [0] looks like "135://PARTNAME", we only need the part name
    //parts [1] looks like "increment" or "decrement" or "drawing"
    final partName = parts[0].split('://').last.trim().toUpperCase();
    final action = parts[1];

    await _lookupPart(partName);

    if (partInfo == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Part not found: $partName'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    switch (action.toLowerCase()) {
      case 'increment':
        await _updateCount(true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${partInfo!['humanName']} incremented to ${partInfo!['count']}',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        break;
      case 'decrement':
        await _updateCount(false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${partInfo!['humanName']} decremented to ${partInfo!['count']}',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        break;
      case 'drawing':
        _openLink(partInfo!['drawing']);
        break;
      default:
        if (kDebugMode) {
          print("Unknown action: $action");
        }
    }
  }

  Future<void> _lookupPart(String id) async {
    if (!isReady) {
      await initSheets();
      //force an init of them

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Google Sheets not ready yet. Try again.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    final rows = await _stockSheet.values.allRows();
    final match = rows.firstWhere(
      (row) {
        if (row.length == 1) {
          // skip
          return false;
        }
        return row.isNotEmpty && row[1].trim().toUpperCase() == (id.trim().toUpperCase());
      },
      orElse: () => [],
    );

    if (match.isNotEmpty) {
      setState(() {
        partInfo = {
          'humanName': match[0],
          'name': match[1],
          'count': int.tryParse(match[2]) ?? 0,
          'cad': match[3],
          'drawing': match[4],
        };
      });
    } else {
      setState(() {
        partInfo = null;
      });
    }
  }

  Future<void> _updateCount(bool increment) async {
    if (partInfo == null) return;
    final rows = await _stockSheet.values.allRows();
    final index = rows.indexWhere(
      (row) {
        if (row.length == 1) {
          // skip
          return false;
        }
        return row.isNotEmpty && row[1].trim().toUpperCase() == partInfo!['name'].trim().toUpperCase();
      },
    );
    if (index == -1) return;
    if (partInfo!['humanName'].contains('Laptop')) {
      // Handle case where its actually a SIGNOUT device.
      bool isCheckedOutAlready = partInfo!['count'] == 1; 
      if (isCheckedOutAlready && increment) {
        //BAD
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Device already checked out! Return it first from ${partInfo!['cad']}.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      } 
      if (!isCheckedOutAlready && !increment){
        //BAD
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Device not checked out, cannot return!'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      //All good, save the current user as the one who checked it out in partInfo[cad]
      await _stockSheet.values.insertValue(increment ? 1 : 0, column: 3, row: index + 1);
      await _stockSheet.values.insertValue(increment ? savedName : '', column: 4, row: index + 1);
      await _timelineSheet.values.appendRow([
        partInfo!['name'],
        savedName,
        increment ? 'Checked Out' : 'Returned',
        increment ? '1' : '0',
        DateFormat.jm().format(DateTime.now()),
        DateFormat.yMMMd().format(DateTime.now()),
      ]);
      setState(() {
        partInfo!['cad'] = increment ? savedName : '';
        partInfo!['count'] = increment ? 1 : 0;
      });
    } else { //NOT a "Signout"
      int newCount = partInfo!['count'] + (increment ? 1 : -1);
      newCount = newCount < 0 ? 0 : newCount;

      await _stockSheet.values.insertValue(newCount, column: 3, row: index + 1);

      await _timelineSheet.values.appendRow([
        partInfo!['name'],
        savedName,
        increment ? 'Increment' : 'Decrement',
        newCount.toString(),
        DateFormat.jm().format(DateTime.now()),
        DateFormat.yMMMd().format(DateTime.now()),
      ]);
      setState(() =>         partInfo!['count'] = newCount);
    }
    

  }

  void _openLink(String url) async {
    if (url.isEmpty || url.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No URL provided'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      final uri = Uri.parse(url.trim());
      if (kDebugMode) {
        print("Attempting to open URL: $url");
      }

      bool launched = false;

      // For Android, try in-app browser first as it's more reliable
      try {
        launched = await launchUrl(
          uri,
          mode: LaunchMode.inAppBrowserView,
          browserConfiguration: const BrowserConfiguration(showTitle: true),
        );
        if (kDebugMode) {
          print("Launched in in-app browser: $launched");
        }
      } catch (e) {
        if (kDebugMode) {
          print("In-app browser failed: $e");
        }
      }

      // If in-app browser fails, try external application
      if (!launched) {
        try {
          launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
          if (kDebugMode) {
            print("Launched in external app: $launched");
          }
        } catch (e) {
          if (kDebugMode) {
            print("External application failed: $e");
          }
        }
      }

      // Last resort: try platform default
      if (!launched) {
        try {
          launched = await launchUrl(uri);
          if (kDebugMode) {
            print("Launched with platform default: $launched");
          }
        } catch (e) {
          if (kDebugMode) {
            print("Platform default failed: $e");
          }
        }
      }

      if (!launched) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Could not open URL: $url\nTry copying the link manually',
              ),
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print("Error parsing URL: $e");
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid URL format: $url'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          currentName: savedName,
          manualPartEntryEnabled: savedManualPartEntryEnabled,
          onNameChanged: _saveName,
          onPartEntryChanged: _saveManualPartEntryEnabled,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.inventory_2, color: Colors.white),
            SizedBox(width: 8),
            Text(
              'Stock Updater',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 50),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Welcome Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.person,
                            color: Color(0xFF1976D2),
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                text: 'Welcome, ',
                                style: const TextStyle(
                                  fontSize: 22,
                                  color: Colors.grey,
                                ),
                                children: [
                                  TextSpan(
                                    text: savedName.isNotEmpty
                                        ? savedName.split(
                                            " ",
                                          )[0] // First name only
                                        : 'Anonymous',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 22,
                                      color: Color(0xFF1976D2),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (savedName.isEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange[50],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orange[200]!),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.warning,
                                color: Colors.orange,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Please set your name in Settings',
                                  style: TextStyle(color: Colors.orange),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // NFC Status Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.nfc,
                            color: runningNFC ? Colors.green : Colors.grey,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'NFC Status',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: 'Refresh',
                            onPressed: () async {
                              bool isAvailable = await NfcManager.instance
                                  .isAvailable();
                              setState(() {
                                runningNFC = isAvailable;
                              });
                              if (isAvailable && !runningNFC) {
                                _startNfc(); // Start NFC session if available and not running
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: runningNFC
                              ? Colors.green[50]
                              : Colors.grey[50],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: runningNFC
                                ? Colors.green[200]!
                                : Colors.grey[300]!,
                          ),
                        ),
                        child: Row(
                          children: [
                            if (runningNFC) ...[
                              const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'NFC is ready. Hold your phone near a tag to scan.',
                                  style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ] else ...[
                              const Icon(
                                Icons.error,
                                color: Colors.grey,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'NFC is not available. Please enable NFC in device settings.',
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Manual Entry Card
              if (savedManualPartEntryEnabled) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.keyboard,
                              color: Color(0xFF1976D2),
                              size: 28,
                            ),
                            SizedBox(width: 12),
                            Text(
                              'Manual Part Entry',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: manualIdController,
                          decoration: const InputDecoration(
                            labelText: 'Enter Part Number',
                            hintText: 'e.g., WCP-0251',
                            prefixIcon: Icon(Icons.search),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () =>
                                _lookupPart(manualIdController.text.trim()),
                            child: const Text('Look Up Part'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // Part Information Card
              if (partInfo != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.info,
                              color: Color(0xFF1976D2),
                              size: 28,
                            ),
                            SizedBox(width: 12),
                            Text(
                              'Part Information',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Part Name (more legible)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue[200]!),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.tag, color: Color(0xFF1976D2)),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Human-friendly title: larger and clearer
                                  Text(
                                    partInfo!['humanName'],
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1976D2),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Part Number',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    partInfo!['name'],
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1976D2),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Stock Count or Signout status for devices
                        Builder(builder: (context) {
                          final isLaptop = partInfo!['humanName']
                                  .toString()
                                  .toLowerCase()
                                  .contains('laptop');
                          final isCheckedOut = partInfo!['count'] == 1;

                          if (isLaptop) {
                            // For signout devices show checked out user instead of numeric stock
                            return Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: isCheckedOut ? Colors.orange[50] : Colors.green[50],
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: isCheckedOut ? Colors.orange[200]! : Colors.green[200]!),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isCheckedOut ? Icons.person : Icons.check_circle,
                                    color: isCheckedOut ? Colors.orange : Colors.green,
                                  ),
                                  const SizedBox(width: 12),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Status',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (isCheckedOut) ...[
                                        const Text(
                                          'Checked out to',
                                          style: TextStyle(fontSize: 12, color: Colors.grey),
                                        ),
                                        Text(
                                          partInfo!['cad'] ?? 'Unknown',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.orange,
                                          ),
                                        ),
                                      ] else ...[
                                        const Text(
                                          'Available',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            );
                          }

                          // Default stock display for non-signout parts
                          return Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.green[50],
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.green[200]!),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.inventory, color: Colors.green),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Current Stock',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      '${partInfo!['count']} units',
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        }),

                        const SizedBox(height: 20),

                        // Action Buttons
                        const Text(
                          'Actions',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Render actions differently for 'Laptop' signout devices
                        Builder(builder: (context) {
                          final isLaptop = partInfo!['humanName']
                              .toString()
                              .toLowerCase()
                              .contains('laptop');
                          final isCheckedOut = partInfo!['count'] == 1;

                          if (isLaptop) {
                            return Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () => _updateCount(!isCheckedOut),
                                    icon: Icon(isCheckedOut ? Icons.logout : Icons.login),
                                    label: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(isCheckedOut ? 'Sign Out' : 'Sign In'),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          isCheckedOut ? Colors.red : Colors.green,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }

                          // Non-laptop: normal increment/decrement
                          return Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () => _updateCount(true),
                                  icon: const Icon(Icons.add),
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: const Text('Add (+1)'),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () => _updateCount(false),
                                  icon: const Icon(Icons.remove),
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: const Text('Remove (-1)'),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }),

                        const SizedBox(height: 12),

                        // View Links (hidden for Laptop signout devices)
                        Builder(builder: (context) {
                          final isLaptop = partInfo!['humanName']
                              .toString()
                              .toLowerCase()
                              .contains('laptop');
                          if (isLaptop) {
                            return const SizedBox.shrink();
                          }

                          return Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _openLink(partInfo!['cad']),
                                  icon: const Icon(Icons.view_in_ar),
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: const Text('View CAD'),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF1976D2),
                                    side: const BorderSide(
                                      color: Color(0xFF1976D2),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _openLink(partInfo!['drawing']),
                                  icon: const Icon(Icons.picture_as_pdf),
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: const Text('View Drawing'),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF1976D2),
                                    side: const BorderSide(
                                      color: Color(0xFF1976D2),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    manualIdController.dispose();
    super.dispose();
  }
}

class SettingsPage extends StatefulWidget {
  final String currentName;
  final Future<bool> Function(String) onNameChanged;
  final bool manualPartEntryEnabled;
  final Function(bool) onPartEntryChanged;
  const SettingsPage({
    super.key,
    required this.currentName,
    required this.manualPartEntryEnabled,
    required this.onPartEntryChanged,
    required this.onNameChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final nameController = TextEditingController();
  final partNameController = TextEditingController();
  String selectedAction = 'Increment';
  bool isWriting = false;
  bool isManualEntryEnabled = false;
  String? hasError;

  @override
  void initState() {
    super.initState();
    nameController.text = widget.currentName;
    isManualEntryEnabled = widget.manualPartEntryEnabled;
  }

  Future<void> _writeNfcTag() async {
    if (partNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a part name'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    bool isAvailable = await NfcManager.instance.isAvailable();
    if (!isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('NFC is not available on this device'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    setState(() => isWriting = true);

    try {
      final content = '${partNameController.text.trim()}|$selectedAction';
      if (kDebugMode) {
        print("Writing to NFC tag: $content");
      }

      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443},
        onDiscovered: (NfcTag tag) async {
          try {
            final ndef = Ndef.from(tag);
            if (ndef == null) {
              throw 'This tag is not NDEF compatible';
            }

            if (!ndef.isWritable) {
              throw 'This tag is not writable';
            }

            final content = '${partNameController.text.trim()}|$selectedAction';
            final uriString = 'stock135://$content';

            // For URI records, the payload starts with a URI identifier byte
            // 0x00 means no abbreviation (full URI)
            final uriBytes = utf8.encode(uriString);
            final payload = Uint8List(1 + uriBytes.length);
            payload[0] = 0x00; // URI identifier byte for no abbreviation
            payload.setRange(1, payload.length, uriBytes);

            final message = NdefMessage(
              records: [
                NdefRecord(
                  typeNameFormat: TypeNameFormat.wellKnown,
                  type: Uint8List.fromList([0x55]), // 'U' for URI record
                  identifier: Uint8List(0),
                  payload: payload,
                ),
              ],
            );

            if (message.byteLength > ndef.maxSize) {
              throw 'Content too long for this tag';
            }

            await ndef.write(message: message);

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('NFC tag written successfully!'),
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: Colors.green,
                ),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error writing to tag: $e'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          } finally {
            await NfcManager.instance.stopSession();
            setState(() => isWriting = false);
          }
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      setState(() => isWriting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.settings, color: Colors.white),
            SizedBox(width: 8),
            Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20.0).copyWith(bottom: 50),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // User Settings Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.person,
                            color: Color(0xFF1976D2),
                            size: 28,
                          ),
                          SizedBox(width: 12),
                          Text(
                            'User Settings',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: 'Your Name',
                          hintText: 'Enter your full name (e.g., John Doe)',
                          helperText: 'This will be saved for future sessions',
                          errorText: hasError,
                          prefixIcon: const Icon(Icons.badge),
                        ),
                        onChanged: (name) async {
                          final success = await widget.onNameChanged(name);
                          if (!success) {
                            setState(() {
                              hasError =
                                  'Invalid name format. Use "First Last" format.';
                            });
                          } else {
                            setState(() {
                              hasError = null;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 20),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.grey[50],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: SwitchListTile(
                          title: const Text(
                            'Enable Manual Part Entry',
                            style: TextStyle(fontWeight: FontWeight.w500),
                          ),
                          subtitle: const Text(
                            'Allow typing part numbers manually',
                          ),
                          value: isManualEntryEnabled,
                          onChanged: (value) {
                            setState(() {
                              isManualEntryEnabled = value;
                              widget.onPartEntryChanged(value);
                            });
                          },
                          activeColor: const Color(0xFF1976D2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // NFC Tag Programming Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.nfc, color: Color(0xFF1976D2), size: 28),
                          SizedBox(width: 12),
                          Text(
                            'NFC Tag Programming',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: partNameController,
                        decoration: InputDecoration(
                          labelText: 'Part Name',
                          hintText: 'e.g., WCP-0251 or AM-4985',
                          helperText: null, // Set to null for FittedBox
                          prefixIcon: Icon(Icons.label),
                        ),
                      ),
                      const FittedBox(
                        child: Text(
                          'Enter a part name from PR Stock spreadsheet',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 20),
                      DropdownButtonFormField<String>(
                        value: selectedAction,
                        decoration: const InputDecoration(
                          labelText: 'Tag Action',
                          prefixIcon: Icon(Icons.touch_app),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'Increment',
                            child: Row(
                              children: [
                                Icon(Icons.add, color: Colors.green, size: 20),
                                SizedBox(width: 8),
                                Text('Increment (+1)'),
                              ],
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'Decrement',
                            child: Row(
                              children: [
                                Icon(Icons.remove, color: Colors.red, size: 20),
                                SizedBox(width: 8),
                                Text('Decrement (-1)'),
                              ],
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'Drawing',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.picture_as_pdf,
                                  color: Colors.blue,
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Text('Open Drawing'),
                              ],
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() => selectedAction = value!);
                        },
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: isWriting ? null : _writeNfcTag,
                          icon: isWriting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.nfc),
                          label: Text(
                            isWriting
                                ? 'Hold phone near NFC tag...'
                                : 'Write to NFC Tag',
                          ),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: isWriting
                                ? Colors.grey
                                : const Color(0xFF1976D2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Instructions Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.help_outline,
                            color: Color(0xFF1976D2),
                            size: 28,
                          ),
                          SizedBox(width: 12),
                          Text(
                            'How to Program NFC Tags',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.blue[50],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.blue[200]!),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildInstructionStep(
                              '1',
                              'Enter Part Name',
                              'Type the exact part name as it appears in your spreadsheet',
                              Icons.edit,
                            ),
                            const SizedBox(height: 12),
                            _buildInstructionStep(
                              '2',
                              'Select Action',
                              'Choose what the tag should do when scanned',
                              Icons.touch_app,
                            ),
                            const SizedBox(height: 12),
                            _buildInstructionStep(
                              '3',
                              'Write to Tag',
                              'Tap the button and hold your phone near the NFC tag',
                              Icons.nfc,
                            ),
                            const SizedBox(height: 12),
                            _buildInstructionStep(
                              '4',
                              'Wait for Success',
                              'Keep the tag near your phone until you see confirmation',
                              Icons.check_circle,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstructionStep(
    String number,
    String title,
    String description,
    IconData icon,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFF1976D2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Icon(icon, color: const Color(0xFF1976D2), size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Text(
                description,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    partNameController.dispose();
    super.dispose();
  }
}
