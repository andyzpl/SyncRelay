"""Execute the production forwarding record queries against the SQLite schema."""
import re
import sqlite3
import unittest

from library_task_test import STORE, TaskFixture, schema


def strings(fragment):
    return ''.join(re.findall(r'"([^"\n]*)"', fragment))


SELECT = strings(STORE.split('SRForwardingRecordSelect =', 1)[1].split(';', 1)[0])
PAGE = STORE.split('- (NSArray<NSDictionary *> *)forwardingRecordsForAccount:', 1)[1].split('\n}', 1)[0]
CURSOR = strings(PAGE.split('NSDictionary *cursor = [self query:', 1)[1].split('values:', 1)[0])
BEFORE, ORDER = re.findall(r'stringByAppendingString:@"([^"]+)"', PAGE)
OUTCOME = strings(STORE.split('#define SRDeliveryOutcomeSQL', 1)[1].splitlines()[0])
TARGETS = STORE.split('- (NSArray<NSDictionary *> *)forwardingTargetsForRun:', 1)[1].split('\n}', 1)[0]
TARGET_GUARD = strings(TARGETS.split('SRRequire([self query:', 1)[1].split('values:', 1)[0])
TARGET_SQL = strings(TARGETS.split('return [self query:', 1)[1].split('values:', 1)[0].replace('SRDeliveryOutcomeSQL', f'"{OUTCOME}"'))


class ForwardingRecordQueries(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.addCleanup(self.db.close)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA foreign_keys=ON')
        schema(self.db)

    def add_run(self, run, account='me', start=10, materialized=True):
        self.db.execute("INSERT INTO plans VALUES(?,?,?,'[]','[]','{}')", (f'p-{run}', account, 'source@chatroom'))
        self.db.execute("INSERT INTO rules VALUES(?,?,?,0,3,5)", (f'r-{run}', f'p-{run}', run))
        if materialized:
            self.db.execute("INSERT INTO runs VALUES(?,?,?,'completed',?,20,3,5,'{}')", (run, f'r-{run}', account, start))

    def test_tied_timestamps_page_without_unstarted_plans_or_other_accounts(self):
        self.add_run('old', start=9)
        self.add_run('tie-first')
        self.add_run('tie-last')
        self.add_run('unstarted', start=12, materialized=False)
        self.add_run('not-mine', account='other', start=13)
        rows = self.db.execute(SELECT + ORDER, ('me', 2)).fetchall()
        self.assertEqual([(row['id'], row['sourceKind']) for row in rows], [('tie-last', 'group_sync'), ('tie-first', 'group_sync')])
        self.add_run('newer-while-reading', start=14)
        cursor = self.db.execute(CURSOR, ('tie-first', 'me')).fetchone()
        older = self.db.execute(SELECT + BEFORE + ORDER, ('me', *cursor, 2)).fetchall()
        self.assertEqual([row['id'] for row in older], ['old'])
        self.assertIsNone(self.db.execute(CURSOR, ('not-mine', 'me')).fetchone())

    def test_delivery_rows_keep_submission_separate_from_confirmation(self):
        self.add_run('run')
        states = ['confirmed', 'failed', 'uncertain', 'uncertain', 'cancelled']
        for pos, state in enumerate(states):
            self.db.execute('INSERT INTO deliveries(id,run_id,target,position,state,attempt_id) VALUES(?,?,?,?,?,?)',
                            (f'd-{pos}', 'run', f'group-{pos}', pos, state, f'a-{pos}'))
        self.db.execute("INSERT INTO attempts(id,delivery_id,started_at,state) VALUES('a-2','d-2',1,'uncertain')")
        self.db.execute("INSERT INTO submission_receipts VALUES('d-2','a-2',2)")
        self.assertIsNone(self.db.execute(TARGET_GUARD, ('run', 'other')).fetchone())
        self.assertEqual([tuple(row) for row in self.db.execute(TARGET_SQL, ('run', 3, 1))],
                         [('group-1', 'failed'), ('group-2', 'submitted'), ('group-3', 'uncertain')])

    def test_library_run_joins_the_same_feed_only_after_start(self):
        self.add_run('sync')
        fx = TaskFixture(self.db)
        fx.item(account='me')
        task = fx.confirm('library', account='me')
        self.assertEqual([row['id'] for row in self.db.execute(SELECT + ORDER, ('me', 30))], ['sync'])
        frozen = fx.frozen(task, account='me')
        self.db.execute(fx.insert_run, ('library', frozen['rule_id'], 'me', 100, 5, 10, frozen['frozen_snapshot']))
        self.db.execute(fx.attach_run, ('library', 100, task, 'me'))
        self.assertEqual([(row['id'], row['sourceKind']) for row in self.db.execute(SELECT + ORDER, ('me', 30))],
                         [('library', 'message_library'), ('sync', 'group_sync')])


if __name__ == '__main__':
    unittest.main()
