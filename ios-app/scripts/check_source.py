#!/usr/bin/env python3
"""Source grammar/config/safety assertions. NOT a Swift compiler or iOS build."""
import json, pathlib, plistlib, sys
import yaml
from tree_sitter import Language, Parser
import tree_sitter_swift
ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = Parser(Language(tree_sitter_swift.language()))
files = sorted(p for folder in ('PhoneAgent', 'PhoneAgentTests') for p in (ROOT / folder).rglob('*.swift'))
errors = []
for path in files:
    tree = parser.parse(path.read_bytes())
    if tree.root_node.has_error:
        errors.append(str(path.relative_to(ROOT)))
assert not errors, f'Swift grammar errors: {errors}'
project = yaml.safe_load((ROOT / 'project.yml').read_text())
assert project['settings']['base']['APP_DISPLAY_NAME'] == '随办'
assert project['packages']['SwiftAgentKit']['path'] == 'Vendor/SwiftAgentKit'
upstream = json.loads((ROOT / 'Vendor/SwiftAgentKit/UPSTREAM.json').read_text())
assert upstream['revision'] == '84ddf324fd2a223834323537eb3f8746d669753b'
assert project['packages']['ProviderKit']['path'] == 'ProviderKit'
assert 'PhoneAgentTests' in project['targets']
assert project['targets']['PhoneAgent']['settings']['base']['INFOPLIST_KEY_CFBundleDisplayName'] == '$(APP_DISPLAY_NAME)'
assert project['targets']['PhoneAgentLiveActivity']['settings']['base']['INFOPLIST_KEY_CFBundleDisplayName'] == '$(APP_DISPLAY_NAME)'
plistlib.loads((ROOT / 'PhoneAgent/PrivacyInfo.xcprivacy').read_bytes())
provider = (ROOT / 'PhoneAgent/Agent/Providers.swift').read_text()
controller = (ROOT / 'PhoneAgent/Agent/AgentViewModel.swift').read_text()
bridge = (ROOT / 'PhoneAgent/Bridge/TLSBridge.swift').read_text()
tools = (ROOT / 'PhoneAgent/Agent/DeviceTools.swift').read_text()
assert 'completionHandler(nil)' in provider
transport = (ROOT / 'ProviderKit/Sources/OpenAIAdapter/ResponsesTransport.swift').read_text()
assert 'URLSessionConfiguration.ephemeral' in transport
assert 'ModelError.interrupted' in provider
assert 'reasoning: parsed.reasoning' not in provider
assert 'enableRepairRetry: false' in controller
assert 'autonomousMode: false' in controller and 'parallelToolCalls: false' in controller
stop = controller.split('func stop(message', 1)[1].split('func approve(', 1)[0]
assert 'guard !stopping else {' in stop and 'if disconnectUSB' in stop
disconnect = controller.split('func disconnect()', 1)[1].split('func usbDiagnosticReport()', 1)[0]
assert 'cancelRun(' in disconnect and 'disconnectUSB: true' in disconnect
assert 'listenerGeneration = UUID(); listenerTask?.cancel()' in controller
assert 'listenerGeneration == listenerID' in bridge
assert 'guard generation == listenerID' in bridge
assert 'requestCancel()' in controller and 'provider?.cancel()' in controller
assert 'await oldTask?.value' in controller
assert 'rewriteMessages' in controller
assert 'sec_protocol_options_set_max_tls_protocol_version' in bridge
assert 'sec_protocol_options_set_verify_block' not in bridge
assert 'NWParameters(tls: tls, tcp: tcp)' in bridge
assert 'guard await approve' in tools and 'image = nil' in tools
assert 'requiresConfirmationEvenWhenAutonomous' not in tools # app-owned gate cannot be waived
background_plist = plistlib.loads((ROOT / 'PhoneAgent/Info.plist').read_bytes())
# Arbitrary INFOPLIST_KEY_* settings are not merged into this explicit plist
# by the device build; the runtime's two capture keys must live in the source.
assert background_plist['SuibanBroadcastAppGroup'] == '$(BROADCAST_APP_GROUP_IDENTIFIER)'
assert background_plist['SuibanBroadcastExtensionBundleIdentifier'] == project['targets']['PhoneAgentBroadcast']['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER']
assert set(background_plist['UIBackgroundModes']) == {'screen-capture', 'processing', 'audio', 'bluetooth-central'}
assert '随办硬件v1' in background_plist['NSBluetoothAlwaysUsageDescription']
assert background_plist['BGTaskSchedulerPermittedIdentifiers'] == ['$(PRODUCT_BUNDLE_IDENTIFIER).backgroundRun.*', '$(PRODUCT_BUNDLE_IDENTIFIER).pairing']
print(f'PASS: {len(files)} Swift files parsed; project/plist/pins and source guardrail assertions checked')
print('This script does not perform Swift type-check, dependency resolution, Xcode, XCTest, Simulator, or device/TLS tests.')
