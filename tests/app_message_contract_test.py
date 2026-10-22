"""Appmsg source contracts and redacted triage; not native XML/device tests."""
from pathlib import Path
import unittest

from tools.diagnose_report import analyze

ROOT = Path(__file__).resolve().parents[1]


class AppMessageContractTests(unittest.TestCase):
    def report(self, samples=None, **updates):
        probe = {'schema': 1, 'observerOnly': True, 'relayable': False,
                 'attempts': len(samples or []), 'dropped': 0, 'samples': samples or []}
        probe.update(updates)
        return {'reportSchema': 1, 'storageReady': True,
                'draftSummary': {'sourceSelected': True, 'senderCount': 1, 'ruleCount': 1},
                'sourceCapture': {'state': 'waiting'}, 'receiveCandidate': {'appMessageProbe': probe}}

    def sample(self, subtype):
        return {'state': 'parsed', 'subtype': subtype,
                'kindHint': {5: 'link', 6: 'file'}.get(subtype, 'other'),
                **{key: False for key in ('hasTitle', 'hasURL', 'hasAttachment',
                                         'hasAttachmentID', 'hasFileExtension', 'hasTotalLength')}}

    def codes(self, report):
        return {row['code'] for row in analyze(report)}

    def test_link_and_file_hints_are_not_captured_or_delivered(self):
        report = self.report([self.sample(5), self.sample(6)])
        codes = self.codes(report)
        self.assertTrue({'app_message_subtypes_observed', 'app_message_link_hint',
                         'app_message_file_hint'} <= codes)
        self.assertFalse({'preview_ready', 'text_host_invoked', 'image_snapshot_ready'} & codes)
        self.assertIn('not unique messages', str(analyze(report)))

    def test_unknown_subtypes_are_not_coerced_to_link_or_file(self):
        codes = self.codes(self.report([self.sample(2000), self.sample(2**32 - 1)]))
        self.assertIn('app_message_other_subtype', codes)
        self.assertFalse({'app_message_link_hint', 'app_message_file_hint'} & codes)

    def test_invalid_xml_and_getter_failure_are_distinct(self):
        self.assertIn('app_message_parse_rejected', self.codes(self.report([{'state': 'unsafe_xml'}])))
        codes = self.codes(self.report([{'state': 'content_unavailable', 'getterState': 2}]))
        self.assertIn('app_message_content_unavailable', codes)
        self.assertNotIn('app_message_parse_rejected', codes)

    def test_probe_limits_and_invalidated_queue(self):
        self.assertIn('app_message_probe_dropped', self.codes(self.report([self.sample(5)], dropped=1)))
        self.assertIn('app_message_no_stable_sample', self.codes(self.report(attempts=1)))
        for updates in ({'attempts': True}, {'attempts': 17}, {'dropped': -1}, {'samples': [{}] * 17}):
            self.assertIn('app_message_probe_invalid', self.codes(self.report(**updates)))

    def test_malformed_or_non_read_only_evidence_never_yields_hints(self):
        for updates in ({'schema': True}, {'schema': 2}, {'samples': 'private XML'},
                        {'samples': ['private XML'], 'attempts': 1}):
            codes = self.codes(self.report(**updates))
            self.assertIn('app_message_probe_invalid', codes)
            self.assertNotIn('app_message_link_hint', codes)
        for updates in ({'observerOnly': False}, {'relayable': True}):
            codes = self.codes(self.report([self.sample(5)], **updates))
            self.assertIn('app_message_probe_scope_invalid', codes)
            self.assertNotIn('app_message_link_hint', codes)

    def test_subtypes_and_classification_must_be_consistent(self):
        samples = [self.sample(value) for value in (True, -1, 2**32, 5.0, '5')]
        samples += [{**self.sample(5), 'kindHint': 'file'},
                    {**self.sample(5), 'hasURL': 'private URL'},
                    {'state': 'invalid_xml', 'subtype': 5}, {'state': 'private parser error'}]
        for sample in samples:
            codes = self.codes(self.report([sample]))
            self.assertIn('app_message_probe_invalid', codes)
            self.assertFalse({'app_message_link_hint', 'app_message_file_hint'} & codes)

    def test_private_fields_are_never_echoed(self):
        report = self.report([{**self.sample(5), 'xml': 'private XML',
                               'url': 'private URL', 'attachid': 'wxid_secret'}])
        result = str(analyze(report))
        for secret in ('private XML', 'private URL', 'wxid_secret'):
            self.assertNotIn(secret, result)

    def test_receiver_keeps_xml_probe_separate_from_relay_types(self):
        source = (ROOT / 'Adapter/SRWeChatReceiver.m').read_text(encoding='utf-8')
        allowed = source.split('- (BOOL)allowsSender:', 1)[1].split('- (void)observeSession:', 1)[0]
        self.assertIn('@"unsupported"', allowed)
        self.assertNotIn('@"file"', allowed)
        self.assertNotIn('@"link"', allowed)
        probe = source.split('- (void)observeAppMessageWrap:', 2)[2].split('- (void)observeOutgoingManager:', 1)[0]
        self.assertLess(probe.index('self.senderIDs containsObject:sender'), probe.index('SRReadDeclaredString(wrap, @"m_nsContent"'))
        self.assertLess(probe.index('SRAppMessageSampleLimit'), probe.index('dispatch_async'))
        self.assertLess(probe.index('receiver.currentAccount()'), probe.index('SRReadDeclaredString(wrap, @"m_nsContent"'))
        for forbidden in ('deliverMessage:', 'self.received(', 'prepareImage(', 'GetMsg:', 'valueForKey:', 'AddAppMsg:'):
            self.assertNotIn(forbidden, probe)

    def test_xml_parser_is_bounded_and_never_resolves_external_entities(self):
        source = (ROOT / 'Adapter/SRWeChatReceiver.m').read_text(encoding='utf-8')
        parser = source.split('@implementation SRAppMessageXMLProbe', 1)[1].split('@end', 1)[0]
        self.assertIn('128 * 1024', source)
        self.assertIn('self.path.count >= 32', parser)
        self.assertIn('self.elements > 1024', parser)
        self.assertLess(parser.index('content.length > SRAppMessageByteLimit'), parser.index('dataUsingEncoding:'))
        self.assertLess(parser.index('@"<!DOCTYPE"'), parser.index('[parser parse]'))
        self.assertLess(parser.index('NSMakeRange(0, 1)'), parser.index('dataUsingEncoding:'))
        self.assertIn('parser.shouldResolveExternalEntities = NO', parser)
        self.assertIn('NSXMLParserResolveExternalEntitiesNever', parser)
        for forbidden in ('NSLog(', 'parserError', 'contentsOfURL:', 'writeTo', 'NSURLSession', 'URLWithString:'):
            self.assertNotIn(forbidden, parser)

    def test_existing_native_target_includes_production_parser_cases(self):
        test = (ROOT / 'tests/receive_test.m').read_text(encoding='utf-8')
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        self.assertIn('#import "app_message_probe_cases.h"', test)
        self.assertIn('checkAppMessageProbe();', test)
        command = next(line for line in workflow.splitlines() if line.strip().startswith('clang ') and 'tests/receive_test.m' in line)
        self.assertIn('Adapter/SRWeChatReceiver.m', command)


if __name__ == '__main__':
    unittest.main()
