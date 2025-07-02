import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:gsheets/gsheets.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'secrets.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: const StockHomePage());
  }
}

class StockHomePage extends StatefulWidget {
  const StockHomePage({super.key});

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
    _initSheets()
        .then((_) {
          setState(() {
            isReady = true;
          });
          if (kDebugMode) {
            print("Google Sheets initialized successfully.");
          }
        })
        .catchError((error) {
          if (kDebugMode) {
            print("Error initializing Google Sheets: $error");
          }
        });
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

  Future<void> _initSheets() async {
    final gsheets = GSheets(jsonDecode(googleSheetCredentials));
    final ss = await gsheets.spreadsheet(spreadsheetID);
    _stockSheet =
        ss.worksheetByTitle('Stock Count') ??
        await ss.addWorksheet('Stock Count');
    _timelineSheet =
        ss.worksheetByTitle('Timeline') ?? await ss.addWorksheet('Timeline');
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
      onSessionErrorIos: (p0) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("NFC session error: $p0"))),
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
            record.payload.skip(2),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error reading NFC tag: $e')));
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

    final partName = parts[0];
    final action = parts[1];

    await _lookupPart(partName);

    if (partInfo == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Part not found: $partName')));
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
                '${partInfo!['name']} incremented to ${partInfo!['count']}',
              ),
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
                '${partInfo!['name']} decremented to ${partInfo!['count']}',
              ),
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
      if (kDebugMode) {
        print("Google Sheets not ready yet.");
      }
      return;
    }
    final rows = await _stockSheet.values.allRows();
    final match = rows.firstWhere(
      (row) => row.isNotEmpty && row[0].trim() == id.trim(),
      orElse: () => [],
    );
    if (match.isNotEmpty) {
      setState(() {
        partInfo = {
          'name': match[0],
          'count': int.tryParse(match[1]) ?? 0,
          'cad': match[2],
          'drawing': match[3],
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
    final index = rows.indexWhere((row) => row[0].trim() == partInfo!['name']);
    if (index == -1) return;

    int newCount = partInfo!['count'] + (increment ? 1 : -1);
    newCount = newCount < 0 ? 0 : newCount;

    await _stockSheet.values.insertValue(newCount, column: 2, row: index + 1);

    await _timelineSheet.values.appendRow([
      partInfo!['name'],
      savedName,
      increment ? 'Increment' : 'Decrement',
      newCount.toString(),
      DateFormat.jm().format(DateTime.now()),
      DateFormat.yMMMd().format(DateTime.now()),
    ]);

    setState(() => partInfo!['count'] = newCount);
  }

  void _openLink(String url) async {
    if (url.isEmpty || url.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No URL provided')));
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
            ),
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print("Error parsing URL: $e");
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Invalid URL format: $url')));
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
        title: const Text('135 Stock Updater'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  text: 'Welcome, ',
                  style: const TextStyle(fontSize: 20),
                  children: [
                    TextSpan(
                      text: savedName.isNotEmpty ? savedName : 'no name. Go To Settings.',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                      ),
                    ),
                  ],
                ),
              ),
              Text.rich(
                TextSpan(
                  text: runningNFC
                      ? 'NFC Is Currently running, place near a tag.'
                      : 'Waiting for NFC... (Restart when you have NFC enabled in settings.)',
                  style: const TextStyle(fontSize: 48, color: Colors.grey),
                ),
              ),
              if (savedManualPartEntryEnabled) ...[
                TextField(
                  controller: manualIdController,
                  decoration: const InputDecoration(
                    labelText: 'Manual Part Number',
                  ),
                ),
                ElevatedButton(
                  onPressed: () => _lookupPart(manualIdController.text.trim()),
                  child: const Text('Lookup Part'),
                ),
              ],
              
              const SizedBox(height: 24),
              if (partInfo != null) ...[
                Text('Part: ${partInfo!['name']}'),
                Text('Stock: ${partInfo!['count']}'),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () => _updateCount(true),
                      child: const Text('+1'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => _updateCount(false),
                      child: const Text('-1'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _openLink(partInfo!['cad']),
                  child: const Text('View CAD'),
                ),
                TextButton(
                  onPressed: () => _openLink(partInfo!['drawing']),
                  child: const Text('View Drawing'),
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
  bool isManualEntryEnabled = false; // Always enabled for this example
  String? hasError;
  @override
  void initState() {
    super.initState();
    nameController.text = widget.currentName;
    isManualEntryEnabled = widget.manualPartEntryEnabled;
  }

  Future<void> _writeNfcTag() async {
    if (partNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter a part name')));
      return;
    }

    bool isAvailable = await NfcManager.instance.isAvailable();
    if (!isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('NFC is not available on this device')),
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

            final languageCode = 'en';
            final textBytes = utf8.encode(content);
            final languageCodeBytes = utf8.encode(languageCode);

            final payloadLength =
                1 + languageCodeBytes.length + textBytes.length;
            final payload = Uint8List(payloadLength);

            payload[0] = languageCodeBytes.length;
            payload.setRange(
              1,
              1 + languageCodeBytes.length,
              languageCodeBytes,
            );
            payload.setRange(
              1 + languageCodeBytes.length,
              payloadLength,
              textBytes,
            );

            final message = NdefMessage(
              records: [
                NdefRecord(
                  typeNameFormat: TypeNameFormat.wellKnown,
                  type: Uint8List.fromList([0x54]), // 'T' for Text record
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
                  backgroundColor: Colors.green,
                ),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error writing to tag: $e')),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      setState(() => isWriting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'User Settings',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Your Name',
                helperText: 'This will be saved for future sessions',
                errorText: hasError
              ),
              onChanged: (name) async {
                final success = await widget.onNameChanged(name);
                if (!success) {
                  setState(() {
                    hasError = 'Invalid name format. Use "First Last" format.';
                  });
                }else{
                  setState(() {
                    hasError = null;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            //checkbox to show manual part entering
            CheckboxListTile(
              title: const Text('Enable Manual Part Entry'),
              value: isManualEntryEnabled,
              onChanged: (value) {
                setState(() {
                  isManualEntryEnabled = value ?? false;
                  widget.onPartEntryChanged(value!);
                });
              },
            ),
            const SizedBox(height: 32),
            const Text(
              'NFC Tag Programming',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: partNameController,
              decoration: const InputDecoration(
                labelText: 'Part Name',
                helperText: 'e.g., WCP-0251 or am-4985',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: selectedAction,
              decoration: const InputDecoration(labelText: 'Action'),
              items: const [
                DropdownMenuItem(
                  value: 'Increment',
                  child: Text('Increment (+1)'),
                ),
                DropdownMenuItem(
                  value: 'Decrement',
                  child: Text('Decrement (-1)'),
                ),
                DropdownMenuItem(value: 'Drawing', child: Text('Open Drawing')),
              ],
              onChanged: (value) {
                setState(() => selectedAction = value!);
              },
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isWriting ? null : _writeNfcTag,
                child: isWriting
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('Hold phone near NFC tag...'),
                        ],
                      )
                    : const Text('Write to NFC Tag'),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Instructions:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text(
              '1. Enter the part name exactly as it appears in your spreadsheet\n'
              '2. Choose the action you want the tag to perform\n'
              '3. Tap "Write to NFC Tag" and hold your phone near the tag\n'
              '4. Wait for confirmation before removing the tag',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    partNameController.dispose();
    super.dispose();
  }
}
