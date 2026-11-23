"""Local SQL/source safeguards, not UIKit execution or host delivery evidence."""
from pathlib import Path
import re
import sqlite3
import unittest

from library_task_test import TaskFixture, schema

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
LIBRARY = (ROOT / 'UI/SRLibraryScreens.m').read_text(encoding='utf-8')
RECORDS = (ROOT / 'UI/SRPlanScreens.m').read_text(encoding='utf-8')
PLANNER = (ROOT / 'Core/SRGroupPlanner.m').read_text(encoding='utf-8')


def method(source, signature):
    return source.split(signature, 1)[1].split('\n}', 1)[0]


class LocalImagePreviewGuards(unittest.TestCase):
    def test_current_preview_query_rejects_wrong_owner_stale_version_text_and_hidden(self):
        body = method(STORE, '- (NSData *)libraryImageDataForItem:')
        sql = re.search(r'\[self query:@"([^"\n]+)"', body).group(1)
        db = sqlite3.connect(':memory:')
        self.addCleanup(db.close)
        schema(db)
        fixture = TaskFixture(db)
        version = fixture.item(identifier='photo', kind='image')
        self.assertIsNotNone(db.execute(sql, ('photo', 'account', version)).fetchone())
        self.assertIsNone(db.execute(sql, ('photo', 'other', version)).fetchone())
        self.assertIsNone(db.execute(sql, ('photo', 'account', 'stale')).fetchone())
        text = fixture.item(identifier='text')
        self.assertIsNone(db.execute(sql, ('text', 'account', text)).fetchone())
        db.execute("INSERT INTO library_deletions VALUES('photo','account',10)")
        self.assertIsNone(db.execute(sql, ('photo', 'account', version)).fetchone())

    def test_previews_are_read_only_and_frozen_history_is_not_the_current_item(self):
        for signature in ('- (NSData *)libraryImageDataForItem:', '- (NSData *)forwardingImageDataForRun:'):
            body = method(STORE, signature)
            self.assertIn('transaction:NO', body)
            for forbidden in ('INSERT ', 'UPDATE ', 'DELETE ', 'startLibraryTask:', 'saveData:', 'saveLibraryImageData:'):
                self.assertNotIn(forbidden, body)
        frozen = method(STORE, '- (NSData *)forwardingImageDataForRun:')
        self.assertIn('[frozen[@"frozen"] isEqual:row[@"snapshot"]]', frozen)
        self.assertIn('[source[@"account"] isEqual:account]', frozen)
        self.assertNotIn('libraryImageDataForItem:', frozen)
        self.assertNotIn('current_version_id', frozen)

    def test_decoder_is_bounded_serial_memory_only_and_invalidates_late_results(self):
        loader = LIBRARY.split('@implementation SRLocalImagePreviews', 1)[1].split('@end', 1)[0]
        for required in ('maxConcurrentOperationCount = 1', 'totalCostLimit = 8 * 1024 * 1024',
                         'self.pending.count >= 16', 'kCGImageSourceThumbnailMaxPixelSize',
                         'loader.generation != generation', 'cancelAllOperations', 'removeAllObjects',
                         'weakOperation.cancelled', 'dispatch_get_main_queue()'):
            self.assertIn(required, loader)
        for forbidden in ('NSURLSession', 'writeToFile:', 'imageWithContentsOfFile:', 'dataForPayload:', 'download'):
            self.assertNotIn(forbidden, loader)

    def test_list_history_thumbnails_and_proportional_detail_have_distinct_sizes(self):
        for source in (LIBRARY, RECORDS):
            self.assertIn('imageProperties.maximumSize = CGSizeMake(48, 48)', source)
            self.assertIn('imageProperties.reservedLayoutSize = CGSizeMake(48, 48)', source)
            self.assertIn('imageProperties.cornerRadius = 6', source)
        detail = method(LIBRARY, '- (UIView *)imagePreviewForVersion:')
        for required in ('UIViewContentModeScaleAspectFit', 'multiplier:0.7', 'constraintLessThanOrEqualToConstant:240',
                         'constraintLessThanOrEqualToConstant:image.size.width', 'page.entry[@"current_version_id"]'):
            self.assertIn(required, detail)

    def test_historical_groups_never_consult_current_configuration(self):
        body = method(STORE, '- (NSArray *)forwardingGroupsUnchecked:')
        self.assertIn('snapshot[@"targetGroups"]', body)
        self.assertIn('SRGroupedTargets(groups)', body)
        self.assertIn('@"legacy": @(legacy)', body)
        self.assertNotIn('configurationForAccount:', body)
        self.assertIn('targets.targetGroup = @(path.row)', RECORDS)
        self.assertIn('未保存当时的分组信息', RECORDS)

    def test_group_snapshot_is_part_of_atomic_request_and_replay_identity(self):
        body = STORE.split('targets:(NSArray<NSString *> *)targets targetGroups:', 1)[1].split('/* Explicit start', 1)[0]
        for required in ('[SRGroupedTargets(targetGroups) isEqualToArray:targets]', '[saved containsObject:group]',
                         'SRSameOptionalValue(source[@"targetGroups"], targetGroups)', 'source[@"targetGroups"] = targetGroups',
                         'transaction:YES'):
            self.assertIn(required, body)
        self.assertLess(body.index('if (replay)'), body.index('configurationForAccount:'))
        self.assertIn('SRCreateGroupedTargetPicker', LIBRARY)
        self.assertIn('NSJSONWritingSortedKeys', LIBRARY)

    def test_rule_history_routes_to_complete_bound_record_not_exceptions(self):
        route = RECORDS.rsplit('if (self.kind == SRRecordHistory) {', 1)[1].split('\n    }', 1)[0]
        self.assertIn('SRCreateForwardingRecord(self.store, self.account, self.verifyAccount, run)', route)
        self.assertIn('[row[@"id"] copy]', route)
        self.assertIn('navigation.topViewController != self', route)
        self.assertNotIn('SRRecordExceptions', route)

    def test_late_record_preview_rechecks_selected_identity_and_frozen_groups(self):
        body = method(RECORDS, '- (void)configurePreviewCell:')
        for token in ('[self.account copy]', '[self.run copy]', '[self.rows copy]',
                      '[page.account isEqual:account]', '[page.run isEqual:run]',
                      '[page verifyVisibleAccount]', 'forwardingTargetGroupsForRun:run account:account',
                      '[currentGroups isEqual:groups]', '[page hideWithMessage:'):
            self.assertIn(token, body)
        self.assertLess(body.index('[page.run isEqual:run]'), body.index('forwardingTargetGroupsForRun:run'))
        self.assertLess(body.index('[currentGroups isEqual:groups]'), body.index('[page.tableView reloadData]'))

    def test_generated_names_use_real_cumulative_ranges_and_preserve_manual_names(self):
        self.assertIn('@"群分组%lu-%lu"', PLANNER)
        self.assertIn('count += [rule[@"targets"] count]', PLANNER)
        self.assertIn('[rule[@"name"] isEqual:rule[@"generatedName"]]', PLANNER)
        self.assertIn('removeObjectForKey:@"generatedName"', PLANNER)
        self.assertIn('return [left[@"size"] compare:right[@"size"]]', PLANNER)
        self.assertNotIn('@"Rule %lu"', PLANNER)


if __name__ == '__main__':
    unittest.main()
